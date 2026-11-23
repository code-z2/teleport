import CryptoKit
import Foundation

// File sessions: SPEC.md "File sessions (v2)". A phone and a Mac run a signed
// ephemeral ECDH handshake through the Mac's relay mailbox, then exchange
// AES-GCM frames with implicit counters.

public enum SessionCrypto {
    static let info = Data("teleport/v1/session".utf8)
    public static let phoneToMac: UInt32 = 1
    public static let macToPhone: UInt32 = 2
    /// Largest data payload per frame.
    public static let chunkSize = 256 * 1024
    /// Most unacknowledged data a sender keeps in flight.
    public static let window: Int64 = 2 * 1024 * 1024
    /// The receiver acknowledges at least this often.
    public static let ackEvery: Int64 = 1024 * 1024
    /// Largest `read` (a byte range, for streaming): within one window, so no acks needed.
    public static let maxRead = 2 * 1024 * 1024

    public struct Hello: Codable, Sendable {
        public var t = "hello"
        public var v = 1
        public var from: String
        public var epk: String
        public var n: String
        public var ts: Int
        public var sig: String
    }

    public struct Accept: Codable, Sendable {
        public var t = "accept"
        public var epk: String
        public var n: String
        public var sig: String
    }

    /// First-message peek: `hello`, `accept` or `error`.
    struct Tagged: Decodable { let t: String; let code: String? }

    public static func helloTranscript(mailbox: String, from: String, epk: String, n: String, ts: Int) -> Data {
        Data("teleport/v1/session|\(mailbox)|\(from)|\(epk)|\(n)|\(ts)".utf8)
    }

    public static func helloTranscript(mailbox: String, _ h: Hello) -> Data {
        helloTranscript(mailbox: mailbox, from: h.from, epk: h.epk, n: h.n, ts: h.ts)
    }

    public static func acceptTranscript(hello: Data, epk: String, n: String) -> Data {
        hello + Data("|\(epk)|\(n)".utf8)
    }

    public struct Keys: Sendable {
        public let phoneToMac: SymmetricKey
        public let macToPhone: SymmetricKey
    }

    public static func keys(ownEphemeral: P256.KeyAgreement.PrivateKey, otherEpk: Data, acceptTranscript: Data) throws -> Keys {
        let other = try P256.KeyAgreement.PublicKey(x963Representation: otherEpk)
        let ss = try ownEphemeral.sharedSecretFromKeyAgreement(with: other).withUnsafeBytes { Data($0) }
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ss),
            salt: Data(SHA256.hash(data: acceptTranscript)),
            info: info,
            outputByteCount: 64
        ).withUnsafeBytes { Data($0) }
        return Keys(phoneToMac: SymmetricKey(data: okm.prefix(32)), macToPhone: SymmetricKey(data: okm.suffix(32)))
    }

    static func verify(_ sig: Data, of data: Data, by publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// One direction of a session: AES-256-GCM with nonce = dir ‖ counter.
public struct FrameCipher: Sendable {
    let key: SymmetricKey
    let dir: UInt32
    private(set) var counter: UInt64 = 0

    public init(key: SymmetricKey, dir: UInt32, counter: UInt64 = 0) {
        self.key = key; self.dir = dir; self.counter = counter
    }

    static func nonce(dir: UInt32, counter: UInt64) -> Data {
        withUnsafeBytes(of: dir.bigEndian) { Data($0) } + withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: .init(data: Self.nonce(dir: dir, counter: counter)))
        counter += 1
        return box.ciphertext + box.tag
    }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 16 else { throw FileSessionError.protocolError }
        let box = try AES.GCM.SealedBox(
            nonce: .init(data: Self.nonce(dir: dir, counter: counter)),
            ciphertext: frame.dropLast(16), tag: frame.suffix(16))
        let plain = try AES.GCM.open(box, using: key)
        counter += 1
        return plain
    }
}

/// A file or folder in a listing.
public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let dir: Bool
    public let size: Int64
    public let mtime: Int
    public var id: String { name }

    public init(name: String, dir: Bool, size: Int64, mtime: Int) {
        self.name = name; self.dir = dir; self.size = size; self.mtime = mtime
    }
}

/// A control message. One flat shape for every `op`; unused fields are omitted.
public struct Control: Codable, Sendable {
    public var op: String
    public var id: UInt32
    public var path: String?
    public var offset: Int64?
    public var size: Int64?
    public var mime: String?
    public var sha256: String?
    public var name: String?
    public var dir: String?
    public var bytes: Int64?
    /// `thumbnail`: longest side in pixels.
    public var px: Int?
    public var entries: [FileEntry]?
    public var code: String?
    public var message: String?

    public init(_ op: String, id: UInt32) { self.op = op; self.id = id }

    public static func error(_ id: UInt32, _ code: String, _ message: String) -> Control {
        var c = Control("error", id: id); c.code = code; c.message = message; return c
    }
}

/// A decrypted frame: 0x01 ‖ JSON, or 0x02 ‖ id ‖ bytes.
public enum SessionFrame: Sendable {
    case control(Control)
    case data(UInt32, Data)

    public var id: UInt32 {
        switch self {
        case .control(let c): c.id
        case .data(let id, _): id
        }
    }

    public func encoded() throws -> Data {
        switch self {
        case .control(let c): Data([1]) + (try JSONEncoder().encode(c))
        case .data(let id, let bytes): Data([2]) + withUnsafeBytes(of: id.bigEndian) { Data($0) } + bytes
        }
    }

    public static func decode(_ plain: Data) throws -> SessionFrame {
        let p = Data(plain)  // re-base indices at 0
        guard let kind = p.first else { throw FileSessionError.protocolError }
        switch kind {
        case 1:
            return .control(try JSONDecoder().decode(Control.self, from: p.dropFirst()))
        case 2 where p.count >= 5:
            let id = p[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return .data(id, Data(p.dropFirst(5)))
        default:
            throw FileSessionError.protocolError
        }
    }
}

public enum FileSessionError: Error, Sendable, Equatable {
    case offline
    case refused(String)
    case untrusted
    case remote(code: String, message: String)
    case hashMismatch
    case closed
    case protocolError
}

extension FileSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .offline: "The Mac is offline. Check it's awake and connected."
        case .refused("denied"): "The Mac doesn't recognise this device. Pair them again."
        case .refused("stale"): "This device's clock is too far off the Mac's."
        case .refused(let code): "The Mac refused the connection (\(code))."
        case .untrusted: "The Mac's identity didn't check out."
        case .remote(_, let message): message
        case .hashMismatch: "The file was corrupted in transit. Try again."
        case .closed: "The connection to the Mac closed."
        case .protocolError: "The Mac sent something unexpected."
        }
    }
}

/// An ordered byte pipe to the other end (a WebSocket on the phone, a mailbox session on the Mac).
public protocol SessionPipe: Sendable {
    /// Queues a message. Messages arrive in the order they were queued.
    func send(_ data: Data)
    var incoming: AsyncThrowingStream<Data, Error> { get }
    func close()
}

/// Lexical path rules (SPEC.md "Path rules"). Returns the normalised relative path, or nil.
public enum FilePaths {
    public static func check(_ path: String, showHidden: Bool) -> String? {
        if path.hasPrefix("/") || path.contains("\0") { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        if parts.contains("..") { return nil }
        if !showHidden {
            for (i, p) in parts.enumerated() where p.hasPrefix(".") || (i == 0 && p == "Library") { return nil }
        }
        return parts.joined(separator: "/")
    }

    /// Whether a listing entry is shown (same rules, for one name inside `parent`).
    public static func visible(_ name: String, inTopLevel: Bool, showHidden: Bool) -> Bool {
        showHidden || !(name.hasPrefix(".") || (inTopLevel && name == "Library"))
    }
}

import CryptoKit
import Foundation

/// Teleport wire protocol v1. See protocol/SPEC.md.
public struct Envelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, blob, peer, pair
        case pairOK = "pair-ok"
        case pairNo = "pair-no"
    }

    public var v: Int
    public var id: String
    public var ts: Int
    public var k: Kind
    public var from: String
    public var epk: String
    public var n: String
    public var ct: String
    public var sig: String

    public static let maxBytes = 3000

    var header: Data { Data("teleport/v1|\(id)|\(ts)|\(k.rawValue)|\(from)".utf8) }

    public func jsonString() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }

    public static func parse(_ json: String) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
    }
}

public enum OpenError: String, Error, Sendable {
    case version, kind, peer, signature, stale, replay, decrypt, encoding, proof
}

public enum TeleportCrypto {
    static let info = Data("teleport/v1/aes-256-gcm".utf8)
    public static let blobAAD = Data("teleport/v1/blob".utf8)

    public static func fingerprint(_ pub: Data) -> String {
        Data(SHA256.hash(data: pub).prefix(8)).base64URL
    }

    static func deriveKey(sharedSecret: Data, epk: Data, recipientKa: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: epk + recipientKa,
            info: info,
            outputByteCount: 32
        )
    }

    /// Seals `plaintext` for the holder of `recipientKa`, signed by `signer`.
    /// `id`, `ts`, `ephemeral` and `nonce` are only passed explicitly by tests.
    public static func seal(
        kind: Envelope.Kind,
        plaintext: Data,
        signer: some SigningKey,
        recipientKa: Data,
        id: Data? = nil,
        ts: Int? = nil,
        ephemeral: P256.KeyAgreement.PrivateKey? = nil,
        nonce: Data? = nil
    ) throws -> Envelope {
        let eph = ephemeral ?? P256.KeyAgreement.PrivateKey()
        let epk = eph.publicKey.x963Representation
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: recipientKa)
        let ss = try eph.sharedSecretFromKeyAgreement(with: recipient).withUnsafeBytes { Data($0) }
        let key = deriveKey(sharedSecret: ss, epk: epk, recipientKa: recipientKa)

        let nonceData = nonce ?? Data(AES.GCM.Nonce())
        var env = Envelope(
            v: 1,
            id: (id ?? .random(16)).base64URL,
            ts: ts ?? Int(Date().timeIntervalSince1970),
            k: kind,
            from: fingerprint(signer.publicKey),
            epk: epk.base64URL,
            n: nonceData.base64URL,
            ct: "",
            sig: ""
        )
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceData), authenticating: env.header)
        let ct = box.ciphertext + box.tag
        env.ct = ct.base64URL
        env.sig = try signer.sign(env.header + epk + nonceData + ct).base64URL
        return env
    }

    /// Verifies the signature first, then freshness, then decrypts.
    /// Replay checking is the caller's job (see `ReplayCache`), because the
    /// copy action legitimately re-opens an envelope the NSE already opened.
    public static func open(
        _ env: Envelope,
        ownKa: some AgreementKey,
        senderKs: Data,
        now: Int = Int(Date().timeIntervalSince1970)
    ) throws -> Data {
        guard env.v == 1 else { throw OpenError.version }
        guard env.from == fingerprint(senderKs) else { throw OpenError.peer }
        guard let epk = Data(base64URL: env.epk), let n = Data(base64URL: env.n),
              let ct = Data(base64URL: env.ct), let sig = Data(base64URL: env.sig), ct.count >= 16
        else { throw OpenError.encoding }

        let verifier = try P256.Signing.PublicKey(x963Representation: senderKs)
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig),
              verifier.isValidSignature(signature, for: env.header + epk + n + ct)
        else { throw OpenError.signature }

        guard env.ts >= now - 86_400, env.ts <= now + 300 else { throw OpenError.stale }

        let ss = try ownKa.sharedSecret(with: epk)
        let key = deriveKey(sharedSecret: ss, epk: epk, recipientKa: ownKa.publicKey)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: n), ciphertext: ct.dropLast(16), tag: ct.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: env.header)
        } catch {
            throw OpenError.decrypt
        }
    }

    // MARK: Pairing v2 (SPEC.md "v2 additions")

    public static func pairProof(secret: Data, cardJSON: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(cardJSON.utf8), using: SymmetricKey(data: secret)))
    }

    /// Plaintext of a `pair` envelope. The card is a string so the proof covers exact bytes.
    struct PairBody: Codable { let card: String; let proof: String }

    public static func pairPlaintext(cardJSON: String, proof: Data) throws -> Data {
        let enc = JSONEncoder()
        // Sorted keys: deterministic bytes, matching the other implementations ({"card","proof"}).
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(PairBody(card: cardJSON, proof: proof.base64URL))
    }

    /// Opens a `pair` envelope from a device that isn't paired yet: decrypt, then check the
    /// signature against the key in the card it carries, then the proof against our QR secret.
    public static func openPair(
        _ env: Envelope, ownKa: some AgreementKey, secret: Data, now: Int = Int(Date().timeIntervalSince1970)
    ) throws -> (card: PairingCard, json: String) {
        guard env.v == 1 else { throw OpenError.version }
        guard env.k == .pair else { throw OpenError.kind }
        guard let epk = Data(base64URL: env.epk), let n = Data(base64URL: env.n),
              let ct = Data(base64URL: env.ct), let sig = Data(base64URL: env.sig), ct.count >= 16
        else { throw OpenError.encoding }

        let plaintext: Data
        do {
            let key = deriveKey(sharedSecret: try ownKa.sharedSecret(with: epk), epk: epk, recipientKa: ownKa.publicKey)
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: n), ciphertext: ct.dropLast(16), tag: ct.suffix(16))
            plaintext = try AES.GCM.open(box, using: key, authenticating: env.header)
        } catch {
            throw OpenError.decrypt
        }

        guard let body = try? JSONDecoder().decode(PairBody.self, from: plaintext),
              let card = try? JSONDecoder().decode(PairingCard.self, from: Data(body.card.utf8)),
              let ks = Data(base64URL: card.ks), ks.count == 65,
              let proof = Data(base64URL: body.proof)
        else { throw OpenError.encoding }

        guard env.from == fingerprint(ks) else { throw OpenError.peer }
        let verifier = try P256.Signing.PublicKey(x963Representation: ks)
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig),
              verifier.isValidSignature(signature, for: env.header + epk + n + ct)
        else { throw OpenError.signature }
        guard env.ts >= now - 86_400, env.ts <= now + 300 else { throw OpenError.stale }
        // Constant-time comparison via CryptoKit's MAC check.
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(body.card.utf8), using: SymmetricKey(data: secret))
        else { throw OpenError.proof }
        return (card, body.card)
    }

    // MARK: Blobs

    public struct SealedBlob: Sendable {
        public let ciphertext: Data
        public let key: Data
        public let nonce: Data
    }

    public static func sealBlob(_ bytes: Data) throws -> SealedBlob {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(bytes, using: key, nonce: nonce, authenticating: blobAAD)
        return SealedBlob(
            ciphertext: box.ciphertext + box.tag,
            key: key.withUnsafeBytes { Data($0) },
            nonce: Data(nonce))
    }

    public static func openBlob(_ ciphertext: Data, key: Data, nonce: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw OpenError.decrypt }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: blobAAD)
    }
}

/// Plaintext of a `blob` envelope.
public struct BlobPointer: Codable, Equatable, Sendable {
    public var id: String
    public var mime: String
    public var size: Int
    public var key: String
    public var n: String
    /// Plaintext chunk size of a chunked (large) blob; nil for the single-box format.
    public var c: Int?
    /// The original file name, for files.
    public var name: String?

    public init(id: String, mime: String, size: Int, key: String, n: String, c: Int? = nil, name: String? = nil) {
        self.id = id; self.mime = mime; self.size = size; self.key = key; self.n = n; self.c = c; self.name = name
    }

    public var isChunked: Bool { c != nil }
}

/// Large blobs (SPEC.md "Large blobs"): AES-GCM per chunk, with the chunk index and a
/// final-chunk marker authenticated, so the stream can't be reordered or cut short.
public enum ChunkedBlob {
    public static let chunkSize = 4 * 1024 * 1024
    public static let maxSize = 250 * 1024 * 1024
    /// Multipart upload part size (R2 needs equal parts, ≥ 5 MiB, except the last).
    public static let partSize = 16 * 1024 * 1024

    public static func count(size: Int, chunk: Int = chunkSize) -> Int { max(1, (size + chunk - 1) / chunk) }

    static func nonce(_ n: Data, _ i: Int) -> Data {
        var out = Data(n)
        let tail = out[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } ^ UInt64(i)
        out.replaceSubrange(4..<12, with: withUnsafeBytes(of: tail.bigEndian) { Data($0) })
        return out
    }

    static func aad(_ i: Int, last: Bool) -> Data {
        TeleportCrypto.blobAAD + withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) } + Data([last ? 1 : 0])
    }

    public static func seal(_ chunk: Data, index: Int, last: Bool, key: SymmetricKey, n: Data) throws -> Data {
        let box = try AES.GCM.seal(chunk, using: key, nonce: .init(data: nonce(n, index)), authenticating: aad(index, last: last))
        return box.ciphertext + box.tag
    }

    public static func open(_ sealed: Data, index: Int, last: Bool, key: SymmetricKey, n: Data) throws -> Data {
        guard sealed.count >= 16 else { throw OpenError.decrypt }
        do {
            let box = try AES.GCM.SealedBox(nonce: .init(data: nonce(n, index)), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: aad(index, last: last))
        } catch {
            throw OpenError.decrypt
        }
    }

    /// Whole-buffer helpers (tests, small inputs).
    public static func seal(_ bytes: Data, key: SymmetricKey, n: Data, chunk: Int = chunkSize) throws -> Data {
        let total = count(size: bytes.count, chunk: chunk)
        var out = Data()
        for i in 0..<total {
            let lo = bytes.startIndex + i * chunk, hi = min(lo + chunk, bytes.endIndex)
            out += try seal(Data(bytes[lo..<hi]), index: i, last: i == total - 1, key: key, n: n)
        }
        return out
    }

    public static func open(_ ct: Data, size: Int, key: SymmetricKey, n: Data, chunk: Int = chunkSize) throws -> Data {
        let total = count(size: size, chunk: chunk)
        guard ct.count == size + 16 * total else { throw OpenError.decrypt }
        var out = Data(), offset = ct.startIndex
        for i in 0..<total {
            let plain = i == total - 1 ? size - i * chunk : chunk
            out += try open(Data(ct[offset..<offset + plain + 16]), index: i, last: i == total - 1, key: key, n: n)
            offset += plain + 16
        }
        return out
    }
}

/// Plaintext of a `peer` envelope: the sender was renamed or its push tokens rotated.
/// Missing fields keep their previous values.
public struct PeerUpdate: Codable, Equatable, Sendable {
    public var name: String?
    public var fcm: String?
    public var la: String?
    public var mailbox: String?

    public init(name: String?, fcm: String?, la: String?, mailbox: String? = nil) {
        self.name = name; self.fcm = fcm; self.la = la; self.mailbox = mailbox
    }
}

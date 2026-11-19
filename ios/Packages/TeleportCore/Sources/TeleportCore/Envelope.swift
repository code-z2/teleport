import CryptoKit
import Foundation

/// Teleport wire protocol v1. See protocol/SPEC.md.
public struct Envelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, blob, peer }

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
    case version, kind, peer, signature, stale, replay, decrypt, encoding
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

    public init(id: String, mime: String, size: Int, key: String, n: String) {
        self.id = id; self.mime = mime; self.size = size; self.key = key; self.n = n
    }
}

/// Plaintext of a `peer` envelope: the sender's push tokens rotated.
public struct PeerUpdate: Codable, Equatable, Sendable {
    public var fcm: String
    public var la: String?
    public var name: String?

    public init(fcm: String, la: String?, name: String?) {
        self.fcm = fcm; self.la = la; self.name = name
    }
}

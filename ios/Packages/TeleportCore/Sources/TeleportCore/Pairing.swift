import Foundation

public enum Platform: String, Codable, Sendable { case ios, android, mac }

/// What a device shows as a QR code: `teleport2:<b64u(JSON)>`. See SPEC.md "v2 additions".
/// `ps` (the one-time pairing secret) is only ever in the QR code, never sent over the network.
public struct PairingCard: Codable, Equatable, Sendable {
    public var v: Int = 2
    public var name: String
    public var platform: Platform
    public var ka: String
    public var ks: String
    public var fcm: String?
    public var la: String?
    public var mailbox: String?
    public var ps: String?

    public static let prefix = "teleport2:"

    public init(name: String, platform: Platform, ka: Data, ks: Data, fcm: String?, la: String?, mailbox: String? = nil) {
        self.name = name; self.platform = platform
        self.ka = ka.base64URL; self.ks = ks.base64URL
        self.fcm = fcm; self.la = la; self.mailbox = mailbox
    }

    /// The card as sent inside `pair` / `pair-ok`: no secret.
    public func json() throws -> String {
        var copy = self
        copy.ps = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(copy), as: UTF8.self)
    }

    /// The QR payload, including the secret.
    public func encoded() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.prefix + (try enc.encode(self)).base64URL
    }

    public static func decode(_ s: String) throws -> PairingCard {
        guard s.hasPrefix(prefix), let json = Data(base64URL: String(s.dropFirst(prefix.count))) else {
            throw OpenError.encoding
        }
        let card = try JSONDecoder().decode(PairingCard.self, from: json)
        guard card.v == 2, Data(base64URL: card.ka)?.count == 65, Data(base64URL: card.ks)?.count == 65 else {
            throw OpenError.encoding
        }
        return card
    }
}

/// A paired device. Public keys and push addresses are not secret, so peers live in
/// App Group defaults where the app and every extension can read them.
public struct Peer: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var platform: Platform
    public var ka: Data
    public var ks: Data
    public var fcm: String?
    public var la: String?
    public var mailbox: String?
    public var pairedAt: Date

    public init(card: PairingCard, pairedAt: Date = Date()) throws {
        guard let ka = Data(base64URL: card.ka), let ks = Data(base64URL: card.ks) else { throw OpenError.encoding }
        self.name = card.name; self.platform = card.platform
        self.ka = ka; self.ks = ks
        self.fcm = card.fcm; self.la = card.la; self.mailbox = card.mailbox
        self.pairedAt = pairedAt
    }

    /// `fp(ks)`: the device's identity, and the `from` of every envelope it sends.
    public var id: String { TeleportCrypto.fingerprint(ks) }
}

/// A device that scanned our QR code and is waiting for the user to tap Allow.
public struct PairRequest: Codable, Equatable, Sendable, Identifiable {
    public var cardJSON: String
    public var name: String
    public var platform: Platform
    public var expires: Date
    public var id: String
}

public final class SharedStore: @unchecked Sendable {
    // UserDefaults is thread-safe; @unchecked because it isn't annotated Sendable.
    let defaults: UserDefaults

    public init(appGroup: String) {
        defaults = UserDefaults(suiteName: appGroup) ?? .standard
        // v1 stored a single "peer". v2 pairings are incompatible: drop it (re-pair once).
        defaults.removeObject(forKey: "peer")
    }

    private func load<T: Decodable>(_ key: String, as: T.Type) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    // MARK: Devices

    /// Paired devices by `fp(ks)`.
    public var peers: [String: Peer] {
        get { load("peers", as: [String: Peer].self) ?? [:] }
        set { save(newValue, "peers") }
    }

    /// Devices we scanned, waiting for their `pair-ok`. Trusted only for that reply.
    public var pendingOutbound: [String: Peer] {
        get { load("pendingOutbound", as: [String: Peer].self)?.filter { $0.value.pairedAt > Date().addingTimeInterval(-600) } ?? [:] }
        set { save(newValue, "pendingOutbound") }
    }

    /// Devices that scanned us, waiting for Allow.
    public var pairRequests: [String: PairRequest] {
        get { load("pairRequests", as: [String: PairRequest].self)?.filter { $0.value.expires > Date() } ?? [:] }
        set { save(newValue, "pairRequests") }
    }

    public var sortedPeers: [Peer] { peers.values.sorted { $0.pairedAt < $1.pairedAt } }

    // MARK: Our QR secret

    struct Secret: Codable { var value: Data; var expires: Date; var used: Bool }

    /// A fresh one-time secret for the QR code, valid 10 minutes.
    public func newPairingSecret() -> Data {
        let value = Data.random(16)
        save(Secret(value: value, expires: Date().addingTimeInterval(600), used: false), "pairingSecret")
        return value
    }

    /// The current secret if it's still valid and unused.
    public var currentPairingSecret: Data? {
        guard let s = load("pairingSecret", as: Secret.self), !s.used, s.expires > Date() else { return nil }
        return s.value
    }

    public func markPairingSecretUsed() {
        guard var s = load("pairingSecret", as: Secret.self) else { return }
        s.used = true
        save(s, "pairingSecret")
    }

    // MARK: This device

    /// Our name as other devices see it. iOS only tells apps "iPhone", so the user sets it.
    public var deviceName: String? {
        get { defaults.string(forKey: "deviceName") }
        set { defaults.set(newValue, forKey: "deviceName") }
    }

    /// Our own tokens, so we can tell peers when they rotate.
    public var ownFCMToken: String? {
        get { defaults.string(forKey: "ownFCM") }
        set { defaults.set(newValue, forKey: "ownFCM") }
    }

    public var ownLiveActivityToken: String? {
        get { defaults.string(forKey: "ownLA") }
        set { defaults.set(newValue, forKey: "ownLA") }
    }

    /// Returns false if `id` was already seen in the last 24 h; records it otherwise.
    public func markSeen(_ id: String, now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
        var seen = (defaults.dictionary(forKey: "seen") as? [String: Int]) ?? [:]
        seen = seen.filter { $0.value > now - 86_400 }
        if seen[id] != nil { return false }
        seen[id] = now
        defaults.set(seen, forKey: "seen")
        return true
    }
}

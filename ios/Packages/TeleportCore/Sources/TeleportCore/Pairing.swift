import Foundation

public enum Platform: String, Codable, Sendable { case ios, android }

/// What a device shows as a QR code: `teleport1:<b64u(JSON)>`.
public struct PairingCard: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var name: String
    public var platform: Platform
    public var ka: String
    public var ks: String
    public var fcm: String
    public var la: String?

    public static let prefix = "teleport1:"

    public init(name: String, platform: Platform, ka: Data, ks: Data, fcm: String, la: String?) {
        self.name = name; self.platform = platform
        self.ka = ka.base64URL; self.ks = ks.base64URL
        self.fcm = fcm; self.la = la
    }

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
        guard card.v == 1, Data(base64URL: card.ka)?.count == 65, Data(base64URL: card.ks)?.count == 65 else {
            throw OpenError.encoding
        }
        return card
    }
}

/// The one paired device. Public keys and push tokens are not secret, so this
/// lives in App Group defaults where the app and every extension can read it.
public struct Peer: Codable, Equatable, Sendable {
    public var name: String
    public var platform: Platform
    public var ka: Data
    public var ks: Data
    public var fcm: String
    public var la: String?

    public init(card: PairingCard) throws {
        guard let ka = Data(base64URL: card.ka), let ks = Data(base64URL: card.ks) else { throw OpenError.encoding }
        self.name = card.name; self.platform = card.platform
        self.ka = ka; self.ks = ks; self.fcm = card.fcm; self.la = card.la
    }

    public var fingerprint: String { TeleportCrypto.fingerprint(ks) }
}

public final class SharedStore: @unchecked Sendable {
    // UserDefaults is thread-safe; @unchecked because it isn't annotated Sendable.
    let defaults: UserDefaults

    public init(appGroup: String) {
        defaults = UserDefaults(suiteName: appGroup) ?? .standard
    }

    public var peer: Peer? {
        get { defaults.data(forKey: "peer").flatMap { try? JSONDecoder().decode(Peer.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "peer") }
    }

    /// Our own tokens, so we can tell the peer when they rotate.
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

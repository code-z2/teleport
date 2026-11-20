import Foundation

/// Values injected through each target's Info.plist (from Config/Teleport.xcconfig).
public struct TeleportConfig: Sendable {
    public let relayURL: URL
    public let relayKey: String
    public let appGroup: String
    public let keychainGroup: String?

    public init(relayURL: URL, relayKey: String, appGroup: String, keychainGroup: String?) {
        self.relayURL = relayURL; self.relayKey = relayKey
        self.appGroup = appGroup; self.keychainGroup = keychainGroup
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> TeleportConfig {
        func value(_ key: String) -> String {
            guard let s = bundle.object(forInfoDictionaryKey: key) as? String, !s.isEmpty else {
                fatalError("Missing \(key) in Info.plist — see ios/Config/Teleport.xcconfig.example")
            }
            return s
        }
        return TeleportConfig(
            relayURL: URL(string: value("TeleportRelayURL"))!,
            relayKey: value("TeleportRelayKey"),
            appGroup: value("TeleportAppGroup"),
            keychainGroup: bundle.object(forInfoDictionaryKey: "TeleportKeychainGroup") as? String)
    }
}

public enum RelayError: Error, Sendable {
    case http(Int, String?)
    case peerGone  // 410: peer's push token is dead
    case offline   // 503: the Mac isn't connected to its mailbox
}

extension RelayError: LocalizedError {
    /// Readable messages instead of "The operation couldn't be completed (RelayError error 0)".
    public var errorDescription: String? {
        switch self {
        case .peerGone: return "The other device's push address expired."
        case .offline: return "The Mac isn't connected."
        case .http(0, let detail?): return detail
        case .http(let status, let body):
            // The relay answers {"ok":false,"error":"…"}.
            let reason = body.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
            return "Relay error \(status)" + (reason.map { ": \($0)" } ?? "")
        }
    }
}

public struct RelayClient: Sendable {
    let config: TeleportConfig
    let session: URLSession

    public init(config: TeleportConfig, session: URLSession = .shared) {
        self.config = config; self.session = session
    }

    /// An authorized request to the relay (also used by the Mac's mailbox connection).
    public func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: config.relayURL.appending(path: path))
        r.httpMethod = method
        r.setValue("Bearer \(config.relayKey)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        return r
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RelayError.http(0, nil) }
        if http.statusCode == 410 { throw RelayError.peerGone }
        if http.statusCode == 503 { throw RelayError.offline }
        guard (200..<300).contains(http.statusCode) else {
            throw RelayError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    public func send(_ env: Envelope, to peer: Peer) async throws {
        struct To: Encodable { let platform: Platform; let fcm: String?; let la: String?; let mailbox: String? }
        struct Body: Encodable { let to: To; let env: Envelope }
        // Macs are reached through their relay mailbox (a live connection); phones by push.
        let to: To
        if peer.platform.hasMailbox {
            guard let mailbox = peer.mailbox else { throw RelayError.http(0, "\(peer.name) has no mailbox") }
            to = To(platform: peer.platform, fcm: nil, la: nil, mailbox: mailbox)
        } else {
            guard let fcm = peer.fcm, !fcm.isEmpty else { throw RelayError.http(0, "\(peer.name) has no push address yet") }
            to = To(platform: peer.platform, fcm: fcm, la: peer.platform == .ios ? peer.la : nil, mailbox: nil)
        }
        var r = request("v1/send", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(Body(to: to, env: env))
        let (data, response) = try await session.data(for: r)
        try check(response, data)
    }

    /// Whether a Mac is connected to its mailbox right now (for "online" labels in pickers).
    /// Whether a Mac is connected to its mailbox right now; nil if the relay couldn't be reached.
    public func isOnline(mailbox: String) async -> Bool? {
        var r = request("v1/mailbox/\(mailbox)/status", method: "GET")
        r.timeoutInterval = 15
        r.cachePolicy = .reloadIgnoringLocalCacheData  // live status, never a cached answer
        struct Status: Decodable { let online: Bool }
        guard let (data, response) = try? await session.data(for: r),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(Status.self, from: data)
        else { return nil }
        return status.online
    }

    public func putBlob(_ ciphertext: Data) async throws -> String {
        var r = request("v1/blob", method: "PUT")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: r, from: ciphertext)
        try check(response, data)
        struct Out: Decodable { let id: String }
        return try JSONDecoder().decode(Out.self, from: data).id
    }

    public func getBlob(_ id: String) async throws -> Data {
        let (data, response) = try await session.data(for: request("v1/blob/\(id)", method: "GET"))
        try check(response, data)
        return data
    }

    public func deleteBlob(_ id: String) async throws {
        let (data, response) = try await session.data(for: request("v1/blob/\(id)", method: "DELETE"))
        try check(response, data)
    }
}

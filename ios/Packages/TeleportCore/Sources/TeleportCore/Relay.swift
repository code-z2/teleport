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
}

public struct RelayClient: Sendable {
    let config: TeleportConfig
    let session: URLSession

    public init(config: TeleportConfig, session: URLSession = .shared) {
        self.config = config; self.session = session
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: config.relayURL.appending(path: path))
        r.httpMethod = method
        r.setValue("Bearer \(config.relayKey)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        return r
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RelayError.http(0, nil) }
        if http.statusCode == 410 { throw RelayError.peerGone }
        guard (200..<300).contains(http.statusCode) else {
            throw RelayError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    public func send(_ env: Envelope, to peer: Peer) async throws {
        struct To: Encodable { let platform: Platform; let fcm: String; let la: String? }
        struct Body: Encodable { let to: To; let env: Envelope }
        var r = request("v1/send", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(
            Body(to: To(platform: peer.platform, fcm: peer.fcm, la: peer.platform == .ios ? peer.la : nil), env: env))
        let (data, response) = try await session.data(for: r)
        try check(response, data)
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

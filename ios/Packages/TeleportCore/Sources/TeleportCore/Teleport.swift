import Foundation

/// Decrypted clip content.
public enum Clip: Sendable {
    case text(String)
    case image(Data, mime: String)
}

public enum TeleportError: Error, Sendable {
    case notPaired
    case tooLarge
}

/// High-level send/receive used by the app and every extension.
public struct Teleport: Sendable {
    public let config: TeleportConfig
    public let keys: DeviceKeys
    public let store: SharedStore
    public let relay: RelayClient

    public static let maxBlobBytes = 10 * 1024 * 1024

    public init(config: TeleportConfig = .fromBundle()) throws {
        self.config = config
        self.keys = try DeviceKeys.loadOrCreate(accessGroup: config.keychainGroup)
        self.store = SharedStore(appGroup: config.appGroup)
        self.relay = RelayClient(config: config)
    }

    func peerOrThrow() throws -> Peer {
        guard let peer = store.peer else { throw TeleportError.notPaired }
        return peer
    }

    // MARK: Pairing

    public func myCard(name: String) throws -> PairingCard {
        PairingCard(
            name: name, platform: .ios,
            ka: keys.agreement.publicKey, ks: keys.signing.publicKey,
            fcm: store.ownFCMToken ?? "", la: store.ownLiveActivityToken)
    }

    public func pair(with encodedCard: String) throws -> Peer {
        let peer = try Peer(card: PairingCard.decode(encodedCard))
        store.peer = peer
        return peer
    }

    /// Call when our FCM or push-to-start token changes.
    public func announceTokens(name: String) async throws {
        guard let peer = store.peer, let fcm = store.ownFCMToken else { return }
        let body = try JSONEncoder().encode(PeerUpdate(fcm: fcm, la: store.ownLiveActivityToken, name: name))
        let env = try TeleportCrypto.seal(kind: .peer, plaintext: body, signer: keys.signing, recipientKa: peer.ka)
        try await relay.send(env, to: peer)
    }

    // MARK: Send

    public func send(_ clip: Clip) async throws {
        let peer = try peerOrThrow()
        switch clip {
        case .text(let text):
            let env = try TeleportCrypto.seal(
                kind: .text, plaintext: Data(text.utf8), signer: keys.signing, recipientKa: peer.ka)
            if try env.jsonString().utf8.count <= Envelope.maxBytes {
                try await relay.send(env, to: peer)
            } else {
                try await sendBlob(Data(text.utf8), mime: "text/plain; charset=utf-8", to: peer)
            }
        case .image(let data, let mime):
            try await sendBlob(data, mime: mime, to: peer)
        }
    }

    private func sendBlob(_ bytes: Data, mime: String, to peer: Peer) async throws {
        guard bytes.count + 16 <= Self.maxBlobBytes else { throw TeleportError.tooLarge }
        let sealed = try TeleportCrypto.sealBlob(bytes)
        let id = try await relay.putBlob(sealed.ciphertext)
        let pointer = BlobPointer(
            id: id, mime: mime, size: bytes.count, key: sealed.key.base64URL, n: sealed.nonce.base64URL)
        let env = try TeleportCrypto.seal(
            kind: .blob, plaintext: try JSONEncoder().encode(pointer), signer: keys.signing, recipientKa: peer.ka)
        try await relay.send(env, to: peer)
    }

    // MARK: Receive

    public enum Received: Sendable {
        case clip(Clip, id: String)
        case peerUpdated(Peer)
    }

    /// Verifies and decrypts an envelope. `firstDelivery` is true in the NSE: it
    /// enforces the replay cache and applies peer updates. The copy paths
    /// (notification action, Live Activity button) re-open with `false`.
    public func receive(_ envJSON: String, firstDelivery: Bool) async throws -> Received {
        let env = try Envelope.parse(envJSON)
        var peer = try peerOrThrow()
        let plaintext = try TeleportCrypto.open(env, ownKa: keys.agreement, senderKs: peer.ks)
        if firstDelivery, !store.markSeen(env.id) { throw OpenError.replay }

        switch env.k {
        case .text:
            return .clip(.text(String(decoding: plaintext, as: UTF8.self)), id: env.id)
        case .blob:
            let pointer = try JSONDecoder().decode(BlobPointer.self, from: plaintext)
            let bytes = try await fetchBlob(pointer, envelopeID: env.id)
            if pointer.mime.hasPrefix("text/") {
                return .clip(.text(String(decoding: bytes, as: UTF8.self)), id: env.id)
            }
            return .clip(.image(bytes, mime: pointer.mime), id: env.id)
        case .peer:
            guard firstDelivery else { throw OpenError.kind }
            let update = try JSONDecoder().decode(PeerUpdate.self, from: plaintext)
            peer.fcm = update.fcm
            peer.la = update.la
            if let name = update.name { peer.name = name }
            store.peer = peer
            return .peerUpdated(peer)
        }
    }

    /// Decrypted blobs are cached in the App Group (keyed by envelope id) so the
    /// copy action can reuse what the NSE downloaded; the R2 copy is deleted.
    private func fetchBlob(_ p: BlobPointer, envelopeID: String) async throws -> Data {
        let cache = clipCacheURL(envelopeID)
        if let cached = try? Data(contentsOf: cache) { return cached }
        guard let key = Data(base64URL: p.key), let n = Data(base64URL: p.n) else { throw OpenError.encoding }
        let bytes = try TeleportCrypto.openBlob(try await relay.getBlob(p.id), key: key, nonce: n)
        try? FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: cache, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? await relay.deleteBlob(p.id)
        pruneClipCache()
        return bytes
    }

    func clipCacheURL(_ id: String) -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: config.appGroup)
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "clips/\(id)")
    }

    func pruneClipCache() {
        let dir = clipCacheURL("x").deletingLastPathComponent()
        let cutoff = Date().addingTimeInterval(-3600)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }
}

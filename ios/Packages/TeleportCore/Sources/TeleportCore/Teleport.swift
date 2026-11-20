import Foundation

/// Decrypted clip content.
public enum Clip: Sendable {
    case text(String)
    case image(Data, mime: String)
}

public enum TeleportError: Error, Sendable {
    case notPaired
    case tooLarge
    /// More than one device is paired and none was chosen.
    case chooseDevice
    /// The QR code is our own, or isn't a Teleport v2 code.
    case invalidCode
    /// The pairing request expired or was already handled.
    case noSuchRequest
}

/// High-level send/receive used by the app and every extension.
public struct Teleport: Sendable {
    public let config: TeleportConfig
    public let keys: DeviceKeys
    public let store: SharedStore
    public let relay: RelayClient
    public let platform: Platform

    public static let maxBlobBytes = 10 * 1024 * 1024

    public init(config: TeleportConfig = .fromBundle(), platform: Platform = .ios) throws {
        self.config = config
        self.keys = try DeviceKeys.loadOrCreate(accessGroup: config.keychainGroup)
        self.store = SharedStore(appGroup: config.appGroup)
        self.relay = RelayClient(config: config)
        self.platform = platform
    }

    public var myID: String { TeleportCrypto.fingerprint(keys.signing.publicKey) }

    /// The one device to send to when the caller didn't choose.
    public func defaultPeer() throws -> Peer {
        let peers = store.sortedPeers
        if peers.isEmpty { throw TeleportError.notPaired }
        guard peers.count == 1 else { throw TeleportError.chooseDevice }
        return peers[0]
    }

    // MARK: Pairing (SPEC.md "v2 additions")

    public func myCard(name: String) -> PairingCard {
        PairingCard(
            name: name, platform: platform,
            ka: keys.agreement.publicKey, ks: keys.signing.publicKey,
            fcm: store.ownFCMToken, la: store.ownLiveActivityToken)
    }

    /// Our QR code, with a fresh one-time secret (valid 10 minutes).
    public func qrCode(name: String) throws -> String {
        var card = myCard(name: name)
        card.ps = store.newPairingSecret().base64URL
        return try card.encoded()
    }

    /// We scanned another device's QR code: remember it as pending and send it a `pair`
    /// request proving we saw its screen. It becomes a peer when its `pair-ok` arrives.
    @discardableResult
    public func scan(_ code: String, name: String) async throws -> Peer {
        guard let card = try? PairingCard.decode(code), let ps = card.ps.flatMap({ Data(base64URL: $0) }) else {
            throw TeleportError.invalidCode
        }
        var peer = try Peer(card: card)
        guard peer.id != myID else { throw TeleportError.invalidCode }
        peer.pairedAt = Date()

        let myJSON = try myCard(name: name).json()
        let body = try TeleportCrypto.pairPlaintext(
            cardJSON: myJSON, proof: TeleportCrypto.pairProof(secret: ps, cardJSON: myJSON))
        let env = try TeleportCrypto.seal(kind: .pair, plaintext: body, signer: keys.signing, recipientKa: peer.ka)
        try await relay.send(env, to: peer)

        var pending = store.pendingOutbound
        pending[peer.id] = peer
        store.pendingOutbound = pending
        return peer
    }

    /// The user tapped Allow on a pairing request: store the device and send `pair-ok`.
    @discardableResult
    public func allow(_ requestID: String, name: String) async throws -> Peer {
        guard let request = store.pairRequests[requestID] else { throw TeleportError.noSuchRequest }
        let peer = try Peer(card: JSONDecoder().decode(PairingCard.self, from: Data(request.cardJSON.utf8)))
        let body = Data(try myCard(name: name).json().utf8)
        let env = try TeleportCrypto.seal(kind: .pairOK, plaintext: body, signer: keys.signing, recipientKa: peer.ka)
        try await relay.send(env, to: peer)

        var peers = store.peers
        peers[peer.id] = peer
        store.peers = peers
        deny(requestID)
        return peer
    }

    public func deny(_ requestID: String) {
        var requests = store.pairRequests
        requests[requestID] = nil
        store.pairRequests = requests
    }

    public func remove(_ peerID: String) {
        var peers = store.peers
        peers[peerID] = nil
        store.peers = peers
    }

    /// Tell every paired device our current name and push addresses.
    public func announce(name: String) async {
        let update = PeerUpdate(name: name, fcm: store.ownFCMToken, la: store.ownLiveActivityToken)
        guard let body = try? JSONEncoder().encode(update) else { return }
        for peer in store.peers.values {
            guard let env = try? TeleportCrypto.seal(kind: .peer, plaintext: body, signer: keys.signing, recipientKa: peer.ka)
            else { continue }
            try? await relay.send(env, to: peer)
        }
    }

    // MARK: Send

    public func send(_ clip: Clip, to peer: Peer) async throws {
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
        case clip(Clip, id: String, from: Peer)
        case peerUpdated(Peer)
        /// Someone scanned our QR code; the user must Allow or Deny.
        case pairRequest(PairRequest)
        /// A device we scanned accepted.
        case paired(Peer)
    }

    /// Verifies and decrypts an envelope. `firstDelivery` is true in the NSE: it
    /// enforces the replay cache and applies pairing and device updates. The copy
    /// paths (notification action, Live Activity button) re-open clips with `false`.
    public func receive(_ envJSON: String, firstDelivery: Bool) async throws -> Received {
        let env = try Envelope.parse(envJSON)

        if env.k == .pair {
            guard firstDelivery else { throw OpenError.kind }
            guard let secret = store.currentPairingSecret else { throw OpenError.proof }
            let (card, json) = try TeleportCrypto.openPair(env, ownKa: keys.agreement, secret: secret)
            guard store.markSeen(env.id) else { throw OpenError.replay }
            store.markPairingSecretUsed()
            let request = PairRequest(
                cardJSON: json, name: card.name, platform: card.platform,
                expires: Date().addingTimeInterval(600), id: env.from)
            var requests = store.pairRequests
            requests[request.id] = request
            store.pairRequests = requests
            return .pairRequest(request)
        }

        // Everything else must come from a paired device (or, for pair-ok, one we scanned).
        let known = store.peers[env.from]
        let pending = env.k == .pairOK ? store.pendingOutbound[env.from] : nil
        guard var peer = known ?? pending else { throw OpenError.peer }
        let plaintext = try TeleportCrypto.open(env, ownKa: keys.agreement, senderKs: peer.ks)
        if firstDelivery, !store.markSeen(env.id) { throw OpenError.replay }

        switch env.k {
        case .text:
            return .clip(.text(String(decoding: plaintext, as: UTF8.self)), id: env.id, from: peer)
        case .blob:
            let pointer = try JSONDecoder().decode(BlobPointer.self, from: plaintext)
            let bytes = try await fetchBlob(pointer, envelopeID: env.id)
            if pointer.mime.hasPrefix("text/") {
                return .clip(.text(String(decoding: bytes, as: UTF8.self)), id: env.id, from: peer)
            }
            return .clip(.image(bytes, mime: pointer.mime), id: env.id, from: peer)
        case .peer:
            guard firstDelivery, known != nil else { throw OpenError.kind }
            let update = try JSONDecoder().decode(PeerUpdate.self, from: plaintext)
            if let name = update.name { peer.name = name }
            if let fcm = update.fcm { peer.fcm = fcm }
            if let la = update.la { peer.la = la }
            if let mailbox = update.mailbox { peer.mailbox = mailbox }
            var peers = store.peers
            peers[peer.id] = peer
            store.peers = peers
            return .peerUpdated(peer)
        case .pairOK:
            guard firstDelivery, pending != nil else { throw OpenError.kind }
            // Their card carries their current name and push addresses; keys must not change.
            let card = try JSONDecoder().decode(PairingCard.self, from: plaintext)
            var confirmed = try Peer(card: card)
            guard confirmed.id == peer.id, confirmed.ka == peer.ka else { throw OpenError.peer }
            confirmed.pairedAt = Date()
            var peers = store.peers
            peers[confirmed.id] = confirmed
            store.peers = peers
            var outbound = store.pendingOutbound
            outbound[confirmed.id] = nil
            store.pendingOutbound = outbound
            return .paired(confirmed)
        case .pair:
            throw OpenError.kind  // handled above
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

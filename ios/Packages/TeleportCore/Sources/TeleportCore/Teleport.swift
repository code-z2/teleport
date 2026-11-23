import CryptoKit
import Foundation

/// Decrypted clip content.
public enum Clip: Sendable {
    case text(String)
    case image(Data, mime: String)
}

/// What a share sheet, Service or Control Center sheet sends: a clip (clipboard-sized) or a
/// file (up to 250 MB, streamed from disk).
public enum Outgoing: Sendable {
    case clip(Clip)
    case file(URL, mime: String, name: String)
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

    /// Clips (text, images) up to this go as one sealed blob and land on the clipboard.
    public static let maxBlobBytes = 10 * 1024 * 1024
    /// Files up to this go as chunked blobs (SPEC.md "Large blobs").
    public static let maxFileBytes = ChunkedBlob.maxSize

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
            fcm: store.ownFCMToken, la: store.ownLiveActivityToken.flatMap { $0.isEmpty ? nil : $0 },
            // A Mac is reached through its relay mailbox, named by its own id.
            mailbox: platform.hasMailbox ? myID : nil)
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
        removeRequest(requestID)
        return peer
    }

    /// The user tapped Deny: forget the request and tell the device, so it stops waiting.
    public func deny(_ requestID: String) {
        let request = store.pairRequests[requestID]
        removeRequest(requestID)
        guard let request, let card = try? JSONDecoder().decode(PairingCard.self, from: Data(request.cardJSON.utf8)),
              let peer = try? Peer(card: card) else { return }
        let relay = relay, signing = keys.signing
        Task {
            guard let env = try? TeleportCrypto.seal(kind: .pairNo, plaintext: Data("{}".utf8), signer: signing, recipientKa: peer.ka) else { return }
            try? await relay.send(env, to: peer)
        }
    }

    private func removeRequest(_ requestID: String) {
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
            if data.count + 16 <= Self.maxBlobBytes {
                try await sendBlob(data, mime: mime, to: peer)
            } else {
                // Too big for the clipboard path: send it as a file instead.
                let ext = mime == "image/png" ? "png" : mime == "image/gif" ? "gif" : "jpg"
                let tmp = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await sendFile(tmp, mime: mime, name: "Image.\(ext)", to: peer)
            }
        }
    }

    /// Sends whatever was shared. Files report upload progress; clips are quick.
    public func send(
        _ outgoing: Outgoing, to peer: Peer,
        progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws {
        switch outgoing {
        case .clip(let clip): try await send(clip, to: peer)
        case .file(let url, let mime, let name): try await sendFile(url, mime: mime, name: name, to: peer, progress: progress)
        }
    }

    /// Sends a file of up to 250 MB as a chunked blob, streaming: it's read, sealed and
    /// uploaded 16 MiB at a time, so even the share extension stays within its memory.
    public func sendFile(
        _ url: URL, mime: String, name: String?, to peer: Peer,
        progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws {
        let size = Int((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        guard size <= Self.maxFileBytes else { throw TeleportError.tooLarge }
        let key = SymmetricKey(size: .bits256)
        let n = Data.random(12)
        let chunks = ChunkedBlob.count(size: size)
        let totalCiphertext = Int64(size + 16 * chunks)

        let upload = try await relay.startUpload()
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var pending = Data(), etags: [String] = [], sent: Int64 = 0
            progress(0, totalCiphertext)
            for i in 0..<chunks {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: ChunkedBlob.chunkSize) ?? Data()
                pending += try ChunkedBlob.seal(chunk, index: i, last: i == chunks - 1, key: key, n: n)
                // Equal-sized parts (R2 requires it), the remainder as the last part.
                while pending.count >= ChunkedBlob.partSize {
                    let part = pending.prefix(ChunkedBlob.partSize)
                    etags.append(try await relay.uploadPart(upload, part: etags.count + 1, Data(part)))
                    pending.removeFirst(ChunkedBlob.partSize)
                    sent += Int64(part.count)
                    progress(sent, totalCiphertext)
                }
            }
            if !pending.isEmpty || etags.isEmpty {
                etags.append(try await relay.uploadPart(upload, part: etags.count + 1, pending))
                sent += Int64(pending.count)
                progress(sent, totalCiphertext)
            }
            try await relay.completeUpload(upload, etags: etags)
        } catch {
            await relay.abortUpload(upload)
            throw error
        }
        let pointer = BlobPointer(
            id: upload.id, mime: mime, size: size, key: key.withUnsafeBytes { Data($0) }.base64URL, n: n.base64URL,
            c: ChunkedBlob.chunkSize, name: name)
        let env = try TeleportCrypto.seal(
            kind: .blob, plaintext: try JSONEncoder().encode(pointer), signer: keys.signing, recipientKa: peer.ka)
        try await relay.send(env, to: peer, hint: "file")
    }

    private func sendBlob(_ bytes: Data, mime: String, to peer: Peer) async throws {
        guard bytes.count + 16 <= Self.maxBlobBytes else { throw TeleportError.tooLarge }
        let sealed = try TeleportCrypto.sealBlob(bytes)
        let id = try await relay.putBlob(sealed.ciphertext)
        let pointer = BlobPointer(
            id: id, mime: mime, size: bytes.count, key: sealed.key.base64URL, n: sealed.nonce.base64URL)
        let env = try TeleportCrypto.seal(
            kind: .blob, plaintext: try JSONEncoder().encode(pointer), signer: keys.signing, recipientKa: peer.ka)
        // Photos get an iPhone Live Activity (Copy / Save); long text stays a plain notification.
        try await relay.send(env, to: peer, hint: mime.hasPrefix("image/") ? "image" : nil)
    }

    public var inbox: Inbox { Inbox(appGroup: config.appGroup) }

    /// The relay request for a blob, for a background URLSession download (the notification
    /// extension starts it; the system finishes it even if the phone is locked).
    public func blobRequest(_ p: BlobPointer) -> URLRequest {
        var r = relay.request("v1/blob/\(p.id)", method: "GET")
        r.timeoutInterval = 300
        return r
    }

    /// Downloads and decrypts a received file to `destination`, streaming, then deletes it
    /// from the relay. Progress covers the download; decrypting is quick by comparison.
    public func downloadFile(
        _ p: BlobPointer, to destination: URL,
        progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws {
        let ciphertext = try await relay.downloadBlob(p.id, progress: progress)
        defer { try? FileManager.default.removeItem(at: ciphertext) }
        try Self.decryptFile(p, ciphertext: ciphertext, to: destination)
        try? await relay.deleteBlob(p.id)
    }

    public func deleteBlob(_ p: BlobPointer) async { try? await relay.deleteBlob(p.id) }

    /// Decrypts a downloaded chunked blob into `destination`, a chunk at a time.
    public static func decryptFile(_ p: BlobPointer, ciphertext: URL, to destination: URL) throws {
        guard let chunk = p.c, chunk > 0, p.size <= maxFileBytes,
              let keyData = Data(base64URL: p.key), let n = Data(base64URL: p.n) else { throw OpenError.encoding }
        let key = SymmetricKey(data: keyData)
        let chunks = ChunkedBlob.count(size: p.size, chunk: chunk)
        let expected = p.size + 16 * chunks
        let actual = (try FileManager.default.attributesOfItem(atPath: ciphertext.path)[.size] as? NSNumber)?.intValue ?? -1
        guard actual == expected else { throw OpenError.decrypt }

        let partial = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        do {
            let input = try FileHandle(forReadingFrom: ciphertext)
            let output = try FileHandle(forWritingTo: partial)
            defer { try? input.close(); try? output.close() }
            for i in 0..<chunks {
                let plain = i == chunks - 1 ? p.size - i * chunk : chunk
                guard let sealed = try input.read(upToCount: plain + 16), sealed.count == plain + 16 else { throw OpenError.decrypt }
                try output.write(contentsOf: try ChunkedBlob.open(sealed, index: i, last: i == chunks - 1, key: key, n: n))
            }
            try output.close()
            _ = try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    // MARK: Receive

    public enum Received: Sendable {
        case clip(Clip, id: String, from: Peer)
        /// A large file: verified and decrypted pointer only. Download with `downloadFile`
        /// (not in the notification extension, which has too little memory and time).
        case file(BlobPointer, id: String, from: Peer)
        case peerUpdated(Peer)
        /// Someone scanned our QR code; the user must Allow or Deny.
        case pairRequest(PairRequest)
        /// A device we scanned accepted.
        case paired(Peer)
        /// A device we scanned tapped Deny.
        case declined(Peer)
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
        let pending = env.k == .pairOK || env.k == .pairNo ? store.pendingOutbound[env.from] : nil
        guard var peer = known ?? pending else { throw OpenError.peer }
        let plaintext = try TeleportCrypto.open(env, ownKa: keys.agreement, senderKs: peer.ks)
        if firstDelivery, !store.markSeen(env.id) { throw OpenError.replay }

        switch env.k {
        case .text:
            return .clip(.text(String(decoding: plaintext, as: UTF8.self)), id: env.id, from: peer)
        case .blob:
            let pointer = try JSONDecoder().decode(BlobPointer.self, from: plaintext)
            if pointer.isChunked { return .file(pointer, id: env.id, from: peer) }
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
        case .pairNo:
            guard firstDelivery, let pending, known == nil else { throw OpenError.kind }
            var outbound = store.pendingOutbound
            outbound[pending.id] = nil
            store.pendingOutbound = outbound
            return .declined(pending)
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

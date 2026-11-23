import CryptoKit
import Foundation

/// The phone's end of a file session with a paired Mac: list, download and upload.
/// Several operations may run at once; each has its own id.
public actor FileSessionClient {
    private let pipe: any SessionPipe
    private var tx: FrameCipher?
    private var rx: FrameCipher?
    private var nextID: UInt32 = 1
    private var routes: [UInt32: AsyncThrowingStream<SessionFrame, Error>.Continuation] = [:]
    private var failure: Error?
    private var reader: Task<Void, Never>?

    /// Opens a session to `mac` through its relay mailbox.
    /// Opens a session to `mac`: through its relay mailbox, then, if the computer is on the
    /// same network, moves to a direct connection (SPEC.md "Direct connections"), which is
    /// as fast as the Wi-Fi instead of the home internet's upload speed.
    public static func connect(teleport: Teleport, to mac: Peer, direct: Bool = true) async throws -> FileSessionClient {
        guard mac.platform.hasMailbox, let mailbox = mac.mailbox else { throw FileSessionError.protocolError }
        if await teleport.relay.isOnline(mailbox: mailbox) == false { throw FileSessionError.offline }
        let pipe = WebSocketPipe(teleport.relay.request("v1/mailbox/\(mailbox)/session", method: "GET"))
        let relayed: FileSessionClient
        do {
            relayed = try await handshake(pipe: pipe, signer: teleport.keys.signing, mailbox: mailbox, macKs: mac.ks)
        } catch {
            pipe.close()
            throw error
        }
        guard direct, let local = await relayed.upgrade(signer: teleport.keys.signing, mailbox: mailbox, macKs: mac.ks) else {
            return relayed
        }
        await relayed.close()
        return local
    }

    /// True for a direct (same-network) session.
    public private(set) var isDirect = false

    /// Asks the computer for its local addresses (over this session, so they're authentic)
    /// and tries each briefly. A new session with its own handshake, or nil.
    func upgrade(signer: any SigningKey, mailbox: String, macKs: Data) async -> FileSessionClient? {
        guard let hosts = try? await endpoints(), !hosts.isEmpty else { return nil }
        for hostPort in hosts {
            let parts = hostPort.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
            do {
                let pipe = try await TCPPipe.connect(host: String(parts[0]), port: port)
                do {
                    let client = try await Self.handshake(pipe: pipe, signer: signer, mailbox: mailbox, macKs: macKs)
                    await client.markDirect()
                    return client
                } catch {
                    pipe.close()
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func markDirect() { isDirect = true }

    /// The computer's direct-connection addresses ("ip:port").
    public func endpoints() async throws -> [String] {
        let (id, stream) = try begin { Control("endpoints", id: $0) }
        defer { end(id) }
        for try await frame in stream {
            guard case .control(let c) = frame else { continue }
            try Self.check(c)
            if c.op == "endpoints" { return c.hosts ?? [] }
        }
        throw failure ?? FileSessionError.closed
    }

    /// The handshake over any pipe (tests use an in-memory one).
    public static func handshake(
        pipe: any SessionPipe, signer: any SigningKey, mailbox: String, macKs: Data,
        now: Int = Int(Date().timeIntervalSince1970)
    ) async throws -> FileSessionClient {
        let eph = P256.KeyAgreement.PrivateKey()
        let epk = eph.publicKey.x963Representation.base64URL
        let n = Data.random(16).base64URL
        let from = TeleportCrypto.fingerprint(signer.publicKey)
        let helloT = SessionCrypto.helloTranscript(mailbox: mailbox, from: from, epk: epk, n: n, ts: now)
        let hello = SessionCrypto.Hello(from: from, epk: epk, n: n, ts: now, sig: try signer.sign(helloT).base64URL)
        let client = FileSessionClient(pipe: pipe)
        pipe.send(try JSONEncoder().encode(hello))
        try await client.start(helloT: helloT, ephemeral: eph, macKs: macKs)
        return client
    }

    private init(pipe: any SessionPipe) {
        self.pipe = pipe
    }

    /// Reads the Mac's reply to the hello, then keeps reading frames for the life of the session.
    private func start(helloT: Data, ephemeral: P256.KeyAgreement.PrivateKey, macKs: Data) async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            reader = Task {
                var it = pipe.incoming.makeAsyncIterator()
                do {
                    guard let first = try await it.next() else { throw FileSessionError.closed }
                    try accept(first, helloT: helloT, ephemeral: ephemeral, macKs: macKs)
                } catch {
                    ready.resume(throwing: error)
                    return
                }
                ready.resume()
                do {
                    while let frame = try await it.next() { try receive(frame) }
                    fail(FileSessionError.closed)
                } catch {
                    fail(error is FileSessionError ? error : FileSessionError.closed)
                }
            }
        }
    }

    private func accept(_ first: Data, helloT: Data, ephemeral: P256.KeyAgreement.PrivateKey, macKs: Data) throws {
        let tag = try JSONDecoder().decode(SessionCrypto.Tagged.self, from: first)
        if tag.t == "error" { throw FileSessionError.refused(tag.code ?? "unknown") }
        let accept = try JSONDecoder().decode(SessionCrypto.Accept.self, from: first)
        let acceptT = SessionCrypto.acceptTranscript(hello: helloT, epk: accept.epk, n: accept.n)
        guard let sig = Data(base64URL: accept.sig), let macEpk = Data(base64URL: accept.epk),
              SessionCrypto.verify(sig, of: acceptT, by: macKs)
        else { throw FileSessionError.untrusted }
        let keys = try SessionCrypto.keys(ownEphemeral: ephemeral, otherEpk: macEpk, acceptTranscript: acceptT)
        tx = FrameCipher(key: keys.phoneToMac, dir: SessionCrypto.phoneToMac)
        rx = FrameCipher(key: keys.macToPhone, dir: SessionCrypto.macToPhone)
    }

    private func receive(_ frame: Data) throws {
        let message: SessionFrame
        guard var rx else { throw FileSessionError.protocolError }
        do { message = try SessionFrame.decode(try rx.open(frame)) } catch { throw FileSessionError.protocolError }
        self.rx = rx
        routes[message.id]?.yield(message)
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        for route in routes.values { route.finish(throwing: error) }
        routes = [:]
        pipe.close()
    }

    public func close() {
        reader?.cancel()
        fail(FileSessionError.closed)
    }

    // MARK: Plumbing

    private func send(_ frame: SessionFrame) throws {
        if let failure { throw failure }
        guard var tx else { throw FileSessionError.closed }
        let sealed = try tx.seal(try frame.encoded())
        self.tx = tx
        pipe.send(sealed)
    }

    /// Starts an operation: registers its reply stream, then sends the request.
    private func begin(_ request: (UInt32) -> Control) throws -> (UInt32, AsyncThrowingStream<SessionFrame, Error>) {
        if let failure { throw failure }
        let id = nextID
        nextID &+= 1
        let (stream, continuation) = AsyncThrowingStream<SessionFrame, Error>.makeStream()
        routes[id] = continuation
        try send(.control(request(id)))
        return (id, stream)
    }

    private func end(_ id: UInt32) {
        routes.removeValue(forKey: id)?.finish()
    }

    private func cancelRemote(_ id: UInt32) {
        try? send(.control(Control("cancel", id: id)))
        end(id)
    }

    private static func check(_ c: Control) throws {
        if c.op == "error" { throw FileSessionError.remote(code: c.code ?? "io", message: c.message ?? "The Mac couldn't do that.") }
    }

    // MARK: Operations

    public func list(_ path: String) async throws -> [FileEntry] {
        let (id, stream) = try begin { var c = Control("list", id: $0); c.path = path; return c }
        defer { end(id) }
        for try await frame in stream {
            guard case .control(let c) = frame else { continue }
            try Self.check(c)
            if c.op == "entries" { return c.entries ?? [] }
        }
        throw FileSessionError.closed
    }

    /// Where an interrupted download of `destination` is kept, so the next try resumes.
    public static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).teleport-part")
    }

    /// Downloads `path` into `destination` (replaced if present). If an earlier attempt was cut
    /// off (the connection dropped), it resumes from where that one stopped: the bytes already
    /// here are hashed again and the computer sends only the rest. Cancel the calling task to
    /// stop (that discards the partial file; a dropped connection keeps it).
    /// `keepPartialOnCancel`: previews keep what they have when you leave, so reopening resumes.
    public func download(
        _ path: String, to destination: URL, keepPartialOnCancel: Bool = false,
        progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws {
        let partial = Self.partialURL(for: destination)
        var hasher = SHA256()
        var offset: Int64 = 0
        if FileManager.default.fileExists(atPath: partial.path), let input = try? FileHandle(forReadingFrom: partial) {
            while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
                offset += Int64(chunk.count)
            }
            try? input.close()
        } else {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let start = offset
        let (id, stream) = try begin { var c = Control("download", id: $0); c.path = path; c.offset = start; return c }
        var finished = false
        defer {
            if finished {
                end(id)
            } else {
                cancelRemote(id)
                // Keep what we have unless it was a deliberate cancel or the bytes were wrong.
                if Task.isCancelled && !keepPartialOnCancel { try? FileManager.default.removeItem(at: partial) }
            }
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var total: Int64 = 0, received = offset, acked = offset

        for try await frame in stream {
            try Task.checkCancellation()
            switch frame {
            case .data(_, let bytes):
                try handle.write(contentsOf: bytes)
                hasher.update(data: bytes)
                received += Int64(bytes.count)
                if received - acked >= SessionCrypto.ackEvery {
                    var ack = Control("ack", id: id); ack.bytes = received
                    try send(.control(ack))
                    acked = received
                }
                progress(received, total)
            case .control(let c):
                try Self.check(c)
                switch c.op {
                case "meta":
                    total = c.size ?? 0
                    if start > total {
                        // The file shrank since: start over.
                        try? FileManager.default.removeItem(at: partial)
                        throw FileSessionError.closed
                    }
                    progress(received, total)
                case "done":
                    try handle.close()
                    guard Data(hasher.finalize()).base64URL == c.sha256 else {
                        try? FileManager.default.removeItem(at: partial)  // changed on the computer: next try starts fresh
                        throw FileSessionError.hashMismatch
                    }
                    _ = try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: partial, to: destination)
                    finished = true
                    return
                case "cancel":
                    throw CancellationError()
                default: break
                }
            }
        }
        try Task.checkCancellation()
        throw failure ?? FileSessionError.closed
    }

    /// Up to 2 MiB of `path` from `offset` (streaming: a player asks for what it needs next).
    public func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        let (id, stream) = try begin {
            var c = Control("read", id: $0); c.path = path; c.offset = offset; c.size = Int64(min(length, SessionCrypto.maxRead)); return c
        }
        defer { end(id) }
        var data = Data()
        for try await frame in stream {
            switch frame {
            case .data(_, let bytes): data.append(bytes)
            case .control(let c):
                try Self.check(c)
                if c.op == "done" { return data }
            }
        }
        throw failure ?? FileSessionError.closed
    }

    /// A JPEG thumbnail (longest side `px`) rendered by Quick Look on the Mac, or nil
    /// if the Mac can't preview this kind of file.
    public func thumbnail(_ path: String, px: Int = 512) async throws -> Data? {
        let (id, stream) = try begin { var c = Control("thumbnail", id: $0); c.path = path; c.px = px; return c }
        defer { end(id) }
        var data = Data()
        for try await frame in stream {
            switch frame {
            case .data(_, let bytes):
                data.append(bytes)
            case .control(let c):
                if c.op == "error" && c.code == "unsupported" { return nil }
                try Self.check(c)
                if c.op == "done" {
                    guard Data(SHA256.hash(data: data)).base64URL == c.sha256 else { throw FileSessionError.hashMismatch }
                    return data
                }
            }
        }
        throw failure ?? FileSessionError.closed
    }

    /// Uploads `source` into the Mac folder `dir`. Returns the name the Mac saved it under.
    public func upload(
        _ source: URL, to dir: String, name: String,
        progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws -> String {
        let size = Int64((try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let (id, stream) = try begin {
            var c = Control("upload", id: $0); c.dir = dir; c.name = name; c.size = size; return c
        }
        var finished = false
        defer { if finished { end(id) } else { cancelRemote(id) } }
        var replies = stream.makeAsyncIterator()

        // Wait for `ready` (or an error), then stream the file.
        var savedName = name
        while true {
            guard let frame = try await replies.next() else { throw failure ?? FileSessionError.closed }
            guard case .control(let c) = frame else { continue }
            try Self.check(c)
            if c.op == "ready" { savedName = c.name ?? name; break }
        }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hasher = SHA256()
        var sent: Int64 = 0, acked: Int64 = 0
        progress(0, size)
        while let chunk = try handle.read(upToCount: SessionCrypto.chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            // Respect the window: wait for acks before sending more.
            while sent - acked >= SessionCrypto.window {
                guard let frame = try await replies.next() else { throw failure ?? FileSessionError.closed }
                if case .control(let c) = frame {
                    try Self.check(c)
                    if c.op == "ack" { acked = max(acked, c.bytes ?? 0) }
                    if c.op == "cancel" { throw CancellationError() }
                }
            }
            try send(.data(id, chunk))
            hasher.update(data: chunk)
            sent += Int64(chunk.count)
            progress(sent, size)
        }
        var done = Control("done", id: id); done.sha256 = Data(hasher.finalize()).base64URL
        try send(.control(done))

        while let frame = try await replies.next() {
            guard case .control(let c) = frame else { continue }
            try Self.check(c)
            if c.op == "saved" { finished = true; return c.name ?? savedName }
            if c.op == "cancel" { throw CancellationError() }
        }
        throw failure ?? FileSessionError.closed
    }
}

/// A WebSocket to the relay's session endpoint.
final class WebSocketPipe: SessionPipe, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(_ request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 2 * 1024 * 1024
        (incoming, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                continuation.yield(data)
                receive()
            case .success:
                receive()  // text isn't used on sessions
            case .failure(let error):
                let status = (task.response as? HTTPURLResponse)?.statusCode
                continuation.finish(throwing: status == 503 ? FileSessionError.offline : error)
            }
        }
    }

    func send(_ data: Data) {
        task.send(.data(data)) { [weak self] error in
            if error != nil { self?.continuation.finish(throwing: FileSessionError.closed) }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }
}

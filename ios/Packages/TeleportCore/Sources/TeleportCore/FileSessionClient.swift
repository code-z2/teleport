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
    public static func connect(teleport: Teleport, to mac: Peer) async throws -> FileSessionClient {
        guard mac.platform.hasMailbox, let mailbox = mac.mailbox else { throw FileSessionError.protocolError }
        if await teleport.relay.isOnline(mailbox: mailbox) == false { throw FileSessionError.offline }
        let pipe = WebSocketPipe(teleport.relay.request("v1/mailbox/\(mailbox)/session", method: "GET"))
        do {
            return try await handshake(pipe: pipe, signer: teleport.keys.signing, mailbox: mailbox, macKs: mac.ks)
        } catch {
            pipe.close()
            throw error
        }
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

    /// Downloads `path` into `destination` (replaced if present). Cancel the calling task to stop.
    public func download(
        _ path: String, to destination: URL,
        progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws {
        let (id, stream) = try begin { var c = Control("download", id: $0); c.path = path; return c }
        let partial = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
        var finished = false
        defer {
            if !finished { cancelRemote(id); try? FileManager.default.removeItem(at: partial) } else { end(id) }
        }
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0, received: Int64 = 0, acked: Int64 = 0

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
                    progress(0, total)
                case "done":
                    try handle.close()
                    guard Data(hasher.finalize()).base64URL == c.sha256 else { throw FileSessionError.hashMismatch }
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

import Foundation
import Network

/// The direct path for file sessions on the same network (SPEC.md "Direct connections"):
/// plain TCP carrying exactly what the relay would, framed as u32 BE length ‖ payload. The
/// session's handshake and encryption are unchanged, so the link needs no security of its own.
public enum LocalLink {
    public static let maxFrame = 4 * 1024 * 1024

    /// This computer's private IPv4 addresses (home networks), best first.
    public static func addresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isPrivate(ip) { out.append(ip) }
        }
        return out
    }

    static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }
}

/// A session pipe over one TCP connection (either end).
public final class TCPPipe: SessionPipe, @unchecked Sendable {
    private let connection: NWConnection
    public let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let queue = DispatchQueue(label: "app.teleport.tcp")

    public init(_ connection: NWConnection) {
        self.connection = connection
        (incoming, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    }

    /// Server side: an accepted connection.
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.continuation.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        readFrame()
    }

    /// Client side: connects within `timeout` seconds, or throws.
    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 1.5) async throws -> TCPPipe {
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]  // direct means the local network, never mobile data
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        let pipe = TCPPipe(connection)
        let ready = OnceFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if ready.set() { cont.resume() }
                case .failed(let e), .waiting(let e): if ready.set() { connection.cancel(); cont.resume(throwing: e) }
                case .cancelled: if ready.set() { cont.resume(throwing: FileSessionError.closed) }
                default: break
                }
            }
            connection.start(queue: pipe.queue)
            pipe.queue.asyncAfter(deadline: .now() + timeout) {
                if ready.set() { connection.cancel(); cont.resume(throwing: FileSessionError.offline) }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: pipe.continuation.finish()
            default: break
            }
        }
        pipe.readFrame()
        return pipe
    }

    private func readFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, done, error in
            guard let self else { return }
            guard error == nil, let header, header.count == 4 else { return self.continuation.finish() }
            let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length <= LocalLink.maxFrame else { return self.close() }
            if length == 0 { self.continuation.yield(Data()); return self.readFrame() }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard error == nil, let body, body.count == length else { return self.continuation.finish() }
                self.continuation.yield(body)
                if done { self.continuation.finish() } else { self.readFrame() }
            }
        }
    }

    public func send(_ data: Data) {
        var frame = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.continuation.finish() }
        })
    }

    public func close() {
        connection.cancel()
        continuation.finish()
    }
}

/// Resumes a continuation at most once across racing callbacks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// True the first time only.
    func set() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}

/// Accepts direct sessions on a TCP port (any free one), handing each connection's pipe to
/// `onSession`, which runs a FileServer on it like a relay session.
public final class LocalListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.teleport.listener")

    public init(onSession: @escaping @Sendable (TCPPipe) -> Void) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            let pipe = TCPPipe(connection)
            pipe.start()
            onSession(pipe)
        }
    }

    /// Starts listening; returns the port.
    public func start() async throws -> UInt16 {
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.set() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e): if once.set() { cont.resume(throwing: e) }
                case .cancelled: if once.set() { cont.resume(throwing: FileSessionError.closed) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    /// "ip:port" for each private address this computer has.
    public static func endpoints(port: UInt16) -> [String] { LocalLink.addresses().map { "\($0):\(port)" } }
}

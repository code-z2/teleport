import AppKit
import Foundation
import Network
import OSLog
import TeleportCore

private let log = Logger(subsystem: "app.teleport.mac", category: "mailbox")

/// The Mac's live connection to its relay mailbox (protocol/SPEC.md "Mac mailbox").
/// Proves ownership by signing the mailbox's challenge with this Mac's Secure Enclave key,
/// keeps the connection alive, and reconnects with backoff after sleep or network changes.
@MainActor
final class MailboxConnection {
    enum State: Equatable {
        case connecting
        case online(since: Date)
        case offline(String)
    }

    private(set) var state: State = .connecting {
        didSet {
            log.notice("mailbox \(self.teleport.myID, privacy: .public): \(String(describing: self.state), privacy: .public)")
            onState(state)
        }
    }
    var onState: (State) -> Void = { _ in }
    /// Called with each envelope's JSON as delivered by a phone.
    var onEnvelope: (String) -> Void = { _ in }
    /// Names of the phones browsing this Mac right now.
    var onBrowsers: ([String]) -> Void = { _ in }
    /// Read when each file session starts.
    var showHiddenFiles: () -> Bool = { false }

    /// Open file sessions, by raw 16-byte sid.
    private var sessions: [Data: SessionEntry] = [:]
    private struct SessionEntry { let pipe: MailboxSessionPipe; var phone: String? }
    /// Sessions with no traffic for this long are closed, so a phone that vanished without
    /// hanging up can't stay "browsing". The phone reconnects by itself on its next action.
    private static let sessionIdleLimit: TimeInterval = 5 * 60
    private var idleTimer: Timer?

    private let teleport: Teleport
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var backoff: TimeInterval = 1
    private var pingTimer: Timer?
    private var lastHeard = Date()
    private var reconnectWork: DispatchWorkItem?
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    init(teleport: Teleport) {
        self.teleport = teleport
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectNow() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.disconnect(reason: "Mac is asleep") }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied {
                    if case .offline = self.state { self.reconnectNow() }
                } else {
                    self.disconnect(reason: "No internet connection")
                }
            }
        }
        pathMonitor.start(queue: .main)
        connect()
    }

    func reconnectNow() {
        backoff = 1
        connect()
    }

    // MARK: Connection

    private func connect() {
        reconnectWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        generation += 1
        let gen = generation
        state = .connecting
        var request = teleport.relay.request("v1/mailbox/\(teleport.myID)/connect", method: "GET")
        request.timeoutInterval = 30
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(task, gen)
    }

    private func disconnect(reason: String) {
        endSessions()
        generation += 1
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .offline(reason)
    }

    private func scheduleReconnect(_ reason: String) {
        endSessions()
        pingTimer?.invalidate()
        state = .offline(reason)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.connect() } }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
        backoff = min(backoff * 2, 60)
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    self.lastHeard = Date()
                    self.handle(message, task)
                    self.receive(task, gen)
                case .failure(let error):
                    let code = task.closeCode.rawValue
                    self.scheduleReconnect(Self.describe(code: code, error: error))
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, _ task: URLSessionWebSocketTask) {
        if case .data(let data) = message {
            // A session frame: sid (16 bytes) ‖ payload.
            guard data.count >= 16 else { return }
            sessions[Data(data.prefix(16))]?.pipe.deliver(Data(data.dropFirst(16)))
            return
        }
        guard case .string(let text) = message, text != "pong",
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["t"] as? String
        else { return }
        switch type {
        case "challenge":
            guard let nonce = obj["nonce"] as? String else { return }
            let message = Data("teleport/v1/mailbox|\(teleport.myID)|\(nonce)".utf8)
            guard let sig = try? teleport.keys.signing.sign(message) else {
                return scheduleReconnect("Couldn't sign with this Mac's key")
            }
            send(["t": "auth", "ks": teleport.keys.signing.publicKey.base64URL, "sig": sig.base64URL])
        case "ready":
            backoff = 1
            state = .online(since: Date())
            startPing()
        case "env":
            guard let env = obj["env"],
                  let data = try? JSONSerialization.data(withJSONObject: env),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            onEnvelope(json)
        case "open":
            if let sid = obj["sid"] as? String, let raw = Data(base64URL: sid), raw.count == 16 {
                openSession(raw, task)
            }
        case "close":
            if let sid = obj["sid"] as? String, let raw = Data(base64URL: sid) {
                sessions.removeValue(forKey: raw)?.pipe.finish()
                reportBrowsers()
            }
        default:
            break
        }
    }

    // MARK: File sessions

    private func closeIdleSessions() {
        for (sid, entry) in sessions where entry.pipe.idleFor > Self.sessionIdleLimit {
            log.notice("file session idle, closing")
            entry.pipe.close()
            sessions[sid] = nil
        }
        reportBrowsers()
        if sessions.isEmpty { idleTimer?.invalidate(); idleTimer = nil }
    }

    private func openSession(_ sid: Data, _ task: URLSessionWebSocketTask) {
        if idleTimer == nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeIdleSessions() }
            }
        }
        let pipe = MailboxSessionPipe(sid: sid, task: task)
        sessions[sid] = SessionEntry(pipe: pipe, phone: nil)
        let teleport = teleport
        let server = FileServer(
            pipe: pipe, signer: teleport.keys.signing, mailbox: teleport.myID,
            options: .init(home: FileManager.default.homeDirectoryForCurrentUser, showHidden: showHiddenFiles()),
            phones: { teleport.store.peers[$0] })
        log.notice("file session opened")
        Task { [weak self] in
            // Learn who it is once the handshake is through, for the menu.
            Task { @MainActor [weak self] in
                for _ in 0..<50 {
                    if let phone = await server.phone {
                        self?.sessions[sid]?.phone = phone.name
                        self?.reportBrowsers()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            await server.run()
            await MainActor.run {
                guard let self else { return }
                self.sessions[sid] = nil
                self.reportBrowsers()
                log.notice("file session closed")
            }
        }
    }

    private func endSessions() {
        for entry in sessions.values { entry.pipe.finish() }
        sessions = [:]
        reportBrowsers()
    }

    private func reportBrowsers() {
        onBrowsers(Array(Set(sessions.values.compactMap(\.phone))).sorted())
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    /// Pings every 20 s; the relay answers "pong" even while hibernating. If nothing has come
    /// back for 50 s the connection is dead (a silently dropped socket never errors), so reconnect.
    private func startPing() {
        pingTimer?.invalidate()
        lastHeard = Date()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.lastHeard) > 50 {
                    log.notice("mailbox: no pong for 50 s, reconnecting")
                    return self.reconnectNow()
                }
                self.task?.send(.string("ping")) { _ in }
            }
        }
    }

    private static func describe(code: Int, error: Error) -> String {
        switch code {
        case 4000: "Connected from another session"
        case 4401: "The relay rejected this Mac's key"
        case 4408: "Sign-in to the relay timed out"
        default: (error as NSError).code == NSURLErrorNotConnectedToInternet ? "No internet connection" : "Can't reach the relay"
        }
    }
}

/// One file session's pipe through the mailbox WebSocket: frames go out as sid ‖ payload.
final class MailboxSessionPipe: SessionPipe, @unchecked Sendable {
    let sid: Data
    private let task: URLSessionWebSocketTask
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var closed = false

    init(sid: Data, task: URLSessionWebSocketTask) {
        self.sid = sid
        self.task = task
        (incoming, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    }

    private var lastActivity = Date()
    /// Seconds since the last frame either way.
    var idleFor: TimeInterval { lock.withLock { Date().timeIntervalSince(lastActivity) } }

    func deliver(_ data: Data) {
        lock.withLock { lastActivity = Date() }
        continuation.yield(data)
    }

    /// The phone went away (or the mailbox connection did).
    func finish() {
        lock.withLock { closed = true }
        continuation.finish()
    }

    func send(_ data: Data) {
        guard !lock.withLock({ lastActivity = Date(); return closed }) else { return }
        task.send(.data(sid + data)) { _ in }
    }

    /// The server is done: tell the mailbox to hang up on the phone.
    func close() {
        let wasClosed = lock.withLock { () -> Bool in defer { closed = true }; return closed }
        continuation.finish()
        guard !wasClosed else { return }
        let text = #"{"t":"close","sid":"\#(sid.base64URL)"}"#
        task.send(.string(text)) { _ in }
    }
}

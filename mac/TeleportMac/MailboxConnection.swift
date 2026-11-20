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

    private let teleport: Teleport
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var backoff: TimeInterval = 1
    private var pingTimer: Timer?
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
        generation += 1
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .offline(reason)
    }

    private func scheduleReconnect(_ reason: String) {
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
            // File sessions arrive in phase 5. Until then, decline politely.
            if let sid = obj["sid"] as? String { send(["t": "close", "sid": sid]) }
        default:
            break
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.task?.send(.string("ping")) { _ in } }
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

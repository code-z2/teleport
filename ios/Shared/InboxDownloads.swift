import Foundation
import TeleportCore

/// Background downloads of incoming photos and files. The notification extension starts
/// them (it can't wait: ~24 MB, ~30 s); iOS carries them on even with the phone locked; the
/// app reconnects to the same session to show progress and, when one finishes, decrypts it
/// into the inbox and flips the Live Activity to Copy / Save.
final class InboxDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "app.teleport.inbox"
    static let shared = InboxDownloads()

    private let lock = NSLock()
    private var session: URLSession?
    private var backgroundCompletion: (() -> Void)?

    private static var appGroup: String { TeleportConfig.fromBundle().appGroup }

    private func makeSession(delegate: URLSessionDelegate?) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sharedContainerIdentifier = Self.appGroup  // so the app gets the extension's downloads
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Notification extension: hand the download to the system and return at once.
    static func start(_ request: URLRequest, id: String) {
        let session = InboxDownloads().makeSession(delegate: nil)
        let task = session.downloadTask(with: request)
        task.taskDescription = id
        task.resume()
    }

    /// App: attach to the session (at launch, and when iOS wakes us for it).
    func connect(completion: (() -> Void)? = nil) {
        lock.withLock {
            if let completion { backgroundCompletion = completion }
            if session == nil { session = makeSession(delegate: self) }
        }
    }

    func cancel(_ id: String) async {
        connect()
        guard let session = lock.withLock({ session }) else { return }
        for task in await session.allTasks where task.taskDescription == id { task.cancel() }
    }

    // MARK: Delegate (app only)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let inbox = Inbox(appGroup: Self.appGroup)
        guard let item = inbox.item(id) else { return }
        if fraction - (item.progress ?? 0) >= 0.02 || fraction >= 1 { inbox.update(id) { $0.progress = fraction } }
        Task { @MainActor in FileActivity.progress(item.env, fraction, name: item.name) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let inbox = Inbox(appGroup: Self.appGroup)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let item = inbox.item(id) else {
            inbox.update(id) { $0.state = .failed }
            if let env = inbox.item(id)?.env { Task { @MainActor in FileActivity.finish(env, note: "No longer available") } }
            return
        }
        // The system deletes `location` when this returns: move it first.
        let cipher = inbox.ciphertext(id)
        try? FileManager.default.removeItem(at: cipher)
        do { try FileManager.default.moveItem(at: location, to: cipher) } catch { return }

        do {
            let teleport = try Teleport()
            guard case .file(let pointer, _, _) = try awaitReceive(teleport, item.env) else { throw OpenError.kind }
            try Teleport.decryptFile(pointer, ciphertext: cipher, to: inbox.file(item))
            try? FileManager.default.removeItem(at: cipher)
            inbox.update(id) { $0.state = .ready; $0.progress = nil }
            Task { await teleport.deleteBlob(pointer) }
            Task { @MainActor in FileActivity.ready(item.env, name: item.name) }
        } catch {
            inbox.update(id) { $0.state = .failed }
            Task { @MainActor in FileActivity.finish(item.env, note: "Couldn't open the file") }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let inbox = Inbox(appGroup: Self.appGroup)
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        inbox.update(id) { $0.state = cancelled ? .cancelled : .failed }
        if let env = inbox.item(id)?.env, !cancelled {
            Task { @MainActor in FileActivity.finish(env, note: "Download failed") }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (() -> Void)? in defer { backgroundCompletion = nil }; return backgroundCompletion }
        DispatchQueue.main.async { completion?() }
    }

    /// The pointer only needs verifying and decrypting (no network), so this is quick.
    private func awaitReceive(_ teleport: Teleport, _ env: String) throws -> Teleport.Received {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await teleport.receive(env, firstDelivery: false)) }
            catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    private final class ResultBox: @unchecked Sendable { var result: Result<Teleport.Received, Error>? }
}

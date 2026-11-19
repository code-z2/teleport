import TeleportCore
import UserNotifications

/// Runs for every alert push with mutable-content (≈24 MB, ~30 s budget).
/// Verifies + decrypts, replaces the generic "New clip" with a preview, attaches images,
/// and applies peer token updates. It cannot write the clipboard — the "Copy" action does.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    // Guarded by `lock`: delivered exactly once, by whichever of finish/timeout comes first.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.withLock {
            self.contentHandler = contentHandler
            self.content = content
        }
        guard let env = content.userInfo["env"] as? String else { return deliver(nil) }
        Task { deliver(await Self.render(env)) }
    }

    override func serviceExtensionTimeWillExpire() {
        deliver(nil)
    }

    private struct Rendered: Sendable {
        var title: String
        var body: String
        var attachment: URL?
        var actionable = true
    }

    private func deliver(_ rendered: Rendered?) {
        let pending: ((UNNotificationContent) -> Void, UNMutableNotificationContent)? = lock.withLock {
            defer { contentHandler = nil; content = nil }
            guard let contentHandler, let content else { return nil }
            return (contentHandler, content)
        }
        guard let (handler, content) = pending else { return }
        if let rendered {
            content.title = rendered.title
            content.body = rendered.body
            if !rendered.actionable { content.categoryIdentifier = "" }
            if let url = rendered.attachment, let a = try? UNNotificationAttachment(identifier: "clip", url: url) {
                content.attachments = [a]
            }
        }
        handler(content)
    }

    private static func render(_ env: String) async -> Rendered {
        do {
            let teleport = try Teleport()
            let from = teleport.store.peer?.name ?? "your phone"
            switch try await teleport.receive(env, firstDelivery: true) {
            case .clip(.text(let text), _):
                return Rendered(title: "Clip from \(from)", body: String(text.prefix(300)))
            case .clip(.image(let data, let mime), let id):
                return Rendered(
                    title: "Image from \(from)", body: "Tap Copy to put it on the clipboard",
                    attachment: writeAttachment(data, mime: mime, id: id))
            case .peerUpdated(let peer):
                return Rendered(title: "Teleport", body: "\(peer.name) reconnected", actionable: false)
            }
        } catch {
            return Rendered(title: "Teleport", body: "Couldn't verify a clip (\(error))", actionable: false)
        }
    }

    private static func writeAttachment(_ data: Data, mime: String, id: String) -> URL? {
        let ext = mime == "image/png" ? "png" : (mime == "image/gif" ? "gif" : "jpg")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(id).\(ext)")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}

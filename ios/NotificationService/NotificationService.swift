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
        /// nil keeps the category the relay set ("CLIP"); "" removes the actions.
        var category: String?
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
            if let category = rendered.category { content.categoryIdentifier = category }
            if let url = rendered.attachment, let a = try? UNNotificationAttachment(identifier: "clip", url: url) {
                content.attachments = [a]
            }
        }
        handler(content)
    }

    private static func render(_ env: String) async -> Rendered {
        do {
            let teleport = try Teleport()
            switch try await teleport.receive(env, firstDelivery: true) {
            case .clip(.text(let text), _, let from):
                return Rendered(title: "Clip from \(from.name)", body: String(text.prefix(300)))
            case .clip(.image(let data, let mime), let id, let from):
                return Rendered(
                    title: "Image from \(from.name)", body: "Press and hold to Copy or Save to Photos",
                    attachment: writeAttachment(data, mime: mime, id: id), category: "CLIP_IMAGE")
            case .pairRequest(let request):
                return Rendered(
                    title: "\(request.name) wants to pair",
                    body: "Allow it to send to and receive from this iPhone. Expires in 10 minutes.",
                    category: "PAIR")
            case .paired(let peer):
                return Rendered(title: "Paired with \(peer.name)", body: "You can now teleport between the two.", category: "")
            case .peerUpdated(let peer):
                return Rendered(title: "Teleport", body: "\(peer.name) updated", category: "")
            }
        } catch OpenError.proof {
            return Rendered(
                title: "Teleport", body: "Pairing code expired or already used. Show a new code and scan again.",
                category: "")
        } catch let error as OpenError {
            return Rendered(title: "Teleport", body: "Couldn't verify a clip (\(error.rawValue)). Re-pair if this keeps happening.", category: "")
        } catch {
            // Usually a network failure downloading an image; Copy re-downloads it.
            return Rendered(title: "Teleport", body: "Couldn't download a clip: \(error.localizedDescription). Tap Copy to try again.")
        }
    }

    private static func writeAttachment(_ data: Data, mime: String, id: String) -> URL? {
        let ext = mime == "image/png" ? "png" : (mime == "image/gif" ? "gif" : "jpg")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(id).\(ext)")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}

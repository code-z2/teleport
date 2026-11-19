import TeleportCore
import UIKit
import UniformTypeIdentifiers

/// Share sheet → encrypt → relay. Plain UIKit, no heavy frameworks (extension memory limit).
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground.withAlphaComponent(0.95)
        label.text = "Teleporting…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await run() }
    }

    private func run() async {
        do {
            guard let clip = try await extractClip() else { return finish("Nothing to send") }
            try await Teleport().send(clip)
            finish("Sent ✓")
        } catch TeleportError.notPaired {
            finish("Open Teleport to pair first")
        } catch TeleportError.tooLarge {
            finish("Too large (max 10 MB)")
        } catch {
            finish("Failed")
        }
    }

    private func finish(_ message: String) {
        label.text = message
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func extractClip() async throws -> Clip? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }

        // Prefer an image, then a URL, then text.
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            let data = try await p.loadData(UTType.image)
            return Self.portableImage(data)
        }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = try await p.loadString(UTType.url) {
            return .text(url)
        }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
           let text = try await p.loadString(UTType.plainText) {
            return .text(text)
        }
        return nil
    }

    /// Keep PNG/JPEG/GIF as-is; convert HEIC etc. to JPEG so Android can paste it.
    private static func portableImage(_ data: Data) -> Clip {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image(data, mime: "image/png") }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .image(data, mime: "image/jpeg") }
        if data.starts(with: [0x47, 0x49, 0x46]) { return .image(data, mime: "image/gif") }
        let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
        return .image(jpeg, mime: "image/jpeg")
    }
}

private extension NSItemProvider {
    /// URL or plain text as a String (callback API, so nothing non-Sendable crosses actors).
    @MainActor func loadString(_ type: UTType) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            loadItem(forTypeIdentifier: type.identifier) { item, error in
                if let error { return cont.resume(throwing: error) }
                switch item {
                case let url as URL: cont.resume(returning: url.absoluteString)
                case let s as String: cont.resume(returning: s)
                case let d as Data: cont.resume(returning: String(data: d, encoding: .utf8))
                default: cont.resume(returning: nil)
                }
            }
        }
    }

    @MainActor func loadData(_ type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { cont.resume(returning: data) } else { cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

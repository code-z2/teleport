import AppKit
import SwiftUI
import TeleportCore
import UniformTypeIdentifiers

/// "Teleport" in the macOS Share menu: the shared device picker (SendPicker), hosted in AppKit.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let context = extensionContext
        let model = SendModel(
            loadClip: { await MacClipReader.clip(from: context?.inputItems ?? []) },
            finish: { context?.completeRequest(returningItems: nil) })
        let host = NSHostingView(rootView: SendPicker(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 320)
        view = host
        preferredContentSize = host.fittingSize
    }
}

/// Reads the shared item: an image if there is one, then a URL, then text.
@MainActor
enum MacClipReader {
    static func clip(from items: [Any]) async -> Clip? {
        let providers = (items as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
           let data = await load(p, UTType.image) {
            return portableImage(data)
        }
        // Links (Safari's Share) and text arrive as URL / NSString objects, not raw data.
        for type in [UTType.url, UTType.plainText, UTType.text] {
            if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }),
               let text = await loadText(p, type), !text.isEmpty {
                return .text(text)
            }
        }
        return nil
    }

    private static func loadText(_ provider: NSItemProvider, _ type: UTType) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                switch item {
                case let url as URL: cont.resume(returning: url.absoluteString)
                case let url as NSURL: cont.resume(returning: url.absoluteString)
                case let s as String: cont.resume(returning: s)
                case let s as NSAttributedString: cont.resume(returning: s.string)
                case let d as Data:
                    cont.resume(returning: URL(dataRepresentation: d, relativeTo: nil)?.absoluteString ?? String(data: d, encoding: .utf8))
                default: cont.resume(returning: nil)
                }
            }
        }
    }

    private static func load(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(for: type) { data, _ in cont.resume(returning: data) }
        }
    }

    /// PNG/JPEG/GIF as-is; anything else (TIFF, HEIC…) becomes PNG so phones can paste it.
    private static func portableImage(_ data: Data) -> Clip {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image(data, mime: "image/png") }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .image(data, mime: "image/jpeg") }
        if data.starts(with: [0x47, 0x49, 0x46]) { return .image(data, mime: "image/gif") }
        if let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            return .image(png, mime: "image/png")
        }
        return .image(data, mime: "image/png")
    }
}

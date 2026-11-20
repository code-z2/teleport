// Shared by the Share extension and the Action extension.

import TeleportCore
import UIKit
import UniformTypeIdentifiers

@MainActor
enum ClipExtractor {
    /// Reads the shared item: prefers an image, then a URL, then plain text.
    static func clip(from items: [Any]) async throws -> Clip? {
        let providers = (items as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }

        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            return portableImage(try await p.loadData(UTType.image))
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

    /// User-facing text for a send failure.
    static func message(for error: Error) -> String {
        switch error {
        case TeleportError.notPaired: "Open Teleport to pair first"
        case TeleportError.chooseDevice: "Several devices are paired — pick one from the share sheet's suggestions or the Teleport app icon"
        case TeleportError.tooLarge: "Too large (max 10 MB)"
        case RelayError.peerGone: "The other phone needs to re-pair"
        default: "Send failed"
        }
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

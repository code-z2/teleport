// Shared by the Share extension and the Action extension.

import TeleportCore
import UIKit
import UniformTypeIdentifiers

@MainActor
enum ClipExtractor {
    /// Reads the shared item: an image (clipboard-sized ones as clips, big ones as files),
    /// then a video or any other file, then a URL, then plain text.
    static func outgoing(from items: [Any]) async throws -> Outgoing? {
        let providers = (items as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }

        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
           let file = try await p.copyFile(UTType.image) {
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + 16 <= Teleport.maxBlobBytes, let data = try? Data(contentsOf: file.url) {
                try? FileManager.default.removeItem(at: file.url)
                return .clip(portableImage(data))
            }
            return .file(file.url, mime: file.mime, name: file.name)
        }
        // Videos, PDFs, documents… anything that comes as a file.
        for type in [UTType.movie, UTType.audio, UTType.pdf, UTType.data] {
            if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) && !$0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
               let file = try await p.copyFile(type) {
                return .file(file.url, mime: file.mime, name: file.name)
            }
        }
        if let clip = try await clip(from: providers) { return .clip(clip) }
        return nil
    }

    /// Text and links.
    private static func clip(from providers: [NSItemProvider]) async throws -> Clip? {
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
        case TeleportError.tooLarge: "Too large (max 250 MB)"
        case RelayError.peerGone: "The other phone needs to re-pair"
        case RelayError.offline: "That Mac is offline (asleep or no internet)"
        default: "Send failed"
        }
    }
}

private extension NSItemProvider {
    struct CopiedFile { let url: URL; let mime: String; let name: String }

    /// Copies the item's file into our temporary folder (the provider's copy vanishes when
    /// the callback returns). Streams on disk: fine for a 250 MB video in an extension.
    @MainActor func copyFile(_ type: UTType) async throws -> CopiedFile? {
        let suggested = suggestedName
        return try await withCheckedThrowingContinuation { cont in
            _ = loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { return cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                let ext = url.pathExtension
                var name = suggested ?? url.deletingPathExtension().lastPathComponent
                if !ext.isEmpty, !name.lowercased().hasSuffix("." + ext.lowercased()) { name += "." + ext }
                let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let copy = dir.appending(path: name)
                    try FileManager.default.copyItem(at: url, to: copy)
                    let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? type.preferredMIMEType ?? "application/octet-stream"
                    cont.resume(returning: CopiedFile(url: copy, mime: mime, name: name))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

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

import AppIntents
import SwiftUI
import TeleportCore
import UIKit

/// The sheet the Control Center button opens: what's on the clipboard → a device.
struct ClipboardSendSheet: View {
    let dismiss: () -> Void
    @State private var model: SendModel?

    var body: some View {
        Group {
            if let model { SendPicker(model: model) } else { ProgressView() }
        }
        .presentationDetents([.medium])
        .onAppear {
            guard model == nil else { return }
            model = SendModel(
                loadClip: { await Self.readClipboard() },
                onSent: { ShareSuggestion.donate(for: $0) },
                finish: dismiss)
        }
    }

    /// An image if there is one, otherwise text or a link. Reading may show iOS's
    /// "Allow Paste" prompt (Settings ▸ Teleport ▸ Paste from Other Apps ▸ Allow stops it).
    @MainActor
    static func readClipboard() -> Clip? {
        let pb = UIPasteboard.general
        if pb.hasImages, let image = pb.image {
            if let data = pb.data(forPasteboardType: "public.png") { return .image(data, mime: "image/png") }
            if let data = pb.data(forPasteboardType: "public.jpeg") { return .image(data, mime: "image/jpeg") }
            if let png = image.pngData() { return .image(png, mime: "image/png") }
        }
        if pb.hasURLs, let url = pb.url { return .text(url.absoluteString) }
        if pb.hasStrings, let text = pb.string, !text.isEmpty { return .text(text) }
        return nil
    }
}

/// Offers "Teleport Clipboard" to Siri, Spotlight and the Action button without setup.
struct TeleportShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TeleportClipboardIntent(),
            phrases: ["Teleport my clipboard with \(.applicationName)", "\(.applicationName) clipboard"],
            shortTitle: "Teleport Clipboard",
            systemImageName: "arrow.right.doc.on.clipboard")
    }
}

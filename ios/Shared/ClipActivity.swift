// Compiled into both the app and the Live Activity widget extension.
// LiveActivityIntent.perform() runs in the *app's* process, which owns the clipboard.

import ActivityKit
import AppIntents
import Photos
import TeleportCore
import UIKit

struct ClipActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The sealed envelope JSON. Never plaintext: iOS renders content-state
        /// straight from the push with no hook for us to decrypt first.
        var env: String
        /// Set by the app while it downloads (0…1). Absent in the push.
        var progress: Double?
        /// Set by the app when it's done ("Saved to Photos", "Copied"…). Absent in the push.
        var note: String?
        /// The file's name, once the app knows it (the push can't carry plaintext).
        var name: String?
        /// Downloaded and decrypted: Copy / Save work instantly.
        var ready: Bool?
    }

    /// "image" or "file" (the relay starts these for photos and files only).
    var kind: String
    /// The sender's public-key fingerprint; the widget shows the paired device's name.
    var from: String?
}

// MARK: The photo / file Live Activity's buttons (run in the app's process)

/// Copy: a photo goes on the clipboard as an image; any other file as a file.
@available(iOS 17, *)
struct CopyInboxIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Copy"
    static let isDiscoverable = false
    @Parameter(title: "Envelope") var env: String
    init() {}
    init(env: String) { self.env = env }

    func perform() async throws -> some IntentResult {
        let inbox = Inbox(appGroup: TeleportConfig.fromBundle().appGroup)
        guard let item = inbox.item(env: env), item.state == .ready else {
            try openInApp(env, saveToPhotos: false)  // not downloaded yet: finish in the app
            return .result()
        }
        await InboxClipboard.copy(inbox.file(item), item: item)
        await FileActivity.finish(env, note: "Copied")
        return .result()
    }
}

/// Save: photos and videos straight to Photos; other files open Teleport (Save to Files needs a screen).
@available(iOS 17, *)
struct SaveInboxIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Save"
    static let isDiscoverable = false
    @Parameter(title: "Envelope") var env: String
    init() {}
    init(env: String) { self.env = env }

    func perform() async throws -> some IntentResult {
        let inbox = Inbox(appGroup: TeleportConfig.fromBundle().appGroup)
        guard let item = inbox.item(env: env), item.state == .ready, item.isMedia else {
            try openInApp(env, saveToPhotos: true)
            return .result()
        }
        do {
            try await PhotoSaver.saveFile(inbox.file(item), video: item.isVideo)
            await FileActivity.finish(env, note: "Saved to Photos")
        } catch {
            try openInApp(env, saveToPhotos: true)  // e.g. Photos access not granted yet: ask in the app
        }
        return .result()
    }
}

/// Cancel: stops the download and dismisses the activity.
@available(iOS 17, *)
struct CancelInboxIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel"
    static let isDiscoverable = false
    @Parameter(title: "Envelope") var env: String
    init() {}
    init(env: String) { self.env = env }

    func perform() async throws -> some IntentResult {
        let inbox = Inbox(appGroup: TeleportConfig.fromBundle().appGroup)
        if let id = (try? Envelope.parse(env))?.id {
            await InboxDownloads.shared.cancel(id)
            inbox.update(id) { $0.state = .cancelled }
        }
        await FileActivity.dismiss(env)
        return .result()
    }
}

/// Copying a received photo or file to the clipboard.
enum InboxClipboard {
    @MainActor
    static func copy(_ url: URL, item: InboxItem) {
        if item.mime.hasPrefix("image/"), let image = UIImage(contentsOfFile: url.path) {
            UIPasteboard.general.image = image
        } else if let provider = NSItemProvider(contentsOf: url) {
            UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: nil)
        }
    }
}

/// "Download" on a file's Live Activity: opens Teleport, which downloads and updates the
/// activity's progress bar.
@available(iOS 17, *)
struct DownloadFileIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Download File"
    static let isDiscoverable = false

    @Parameter(title: "Envelope") var env: String

    init() {}
    init(env: String) { self.env = env }

    func perform() async throws -> some IntentResult {
        try openInApp(env, saveToPhotos: false)
        return .result()
    }
}

/// Large files can't be fetched by a Live Activity button (it runs briefly in the
/// background): those buttons open the app instead, which downloads with progress.
/// The app sets this at launch; the widget extension never calls it.
enum IncomingFileRouter {
    @MainActor static var open: ((_ env: String, _ saveToPhotos: Bool) -> Void)?
}

/// Live Activity buttons are iOS 17+. On iOS 16 the notification's Copy / Save actions do this.
@available(iOS 17, *)
struct CopyClipIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Copy Clip"
    static let isDiscoverable = false

    @Parameter(title: "Envelope") var env: String

    init() {}
    init(env: String) { self.env = env }

    func perform() async throws -> some IntentResult {
        let teleport = try Teleport()
        switch try await teleport.receive(env, firstDelivery: false) {
        case .clip(let clip, _, _):
            await ClipboardWriter.write(clip)
        case .file:
            await Self.endActivities()
            try openInApp(env, saveToPhotos: false)
        default:
            break
        }
        // Done — dismiss every clip activity.
        for activity in Activity<ClipActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

/// "Save" on the Live Activity for images: adds the image to Photos without opening the app.
/// Needs add-only Photos access, which the app asks for once it's paired (a background
/// intent can't show the permission prompt itself).
@available(iOS 17, *)
struct SaveClipIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Save Clip to Photos"
    static let isDiscoverable = false

    @Parameter(title: "Envelope") var env: String

    init() {}
    init(env: String) { self.env = env }

    func perform() async throws -> some IntentResult {
        let teleport = try Teleport()
        switch try await teleport.receive(env, firstDelivery: false) {
        case .clip(.image(let data, _), _, _): try await PhotoSaver.save(data)
        case .file:
            // Download in the app (with progress), then straight to Photos.
            await CopyClipIntent.endActivities()
            try openInApp(env, saveToPhotos: true)
        case .clip(let clip, _, _): await ClipboardWriter.write(clip)  // a long text "blob": copy instead
        default: break
        }
        for activity in Activity<ClipActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

// Live Activity intents run in the app's process, where they can bring the app forward.
// Extensions can't use that API, and the widget extension only needs these types to
// draw the buttons, so it gets a stub (WIDGET_EXTENSION is set for that target only).
#if WIDGET_EXTENSION
@available(iOS 17, *)
extension LiveActivityIntent {
    func openInApp(_ env: String, saveToPhotos: Bool) throws {}
}
#else
@available(iOS 17, *)
extension CopyClipIntent: ForegroundContinuableIntent {}
@available(iOS 17, *)
extension DownloadFileIntent: ForegroundContinuableIntent {}
@available(iOS 17, *)
extension CopyInboxIntent: ForegroundContinuableIntent {}
@available(iOS 17, *)
extension SaveInboxIntent: ForegroundContinuableIntent {}
@available(iOS 17, *)
extension SaveClipIntent: ForegroundContinuableIntent {}

@available(iOS 17, *)
extension ForegroundContinuableIntent {
    func openInApp(_ env: String, saveToPhotos: Bool) throws {
        throw needsToContinueInForegroundError { IncomingFileRouter.open?(env, saveToPhotos) }
    }
}
#endif

@available(iOS 17, *)
extension CopyClipIntent {
    static func endActivities() async {
        for activity in Activity<ClipActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// Every "Save to Photos" goes through here. Photos runs the change block on its own
/// queue, so the block is built in a nonisolated, @Sendable context: a block written inside
/// a SwiftUI view inherits main-actor isolation and Swift 6 traps when Photos runs it
/// elsewhere (that was the crash).
enum PhotoSaver {
    enum Failure: Error, LocalizedError {
        case notAllowed
        var errorDescription: String? { "Allow Teleport to add photos in Settings ▸ Privacy ▸ Photos." }
    }

    nonisolated static func save(_ data: Data) async throws {
        try await authorize()
        let change: @Sendable () -> Void = {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
        try await PHPhotoLibrary.shared().performChanges(change)
    }

    /// A photo or video file (streams from disk; fine for large videos).
    nonisolated static func saveFile(_ url: URL, video: Bool) async throws {
        try await authorize()
        let change: @Sendable () -> Void = {
            PHAssetCreationRequest.forAsset().addResource(with: video ? .video : .photo, fileURL: url, options: nil)
        }
        try await PHPhotoLibrary.shared().performChanges(change)
    }

    nonisolated private static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
    }
}

enum ClipboardWriter {
    @MainActor static func write(_ clip: Clip) {
        switch clip {
        case .text(let s):
            if let url = URL(string: s), url.scheme?.hasPrefix("http") == true, !s.contains(" ") {
                UIPasteboard.general.items = [["public.url": url, "public.utf8-plain-text": s]]
            } else {
                UIPasteboard.general.string = s
            }
        case .image(let data, let mime):
            let type = mime == "image/png" ? "public.png" : (mime == "image/gif" ? "com.compuserve.gif" : "public.jpeg")
            UIPasteboard.general.setData(data, forPasteboardType: type)
        }
    }
}

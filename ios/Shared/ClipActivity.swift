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
    }

    var kind: String
}

struct CopyClipIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Copy Clip"
    static let isDiscoverable = false

    @Parameter(title: "Envelope") var env: String

    init() {}
    init(env: String) { self.env = env }

    func perform() async throws -> some IntentResult {
        let teleport = try Teleport()
        if case .clip(let clip, _) = try await teleport.receive(env, firstDelivery: false) {
            await ClipboardWriter.write(clip)
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
struct SaveClipIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Save Clip to Photos"
    static let isDiscoverable = false

    @Parameter(title: "Envelope") var env: String

    init() {}
    init(env: String) { self.env = env }

    func perform() async throws -> some IntentResult {
        let teleport = try Teleport()
        switch try await teleport.receive(env, firstDelivery: false) {
        case .clip(.image(let data, _), _): try await PhotoSaver.save(data)
        case .clip(let clip, _): await ClipboardWriter.write(clip)  // a long text "blob": copy instead
        default: break
        }
        for activity in Activity<ClipActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

enum PhotoSaver {
    enum Failure: Error { case notAllowed }

    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
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

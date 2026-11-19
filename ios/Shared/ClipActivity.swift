// Compiled into both the app and the Live Activity widget extension.
// LiveActivityIntent.perform() runs in the *app's* process, which owns the clipboard.

import ActivityKit
import AppIntents
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

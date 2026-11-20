import AppIntents
import Observation
import SwiftUI

/// "Teleport" in Control Center (and Shortcuts, Siri, the Action button): sends what you
/// copied. iOS only lets the app on screen read the clipboard, so the intent opens
/// Teleport, which reads it and sends (asking which device if there are several).
struct TeleportClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Teleport Clipboard"
    static let description = IntentDescription("Send what you copied to one of your paired devices.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ClipboardSendRequest.shared.pending = true
        return .result()
    }
}

/// Set by the intent, watched by the app: show the "send clipboard" sheet.
@MainActor
@Observable
final class ClipboardSendRequest {
    static let shared = ClipboardSendRequest()
    var pending = false
}

import TeleportCore
import UIKit
import UserNotifications

/// "Teleport" in the share sheet's actions list (next to Copy). No UI: tapping it
/// sends straight away, and a notification confirms the result.
final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // The context is only touched from this one task, then completed.
        nonisolated(unsafe) let context = context
        Task { @MainActor in
            do {
                guard let clip = try await ClipExtractor.clip(from: context.inputItems) else {
                    await Self.notify("Nothing to teleport")
                    return context.completeRequest(returningItems: nil)
                }
                // Phase 4 turns this into "Teleport…" with a device picker. Until then it
                // sends to the only paired device.
                let teleport = try Teleport()
                let peer = try teleport.defaultPeer()
                try await teleport.send(clip, to: peer)
                ShareSuggestion.donate(for: peer)
                await Self.notify("Sent to \(peer.name)")
            } catch {
                await Self.notify(ClipExtractor.message(for: error))
            }
            context.completeRequest(returningItems: nil)
        }
    }

    private static func notify(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Teleport"
        content.body = body
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: "teleport-action", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        // Clear it shortly after; it's only a confirmation.
        Task {
            try? await Task.sleep(for: .seconds(4))
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["teleport-action"])
        }
    }
}

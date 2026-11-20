import AppKit
import SwiftUI
import UserNotifications

/// Menu bar only: no Dock icon, no app switcher entry (LSUIElement in Info.plist).
@main
struct TeleportMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.isOnline ? "arrow.right.doc.on.clipboard" : "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .accessibilityLabel(appDelegate.model.isOnline ? "Teleport: online" : "Teleport: offline")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.setUp(delegate: self)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Allow / Deny on pairing requests; clicking an image notification shows the file.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let requestID = info["request"] as? String
        let file = info["file"] as? String
        await MainActor.run {
            if let requestID, let request = model.requests.first(where: { $0.id == requestID }) {
                switch action {
                case Notifier.allowAction: model.allow(request)
                case Notifier.denyAction: model.deny(request)
                default: break  // opening the notification: decide in the menu bar panel
                }
            } else if let file {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file)])
            }
        }
    }
}

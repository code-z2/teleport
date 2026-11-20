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

/// Receives the right-click "Teleport" Service. The method name matches NSMessage in Info.plist.
@MainActor
final class ServicesProvider: NSObject {
    let model: AppModel
    init(model: AppModel) { self.model = model }

    @objc func teleport(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // The selection's pasteboard is only valid during this call: read it now.
        model.teleportSelection(Pasteboard.read(pasteboard))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    private lazy var services = ServicesProvider(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.setUp(delegate: self)
        // "Teleport" in right-click menus (NSServices in Info.plist).
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
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

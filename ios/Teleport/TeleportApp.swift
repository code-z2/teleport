import ActivityKit
import FirebaseCore
import FirebaseMessaging
import SwiftUI
import TeleportCore
import UserNotifications

@main
struct TeleportApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    nonisolated static let copyAction = "COPY"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().delegate = self
        } else {
            print("Teleport: GoogleService-Info.plist missing — push disabled")
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "CLIP", actions: [copy], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()

        observePushToStartToken()
        return true
    }

    // MARK: Tokens

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in self.tokenChanged { $0.ownFCMToken = fcmToken } }
    }

    private func observePushToStartToken() {
        Task {
            for await data in Activity<ClipActivityAttributes>.pushToStartTokenUpdates {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                tokenChanged { $0.ownLiveActivityToken = hex }
            }
        }
    }

    /// Persist the new token and, if it changed while paired, tell the peer.
    private func tokenChanged(_ update: (SharedStore) -> Void) {
        guard let teleport = try? Teleport() else { return }
        let before = (teleport.store.ownFCMToken, teleport.store.ownLiveActivityToken)
        update(teleport.store)
        let after = (teleport.store.ownFCMToken, teleport.store.ownLiveActivityToken)
        guard before != after, teleport.store.peer != nil else { return }
        Task { try? await teleport.announceTokens(name: UIDevice.current.name) }
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tapping the notification or its "Copy" action opens the app → copy.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.copyAction
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let env = response.notification.request.content.userInfo["env"] as? String
        else { return }
        await Self.copy(env)
    }

    static func copy(_ env: String) async {
        do {
            let teleport = try Teleport()
            if case .clip(let clip, _) = try await teleport.receive(env, firstDelivery: false) {
                ClipboardWriter.write(clip)
            }
        } catch {
            print("Teleport: copy failed: \(error)")
        }
    }
}

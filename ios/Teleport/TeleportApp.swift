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

extension Notification.Name {
    /// Our push tokens changed or push registration failed — the UI should refresh.
    static let teleportPushStateChanged = Notification.Name("TeleportPushStateChanged")
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    nonisolated static let copyAction = "COPY"
    nonisolated static let saveAction = "SAVE"

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
        let copy = UNNotificationAction(
            identifier: Self.copyAction, title: "Copy", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "doc.on.doc"))
        let save = UNNotificationAction(
            identifier: Self.saveAction, title: "Save to Photos", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "square.and.arrow.down"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "CLIP", actions: [copy], intentIdentifiers: []),
            // The NSE switches image notifications to this category.
            UNNotificationCategory(identifier: "CLIP_IMAGE", actions: [copy, save], intentIdentifiers: []),
        ])
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
        guard before != after else { return }
        NotificationCenter.default.post(name: .teleportPushStateChanged, object: nil)
        guard teleport.store.peer != nil else { return }
        Task { try? await teleport.announceTokens(name: UIDevice.current.name) }
    }

    /// Set when APNs refuses to register (missing push entitlement, no network, simulator…).
    static var pushRegistrationError: String?

    /// Hand the APNs token to Firebase explicitly. Firebase's automatic interception
    /// doesn't reliably see this callback in a SwiftUI app, which leaves FCM failing
    /// with "No APNS token specified before fetching FCM Token".
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard FirebaseApp.app() != nil else { return }
        Self.pushRegistrationError = nil
        Messaging.messaging().apnsToken = deviceToken
        Task {
            do {
                let token = try await Messaging.messaging().token()
                tokenChanged { $0.ownFCMToken = token }
            } catch {
                print("Teleport: FCM token failed after APNs registration: \(error)")
                Self.pushRegistrationError = error.localizedDescription
                NotificationCenter.default.post(name: .teleportPushStateChanged, object: nil)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.pushRegistrationError = error.localizedDescription
        NotificationCenter.default.post(name: .teleportPushStateChanged, object: nil)
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
        guard let env = response.notification.request.content.userInfo["env"] as? String else { return }
        switch response.actionIdentifier {
        case Self.saveAction: await Self.save(env)
        case Self.copyAction, UNNotificationDefaultActionIdentifier: await Self.copy(env)
        default: break
        }
    }

    static func save(_ env: String) async {
        do {
            let teleport = try Teleport()
            if case .clip(.image(let data, _), _) = try await teleport.receive(env, firstDelivery: false) {
                try await PhotoSaver.save(data)
            }
        } catch {
            print("Teleport: save failed: \(error)")
        }
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

import ActivityKit
import FirebaseCore
import FirebaseMessaging
import SwiftUI
import TeleportCore
import UserNotifications

@main
struct TeleportApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        Compat.applyLaunchArguments()
        // Live Activity buttons for large files open the download screen here.
        IncomingFileRouter.open = { env, save in IncomingFiles.shared.open(env, saveToPhotos: save) }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

extension Notification.Name {
    /// Our push tokens changed or push registration failed — the UI should refresh.
    static let teleportPushStateChanged = Notification.Name("TeleportPushStateChanged")
    /// A large file's notification was tapped: `object` is the envelope JSON to download.
    static let teleportIncomingFile = Notification.Name("TeleportIncomingFile")
    /// A clip was copied from a notification: `object` is a short preview for the banner.
    static let teleportCopied = Notification.Name("TeleportCopied")
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    nonisolated static let copyAction = "COPY"
    nonisolated static let saveAction = "SAVE"
    nonisolated static let downloadAction = "DOWNLOAD"
    nonisolated static let allowAction = "ALLOW"
    nonisolated static let denyAction = "DENY"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        // Reattach to photo / file downloads the notification extension started, for progress.
        InboxDownloads.shared.connect()
            Messaging.messaging().delegate = self
        } else {
            print("Teleport: GoogleService-Info.plist missing — push disabled")
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let copy = UNNotificationAction(
            // No .foreground: Copy works from the notification without opening Teleport.
            identifier: Self.copyAction, title: "Copy", options: [],
            icon: UNNotificationActionIcon(systemImageName: "doc.on.doc"))
        let save = UNNotificationAction(
            identifier: Self.saveAction, title: "Save to Photos", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "square.and.arrow.down"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "CLIP", actions: [copy], intentIdentifiers: []),
            // The NSE switches image notifications to this category.
            UNNotificationCategory(identifier: "CLIP_IMAGE", actions: [copy, save], intentIdentifiers: []),
            // Photos and files: "You received … from …", no buttons (the Live Activity has
            // Copy / Save / Cancel). Tapping opens the file in Teleport.
            UNNotificationCategory(identifier: "FILE_NOTICE", actions: [], intentIdentifiers: []),
            // The NSE uses this for "<name> wants to pair".
            UNNotificationCategory(identifier: "PAIR", actions: [
                UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [.foreground]),
                UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive]),
            ], intentIdentifiers: []),
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

    /// Live Activities started by push need iOS 17.2. Without a token, the relay sends iOS 16
    /// a plain notification (with Copy / Save) instead.
    ///
    /// The token is only advertised while Live Activities are on for Teleport: with them off,
    /// iOS accepts a push-to-start but shows nothing, so files must come as notifications.
    /// An empty token tells paired devices "none" (a missing field would keep the old one).
    private func observePushToStartToken() {
        guard #available(iOS 17.2, *) else { return }
        let rawKey = "pushToStartToken"
        func apply(enabled: Bool) {
            let raw = UserDefaults.standard.string(forKey: rawKey)
            tokenChanged { $0.ownLiveActivityToken = enabled ? raw : (raw == nil ? nil : "") }
        }
        Task {
            for await data in Activity<ClipActivityAttributes>.pushToStartTokenUpdates {
                UserDefaults.standard.set(data.map { String(format: "%02x", $0) }.joined(), forKey: rawKey)
                apply(enabled: ActivityAuthorizationInfo().areActivitiesEnabled)
            }
        }
        Task {
            apply(enabled: ActivityAuthorizationInfo().areActivitiesEnabled)
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates { apply(enabled: enabled) }
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
        guard !teleport.store.peers.isEmpty, let name = teleport.store.deviceName else { return }
        Task { await teleport.announce(name: name) }
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

    /// iOS wakes the app when a background download finishes (even with the phone locked):
    /// reattach so the delegate decrypts it and flips the Live Activity to Copy / Save.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == InboxDownloads.identifier else { return completionHandler() }
        InboxDownloads.shared.connect(completion: completionHandler)
    }

    // MARK: Notifications

    // The completion-handler forms, answered on the main thread. (The async forms called
    // UIKit back on a background thread, which it asserts against: tapping a file
    // notification crashed.)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            // Pairing requests, "Paired" and device updates change what the main screen shows.
            NotificationCenter.default.post(name: .teleportPushStateChanged, object: nil)
            done([.banner, .sound])
        }
    }

    /// Tapping a notification or one of its actions.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler
        let env = response.notification.request.content.userInfo["env"] as? String
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            guard let env else { return done() }
            if action == Self.copyAction {
                // Copy runs in the background: finish before telling iOS we're done, or the
                // app can be suspended mid-way.
                Task { @MainActor in
                    await Self.handle(env: env, category: category, action: action)
                    done()
                }
            } else {
                done()
                Task { @MainActor in await Self.handle(env: env, category: category, action: action) }
            }
        }
    }

    private static func handle(env: String, category: String, action: String) async {
        if category == "PAIR" {
            return await answerPairing(env, allow: action != denyAction)
        }
        if category == "FILE_NOTICE" {
            return IncomingFiles.shared.open(env)
        }
        switch action {
        case saveAction: await save(env)
        case copyAction, UNNotificationDefaultActionIdentifier: await copy(env)
        default: break
        }
    }

    /// Allow (or tapping the notification) pairs; Deny drops the request.
    /// The request id is the sender's fingerprint, which is the envelope's `from`.
    static func answerPairing(_ env: String, allow: Bool) async {
        guard let teleport = try? Teleport(), let from = try? Envelope.parse(env).from else { return }
        if allow, let name = teleport.store.deviceName {
            do { try await teleport.allow(from, name: name) } catch { print("Teleport: allow failed: \(error)") }
        } else if !allow {
            teleport.deny(from)
        }
        NotificationCenter.default.post(name: .teleportPushStateChanged, object: nil)
    }

    static func save(_ env: String) async {
        do {
            let teleport = try Teleport()
            if case .clip(.image(let data, _), _, _) = try await teleport.receive(env, firstDelivery: false) {
                try await PhotoSaver.save(data)
            }
        } catch {
            print("Teleport: save failed: \(error)")
        }
    }

    static func copy(_ env: String) async {
        do {
            let teleport = try Teleport()
            if case .clip(let clip, _, let from) = try await teleport.receive(env, firstDelivery: false) {
                ClipboardWriter.write(clip)
                // Tapping the notification opens Teleport: show what was copied, not a blank screen.
                let preview: String
                switch clip {
                case .text(let text): preview = String(text.prefix(140))
                case .image: preview = "Image"
                }
                NotificationCenter.default.post(name: .teleportCopied, object: "\(from.name)|\(preview)")
            }
        } catch {
            print("Teleport: copy failed: \(error)")
        }
    }
}

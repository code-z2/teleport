import AppKit
import Observation
import TeleportCore
import UserNotifications

/// Everything the menu bar panel shows, and the actions behind it.
@MainActor
@Observable
final class AppModel {
    let teleport: Teleport?
    let loadError: String?
    private let connection: MailboxConnection?
    private let keepAwake = KeepAwake()

    var state: MailboxConnection.State = .connecting
    var name: String
    var peers: [Peer] = []
    var requests: [PairRequest] = []
    var pairingCode: String?
    /// The last thing that happened, shown at the bottom of the panel.
    var activity: String?

    var keepAwakeOnPower: Bool {
        didSet { UserDefaults.standard.set(keepAwakeOnPower, forKey: "keepAwake"); keepAwake.enabled = keepAwakeOnPower }
    }
    var saveImages: Bool {
        didSet { UserDefaults.standard.set(saveImages, forKey: "saveImages") }
    }
    var startAtLogin: Bool = LoginItem.enabled
    /// Let phones see dotfiles and ~/Library when browsing.
    var showHiddenFiles: Bool {
        didSet { UserDefaults.standard.set(showHiddenFiles, forKey: "showHiddenFiles") }
    }
    /// Phones browsing this Mac right now.
    private(set) var browsers: [String] = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["keepAwake": true, "saveImages": true])
        keepAwakeOnPower = defaults.bool(forKey: "keepAwake")
        saveImages = defaults.bool(forKey: "saveImages")
        showHiddenFiles = defaults.bool(forKey: "showHiddenFiles")
        Self.migrateStore()
        do {
            let teleport = try Teleport(config: .fromBundle(), platform: .mac)
            self.teleport = teleport
            self.loadError = nil
            self.connection = MailboxConnection(teleport: teleport)
            self.name = teleport.store.deviceName ?? Host.current().localizedName ?? "Mac"
        } catch {
            self.teleport = nil
            self.loadError = "Couldn't load this Mac's keys: \(error)"
            print("Teleport: \(self.loadError!)")
            self.connection = nil
            self.name = Host.current().localizedName ?? "Mac"
        }
        keepAwake.enabled = keepAwakeOnPower
        if let teleport, teleport.store.deviceName == nil { teleport.store.deviceName = name }

        connection?.onState = { [weak self] in self?.state = $0 }
        connection?.onEnvelope = { [weak self] env in self?.receive(env) }
        connection?.onBrowsers = { [weak self] in self?.browsers = $0 }
        connection?.showHiddenFiles = { UserDefaults.standard.bool(forKey: "showHiddenFiles") }
        connection?.start()
        reload()
    }

    /// Before the Share extension, settings lived in a store only the app could read. Copy
    /// them once into the App Group store the extension shares, so pairings carry over.
    private static func migrateStore() {
        let config = TeleportConfig.fromBundle()
        guard let shared = UserDefaults(suiteName: config.appGroup), shared.object(forKey: "peers") == nil,
              let bundleID = Bundle.main.bundleIdentifier,
              let old = UserDefaults.standard.persistentDomain(forName: bundleID + ".store")
        else { return }
        for (key, value) in old { shared.set(value, forKey: key) }
        print("Teleport: moved \(old.count) settings into the shared App Group store")
    }

    var isOnline: Bool { if case .online = state { true } else { false } }
    var keepAwakeActive: Bool { keepAwake.active }

    /// Desktop / Documents / Downloads → readable by Teleport (empty until first requested).
    private(set) var folderAccess = HomeFolderAccess.status

    func requestFolderAccess() {
        Task { folderAccess = await HomeFolderAccess.request() }
    }

    func reload() {
        folderAccess = HomeFolderAccess.status
        guard let teleport else { return }
        peers = teleport.store.sortedPeers
        requests = teleport.store.pairRequests.values.sorted { $0.expires < $1.expires }
    }

    func reconnect() { connection?.reconnectNow() }

    // MARK: Receiving

    private func receive(_ env: String) {
        guard let teleport else { return }
        Task {
            do {
                switch try await teleport.receive(env, firstDelivery: true) {
                case .clip(let clip, _, let from):
                    Pasteboard.write(clip)
                    switch clip {
                    case .text(let text):
                        activity = "Copied from \(from.name)"
                        Notifier.post(title: "Copied from \(from.name)", body: String(text.prefix(200)))
                    case .image(let data, let mime):
                        let saved = saveImages ? Pasteboard.saveToDownloads(data, mime: mime, from: from.name) : nil
                        activity = "Image from \(from.name) copied" + (saved != nil ? " and saved to Downloads" : "")
                        Notifier.post(title: "Image from \(from.name)", body: saved != nil ? "Copied, and saved to Downloads/Teleport" : "Copied", file: saved)
                    }
                case .pairRequest(let request):
                    reload()
                    Notifier.postPairRequest(request)
                case .paired(let peer):
                    reload()
                    activity = "Paired with \(peer.name)"
                case .peerUpdated:
                    reload()
                }
            } catch OpenError.proof {
                activity = "A pairing code expired or was already used. Show a new one."
            } catch {
                activity = "Couldn't verify a clip (\(error))"
            }
        }
    }

    // MARK: Pairing

    func showPairingCode() {
        guard let teleport else { return }
        pairingCode = try? teleport.qrCode(name: name)
    }

    func allow(_ request: PairRequest) {
        guard let teleport else { return }
        Task {
            do {
                let peer = try await teleport.allow(request.id, name: name)
                activity = "Paired with \(peer.name)"
                pairingCode = nil
            } catch {
                activity = "Couldn't finish pairing: \(error)"
            }
            reload()
        }
    }

    func deny(_ request: PairRequest) {
        teleport?.deny(request.id)
        reload()
    }

    func remove(_ peer: Peer) {
        teleport?.remove(peer.id)
        reload()
        activity = "Removed \(peer.name)"
    }

    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard let teleport, !trimmed.isEmpty, trimmed != teleport.store.deviceName else { return }
        name = trimmed
        teleport.store.deviceName = trimmed
        Task { await teleport.announce(name: trimmed) }
        activity = "Renamed to \(trimmed)"
    }

    // MARK: Sending

    func sendClipboard(to peer: Peer) {
        guard let teleport else { return }
        guard let clip = Pasteboard.read() else {
            activity = "The clipboard is empty"
            return
        }
        activity = "Sending to \(peer.name)…"
        Task {
            do {
                try await teleport.send(clip, to: peer)
                if case .image = clip { activity = "Image sent to \(peer.name)" } else { activity = "Sent to \(peer.name)" }
            } catch RelayError.peerGone {
                activity = "\(peer.name)'s push address expired. Open Teleport there, or re-pair."
            } catch TeleportError.tooLarge {
                activity = "Too large (max 10 MB)"
            } catch {
                activity = "Couldn't send: \(error)"
            }
        }
    }

    /// "Teleport" from the right-click menu (macOS Services): with one device, send at once;
    /// otherwise pop up the devices by name at the pointer.
    func teleportSelection(_ clip: Clip?) {
        guard let clip else {
            return Notifier.post(title: "Teleport", body: "There's nothing in that selection Teleport can send.")
        }
        switch peers.count {
        case 0: Notifier.post(title: "Teleport", body: "No devices yet. Pair one from the menu bar.")
        case 1: send(clip, to: peers[0])
        default: DevicePopup.show(peers) { [weak self] peer in self?.send(clip, to: peer) }
        }
    }

    private func send(_ clip: Clip, to peer: Peer) {
        guard let teleport else { return }
        Task {
            do {
                try await teleport.send(clip, to: peer)
                activity = "Sent to \(peer.name)"
                Notifier.post(title: "Sent to \(peer.name)", body: "")
            } catch RelayError.peerGone {
                Notifier.post(title: "Teleport", body: "\(peer.name) needs to open Teleport (or re-pair).")
            } catch RelayError.offline {
                Notifier.post(title: "Teleport", body: "\(peer.name) is offline.")
            } catch {
                Notifier.post(title: "Teleport", body: "Couldn't send to \(peer.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Settings

    func setStartAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
        } catch {
            activity = "Couldn't change Start at Login: \(error.localizedDescription)"
        }
        startAtLogin = LoginItem.enabled
    }
}

/// Local notifications for received clips and pairing requests.
enum Notifier {
    static let pairCategory = "PAIR"
    static let allowAction = "ALLOW"
    static let denyAction = "DENY"

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(identifier: pairCategory, actions: [
                UNNotificationAction(identifier: allowAction, title: "Allow"),
                UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive]),
            ], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, file: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let file { content.userInfo["file"] = file.path }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func postPairRequest(_ request: PairRequest) {
        let content = UNMutableNotificationContent()
        content.title = "\(request.name) wants to pair"
        content.body = "Allow it to send to this Mac and receive from it."
        content.categoryIdentifier = pairCategory
        content.userInfo["request"] = request.id
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pair-\(request.id)", content: content, trigger: nil))
    }
}

/// A small menu of device names at the pointer, for the right-click "Teleport" Service.
@MainActor
enum DevicePopup {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func show(_ peers: [Peer], pick: @escaping (Peer) -> Void) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Teleport to…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        var targets: [Target] = []
        for peer in peers {
            let target = Target { pick(peer) }
            targets.append(target)
            let item = NSMenuItem(title: peer.name, action: #selector(Target.run), keyEquivalent: "")
            item.target = target
            item.image = NSImage(systemSymbolName: peer.platform.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        // A menu bar app must come forward for its menu to take clicks.
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(targets) {}
    }
}

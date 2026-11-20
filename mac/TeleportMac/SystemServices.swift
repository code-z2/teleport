import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement

/// Keeps the Mac from idle-sleeping while it's on power, so phones can reach it.
/// The display can still sleep; only system sleep is held off. Released on battery.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    var enabled = false {
        didSet { update() }
    }

    /// True while the assertion is held (on power, setting on).
    private(set) var active = false

    init() {
        // Power source changes are infrequent; checking once a minute is plenty.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    static var onPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true }  // desktops with no battery
        return (source as String) == kIOPMACPowerKey
    }

    func update() {
        let want = enabled && Self.onPower
        if want && !active {
            active = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Teleport: staying reachable for your phones" as CFString,
                &assertion) == kIOReturnSuccess
        } else if !want && active {
            IOPMAssertionRelease(assertion)
            active = false
        }
    }
}

/// "Start at login", via the system's login items (System Settings → General → Login Items).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// macOS guards Desktop, Documents and Downloads separately and asks on the Mac the first
/// time Teleport opens each: awkward when you're browsing from your phone. Rather than Full
/// Disk Access (all or nothing, far beyond the home folder), Teleport asks for just these
/// three, all at once, while you're at the Mac. Its own rules keep phones inside ~ anyway.
enum HomeFolderAccess {
    static let folders = ["Desktop", "Documents", "Downloads"]
    private static let requestedKey = "homeFolderAccessRequested"

    /// Folder → readable. Empty until access has been requested once, because checking
    /// a folder macOS hasn't decided on yet would itself pop up the prompt.
    static var status: [String: Bool] {
        guard UserDefaults.standard.bool(forKey: requestedKey) else { return [:] }
        return Dictionary(uniqueKeysWithValues: folders.map { ($0, readable($0)) })
    }

    private static func readable(_ folder: String) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: folder)
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Opens each folder once so macOS asks now, one prompt per folder. Blocks while they're up.
    static func request() async -> [String: Bool] {
        await Task.detached {
            UserDefaults.standard.set(true, forKey: requestedKey)
            return Dictionary(uniqueKeysWithValues: folders.map { ($0, readable($0)) })
        }.value
    }

    /// For changing an answer later: Privacy & Security ▸ Files and Folders.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}

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

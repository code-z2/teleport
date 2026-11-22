// Which implementation to run: the modern code on iOS 17+, the Legacy/ copies on iOS 16.
//
//     if #available(iOS 17, *), !Compat.forceLegacy { modern } else { legacy }
//
// Debug builds can force the iOS 16 code on a newer iPhone (to test it without an
// iOS 16 device): launch with `-TeleportForceLegacy YES`, or `NO` to switch back.
// Stored in the App Group so the share sheet and the Teleport action follow too.

import Foundation
import TeleportCore

enum Compat {
    private static let key = "forceLegacyUI"

    private static var shared: UserDefaults? {
        UserDefaults(suiteName: TeleportConfig.fromBundle().appGroup)
    }

    static var forceLegacy: Bool {
        #if DEBUG
        shared?.bool(forKey: key) ?? false
        #else
        false
        #endif
    }

    /// Debug only: picks up `-TeleportForceLegacy YES|NO` from the launch arguments.
    static func applyLaunchArguments() {
        #if DEBUG
        if let value = UserDefaults.standard.object(forKey: "TeleportForceLegacy") {
            shared?.set((value as? Bool) ?? ((value as? String) == "YES"), forKey: key)
        }
        #endif
    }
}

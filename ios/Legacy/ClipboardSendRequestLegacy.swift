// iOS 16 support: the ObservableObject copy of `ClipboardSendRequest`
// (Shared/ClipboardControl.swift). In the app and the widget, like the intent that sets it.

import Combine
import SwiftUI

@MainActor
final class ClipboardSendRequestLegacy: ObservableObject {
    static let shared = ClipboardSendRequestLegacy()
    @Published var pending = false
}

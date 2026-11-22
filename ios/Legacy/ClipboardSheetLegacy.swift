// iOS 16 support: shows the "send clipboard" sheet from the ObservableObject flag;
// iOS 17+ uses the @Observable `ClipboardSendRequest`. Pick with `.clipboardSendSheet()`.

import SwiftUI

extension View {
    /// The "send clipboard" sheet the Control Center button / Shortcut opens.
    @ViewBuilder
    func clipboardSendSheet() -> some View {
        if #available(iOS 17, *), !Compat.forceLegacy {
            modifier(ClipboardSheetModern())
        } else {
            modifier(ClipboardSheetLegacy())
        }
    }
}

@available(iOS 17, *)
private struct ClipboardSheetModern: ViewModifier {
    @State private var request = ClipboardSendRequest.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: $request.pending) {
            ClipboardSendSheet { request.pending = false }
        }
    }
}

private struct ClipboardSheetLegacy: ViewModifier {
    @ObservedObject private var request = ClipboardSendRequestLegacy.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: $request.pending) {
            ClipboardSendSheet { request.pending = false }
        }
    }
}

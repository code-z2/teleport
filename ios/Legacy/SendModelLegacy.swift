// iOS 16 support. The iOS 17+ code uses @Observable (`SendModel` in
// ExtensionSupport/SendPicker.swift); iOS 16 has no Observation, so this copy uses
// ObservableObject. Behaviour is shared through `SendModeling`; keep the stored
// properties here in step with `SendModel`.

import Combine
import SwiftUI
import TeleportCore

@MainActor
final class SendModelLegacy: ObservableObject, SendModeling {
    @Published var phase: SendPhase = .loading
    @Published var peers: [Peer] = []
    @Published var online: [String: Bool] = [:]
    @Published var unreachable: Set<String> = []

    let teleport: Teleport?
    let loadClip: () async throws -> Clip?
    let onSent: (Peer) -> Void
    let finish: () -> Void
    let only: Platform?

    init(
        preselected: String? = nil,
        only: Platform? = nil,
        loadClip: @escaping () async throws -> Clip?,
        onSent: @escaping (Peer) -> Void = { _ in },
        finish: @escaping () -> Void
    ) {
        self.teleport = try? Teleport(config: .fromBundle(), platform: Self.platform)
        self.only = only
        self.loadClip = loadClip
        self.onSent = onSent
        self.finish = finish
        start(preselected: preselected)
    }
}

/// iOS 16: observes `SendModelLegacy` and draws the shared layout.
struct LegacySendPicker: View {
    @ObservedObject var model: SendModelLegacy

    var body: some View {
        SendPickerContent(
            phase: model.phase, peers: model.peers, online: model.online, unreachable: model.unreachable,
            send: model.send(to:), cancel: model.cancel)
    }
}

/// The send picker for whichever iOS this is: one call site, two implementations.
enum SendPickerFactory {
    @MainActor
    static func make(
        preselected: String? = nil,
        only: Platform? = nil,
        loadClip: @escaping () async throws -> Clip?,
        onSent: @escaping (Peer) -> Void = { _ in },
        finish: @escaping () -> Void
    ) -> AnyView {
        if #available(iOS 17, *), !Compat.forceLegacy {
            return AnyView(SendPicker(model: SendModel(preselected: preselected, only: only, loadClip: loadClip, onSent: onSent, finish: finish)))
        }
        return AnyView(LegacySendPicker(model: SendModelLegacy(preselected: preselected, only: only, loadClip: loadClip, onSent: onSent, finish: finish)))
    }
}

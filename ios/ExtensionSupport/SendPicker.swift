// The "Teleport to…" screen shared by the iOS Share extension, the iOS "Teleport…"
// action and the macOS Share extension. Plain SwiftUI, so it builds on both platforms.
//
// One paired device (or one chosen in the share sheet's suggestions row): sends at once.
// Several: lists them by name, with a live online/offline label for Macs.

import Observation
import SwiftUI
import TeleportCore

@MainActor
@Observable
final class SendModel {
    enum Phase: Equatable {
        case loading
        case picking
        case sending(String)
        case done(String)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var peers: [Peer] = []
    /// Mac id → online. Missing while still checking.
    private(set) var online: [String: Bool] = [:]
    /// Macs whose status couldn't be fetched (relay unreachable), shown as unknown.
    private(set) var unreachable: Set<String> = []

    private let teleport: Teleport?
    private let loadClip: () async throws -> Clip?
    private let onSent: (Peer) -> Void
    private let finish: () -> Void

    /// Restricts the choice to one kind of device ("Teleport to Mac" etc.).
    private let only: Platform?

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

    private static var platform: Platform {
        #if os(macOS)
        .mac
        #else
        .ios
        #endif
    }

    private func start(preselected: String?) {
        guard let teleport else { return phase = .failed("Open Teleport once to set it up.") }
        peers = teleport.store.sortedPeers.filter { only == nil || $0.platform == only }
        if let id = preselected, let peer = teleport.store.peers[id] { return send(to: peer) }
        switch peers.count {
        case 0:
            phase = .failed(only.map { "No \(Self.label($0)) is paired yet. Pair one in Teleport." }
                ?? "No devices yet. Open Teleport to pair one.")
        case 1: send(to: peers[0])
        default:
            phase = .picking
            watchMacs(teleport)
        }
    }

    /// Keeps each Mac's label live while the picker is open: a Mac that reconnects
    /// (after sleep or a network change) flips to Online without reopening the sheet.
    private func watchMacs(_ teleport: Teleport) {
        for peer in peers where peer.platform.hasMailbox {
            guard let mailbox = peer.mailbox else { continue }
            Task { [weak self] in
                while let self, self.phase == .picking {
                    if let state = await teleport.relay.isOnline(mailbox: mailbox) {
                        self.online[peer.id] = state
                    } else if self.online[peer.id] == nil {
                        self.unreachable.insert(peer.id)  // relay unreachable: say so, not "Offline"
                    }
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        }
    }

    func send(to peer: Peer) {
        guard let teleport else { return }
        phase = .sending(peer.name)
        Task {
            do {
                guard let clip = try await loadClip() else { return fail("There's nothing here Teleport can send.") }
                try await teleport.send(clip, to: peer)
                onSent(peer)
                phase = .done("Sent to \(peer.name)")
                try? await Task.sleep(for: .milliseconds(800))
                finish()
            } catch RelayError.offline {
                fail("\(peer.name) is offline. Check it's awake and connected.")
            } catch RelayError.peerGone {
                fail("\(peer.name) needs to open Teleport (or re-pair).")
            } catch TeleportError.tooLarge {
                fail("That's too large to teleport (10 MB max).")
            } catch {
                fail("Couldn't send: \(error.localizedDescription)")
            }
        }
    }

    func cancel() { finish() }

    static func label(_ platform: Platform) -> String {
        switch platform {
        case .ios: "iPhone"
        case .android: "Android phone"
        case .mac: "Mac"
        case .windows: "Windows PC"
        }
    }

    private func fail(_ message: String) { phase = .failed(message) }
}

struct SendPicker: View {
    let model: SendModel

    var body: some View {
        VStack(spacing: 18) {
            Label("Teleport", systemImage: "arrow.right.doc.on.clipboard")
                .font(.headline)
                .foregroundStyle(.tint)

            switch model.phase {
            case .loading:
                ProgressView()
            case .picking:
                picker
            case .sending(let name):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Sending to \(name)…").foregroundStyle(.secondary)
                }
            case .done(let message):
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text(message).font(.headline)
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center)
                    Button("Close") { model.cancel() }.buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }

    private var picker: some View {
        VStack(spacing: 10) {
            Text("Send to…").font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(model.peers) { peer in
                    Button {
                        model.send(to: peer)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: Self.symbol(peer.platform))
                                .font(.title3)
                                .frame(width: 28)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                subtitle(peer)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if peer.id != model.peers.last?.id { Divider().padding(.leading, 58) }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            Button("Cancel", role: .cancel) { model.cancel() }
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func subtitle(_ peer: Peer) -> some View {
        if peer.platform.hasMailbox {
            switch model.online[peer.id] {
            case true?: Label("Online", systemImage: "circle.fill").labelStyle(StatusLabel(color: .green))
            case false?: Label("Offline", systemImage: "circle.fill").labelStyle(StatusLabel(color: .red))
            case nil:
                Text(model.unreachable.contains(peer.id) ? "Status unavailable" : "Checking…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(peer.platform == .ios ? "iPhone" : "Android").font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func symbol(_ platform: Platform) -> String {
        switch platform {
        case .ios: "iphone"
        case .android: "candybarphone"
        case .mac: "laptopcomputer"
        case .windows: "pc"
        }
    }
}

/// A small coloured dot followed by the label text.
private struct StatusLabel: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title.font(.caption).foregroundStyle(.secondary)
        }
    }
}

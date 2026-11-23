// The "Teleport to…" screen shared by the iOS Share extension, the iOS "Teleport" action,
// the Control Center sheet and the macOS Share extension. Plain SwiftUI, on both platforms.
//
// One paired device (or one chosen in the share sheet's suggestions row): sends at once.
// Several: lists them by name, with a live online/offline label for computers.
//
// iOS 17+ and macOS use the @Observable `SendModel` below; iOS 16 uses the
// ObservableObject copy in Legacy/SendModelLegacy.swift. Both share the logic in the
// `SendModeling` extension and the layout in `SendPickerContent`.

import Observation
import SwiftUI
import TeleportCore

enum SendPhase: Equatable {
    case loading
    case picking
    case sending(String)
    case done(String)
    case failed(String)
}

/// The state and configuration both models store; the behaviour lives in the extension.
@MainActor
protocol SendModeling: AnyObject, Sendable {
    var phase: SendPhase { get set }
    /// Upload progress (0…1) while a file is sending; nil for quick clips.
    var progress: Double? { get set }
    var peers: [Peer] { get set }
    /// Computer id → online. Missing while still checking.
    var online: [String: Bool] { get set }
    /// Computers whose status couldn't be fetched (relay unreachable), shown as unknown.
    var unreachable: Set<String> { get set }

    var teleport: Teleport? { get }
    var loadClip: () async throws -> Outgoing? { get }
    var onSent: (Peer) -> Void { get }
    var finish: () -> Void { get }
    /// Restricts the choice to one kind of device.
    var only: Platform? { get }
}

extension SendModeling {
    static var platform: Platform {
        #if os(macOS)
        .mac
        #else
        .ios
        #endif
    }

    func start(preselected: String?) {
        guard let teleport else { return phase = .failed("Open Teleport once to set it up.") }
        peers = teleport.store.sortedPeers.filter { only == nil || $0.platform == only }
        if let id = preselected, let peer = teleport.store.peers[id] { return send(to: peer) }
        switch peers.count {
        case 0:
            phase = .failed(only.map { "No \(SendText.label($0)) is paired yet. Pair one in Teleport." }
                ?? "No devices yet. Open Teleport to pair one.")
        case 1: send(to: peers[0])
        default:
            phase = .picking
            watchComputers(teleport)
        }
    }

    /// Keeps each computer's label live while the picker is open: one that reconnects
    /// (after sleep or a network change) flips to Online without reopening the sheet.
    private func watchComputers(_ teleport: Teleport) {
        for peer in peers where peer.platform.hasMailbox {
            guard let mailbox = peer.mailbox else { continue }
            Task { [weak self] in
                while let self, self.phase == .picking {
                    if let state = await teleport.relay.isOnline(mailbox: mailbox) {
                        self.online[peer.id] = state
                    } else if self.online[peer.id] == nil {
                        self.unreachable.insert(peer.id)  // relay unreachable: say so, not "Offline"
                    }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
        }
    }

    func send(to peer: Peer) {
        guard let teleport else { return }
        phase = .sending(peer.name)
        Task {
            do {
                guard let outgoing = try await loadClip() else { return fail("There's nothing here Teleport can send.") }
                try await teleport.send(outgoing, to: peer) { [weak self] sent, total in
                    Task { @MainActor in self?.progress = total > 0 ? Double(sent) / Double(total) : nil }
                }
                onSent(peer)
                phase = .done("Sent to \(peer.name)")
                try? await Task.sleep(nanoseconds: 800_000_000)
                finish()
            } catch RelayError.offline {
                fail("\(peer.name) is offline. Check it's awake and connected.")
            } catch RelayError.peerGone {
                fail("\(peer.name) needs to open Teleport (or re-pair).")
            } catch TeleportError.tooLarge {
                fail("That's too large to teleport (250 MB max).")
            } catch {
                fail("Couldn't send: \(error.localizedDescription)")
            }
        }
    }

    func cancel() { finish() }

    private func fail(_ message: String) { phase = .failed(message) }
}

enum SendText {
    static func label(_ platform: Platform) -> String {
        switch platform {
        case .ios: "iPhone"
        case .android: "Android phone"
        case .mac: "Mac"
        case .windows: "Windows PC"
        }
    }
}

/// iOS 17+ and macOS.
@available(iOS 17, macOS 14, *)
@MainActor
@Observable
final class SendModel: SendModeling {
    var phase: SendPhase = .loading
    var progress: Double?
    var peers: [Peer] = []
    var online: [String: Bool] = [:]
    var unreachable: Set<String> = []

    @ObservationIgnored let teleport: Teleport?
    @ObservationIgnored let loadClip: () async throws -> Outgoing?
    @ObservationIgnored let onSent: (Peer) -> Void
    @ObservationIgnored let finish: () -> Void
    @ObservationIgnored let only: Platform?

    init(
        preselected: String? = nil,
        only: Platform? = nil,
        loadClip: @escaping () async throws -> Outgoing?,
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

/// iOS 17+ and macOS: observes `SendModel` and draws the shared layout.
@available(iOS 17, macOS 14, *)
struct SendPicker: View {
    let model: SendModel

    var body: some View {
        SendPickerContent(
            phase: model.phase, progress: model.progress, peers: model.peers, online: model.online, unreachable: model.unreachable,
            send: model.send(to:), cancel: model.cancel)
    }
}

/// The layout, drawn from plain values so both the modern and the legacy model can feed it.
struct SendPickerContent: View {
    let phase: SendPhase
    let progress: Double?
    let peers: [Peer]
    let online: [String: Bool]
    let unreachable: Set<String>
    let send: (Peer) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Label("Teleport", systemImage: "arrow.right.doc.on.clipboard")
                .font(.headline)
                .foregroundStyle(.tint)

            switch phase {
            case .loading:
                ProgressView()
            case .picking:
                picker
            case .sending(let name):
                VStack(spacing: 12) {
                    if let progress {
                        ProgressView(value: progress).frame(maxWidth: 240)
                    } else {
                        ProgressView()
                    }
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
                    Button("Close") { cancel() }.buttonStyle(.bordered)
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
                ForEach(peers) { peer in
                    Button {
                        send(peer)
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
                    if peer.id != peers.last?.id { Divider().padding(.leading, 58) }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            Button("Cancel", role: .cancel) { cancel() }
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func subtitle(_ peer: Peer) -> some View {
        if peer.platform.hasMailbox {
            switch online[peer.id] {
            case true?: Label("Online", systemImage: "circle.fill").labelStyle(StatusLabel(color: .green))
            case false?: Label("Offline", systemImage: "circle.fill").labelStyle(StatusLabel(color: .red))
            case nil:
                Text(unreachable.contains(peer.id) ? "Status unavailable" : "Checking…")
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

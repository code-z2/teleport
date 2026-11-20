import CoreImage.CIFilterBuiltins
import SwiftUI
import TeleportCore

/// The window that drops down from the menu bar icon.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @State private var editingName = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if !model.requests.isEmpty { requestsSection }
            if let code = model.pairingCode { pairingSection(code) }
            devicesSection
            Divider()
            settingsSection
            if let activity = model.activity {
                Text(activity)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Pair a device…", systemImage: "qrcode") { model.showPairingCode() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.reload() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.doc.on.clipboard")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Teleport").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !model.isOnline {
                Button("Retry") { model.reconnect() }.controlSize(.small)
            }
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .online: .green
        case .connecting: .orange
        case .offline: .red
        }
    }

    private var statusText: String {
        switch model.state {
        case .online: "Online. Your phones can reach this Mac"
        case .connecting: "Connecting…"
        case .offline(let reason): "Offline: \(reason)"
        }
    }

    // MARK: Pairing

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.requests) { request in
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(request.name) wants to pair", systemImage: request.platform.symbol)
                        .font(.callout.weight(.semibold))
                    Text("Allow it to send to this Mac and receive from it.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Deny") { model.deny(request) }
                        Button("Allow") { model.allow(request) }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func pairingSection(_ code: String) -> some View {
        VStack(spacing: 10) {
            QRImage(text: code)
                .frame(width: 200, height: 200)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            Text("In Teleport on your phone, tap **Scan a code**, then click **Allow** here.")
                .font(.callout)
                .multilineTextAlignment(.center)
            Text("Valid for 10 minutes, for one device.").font(.caption).foregroundStyle(.secondary)
            Button("Done") { model.pairingCode = nil }.controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Devices").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.peers.isEmpty {
                Text("No devices yet. Choose **Pair a device…** below.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.peers) { peer in
                HStack(spacing: 10) {
                    Image(systemName: peer.platform.symbol)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text(peer.name).lineLimit(1)
                    Spacer()
                    Button {
                        model.sendClipboard(to: peer)
                    } label: {
                        Label("Send clipboard", systemImage: "paperplane")
                    }
                    .controlSize(.small)
                    .help("Send what's on this Mac's clipboard to \(peer.name)")
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Remove \(peer.name)", role: .destructive) { model.remove(peer) }
                }
            }
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This Mac").foregroundStyle(.secondary)
                Spacer()
                if editingName {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .onSubmit { model.rename(draftName); editingName = false }
                } else {
                    Text(model.name).lineLimit(1)
                    Button("Rename") { draftName = model.name; editingName = true }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
            Toggle(isOn: $model.keepAwakeOnPower) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stay awake on power")
                    Text("Keeps the Mac reachable while it's plugged in. The display still sleeps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Save received images to Downloads", isOn: $model.saveImages)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct QRImage: View {
    let text: String

    var body: some View {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let image = filter.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
        return Group {
            if let image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
            }
        }
    }
}

extension Platform {
    var symbol: String {
        switch self {
        case .ios: "iphone"
        case .android: "candybarphone"
        case .mac: "laptopcomputer"
        }
    }
}

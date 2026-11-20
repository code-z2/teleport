import CoreImage.CIFilterBuiltins
import FirebaseCore
import Photos
import SwiftUI
import TeleportCore
import VisionKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var teleport: Teleport? = try? Teleport()
    @State private var clipboardRequest = ClipboardSendRequest.shared
    @State private var name = ""
    @State private var peers: [Peer] = []
    @State private var requests: [PairRequest] = []
    @State private var waiting: [Peer] = []
    @State private var showingQR = false
    @State private var scanning = false
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                if let teleport {
                    Section {
                        TextField("e.g. Peso's iPhone", text: $name)
                            .onSubmit { saveName() }
                            .submitLabel(.done)
                    } header: {
                        Text("This iPhone's name")
                    } footer: {
                        Text("Other devices show this name, e.g. \"Teleport (\(name.isEmpty ? "Peso's iPhone" : name))\".")
                    }

                    if !requests.isEmpty {
                        Section("Pairing requests") {
                            ForEach(requests) { request in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("**\(request.name)** (\(request.platform.label)) wants to pair")
                                    HStack {
                                        Button("Allow") { allow(request) }.buttonStyle(.borderedProminent)
                                        Button("Deny", role: .destructive) { teleport.deny(request.id); reload() }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        ForEach(peers) { peer in
                            if peer.platform.hasMailbox {
                                // A Mac's files can be browsed over an end-to-end encrypted session.
                                NavigationLink {
                                    MacBrowserRoot(teleport: teleport, mac: peer)
                                } label: {
                                    Label {
                                        VStack(alignment: .leading) {
                                            Text(peer.name)
                                            Text("Browse files").font(.caption).foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: peer.platform.symbol)
                                    }
                                }
                            } else {
                                Label(peer.name, systemImage: peer.platform.symbol)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { teleport.remove(peers[i].id) }
                            reload()
                        }
                        ForEach(waiting) { peer in
                            Label("Waiting for \(peer.name) to tap Allow…", systemImage: "hourglass")
                                .foregroundStyle(.secondary)
                        }
                        if peers.isEmpty && waiting.isEmpty {
                            Text("No devices yet").foregroundStyle(.secondary)
                        }
                        Button("Show my pairing code", systemImage: "qrcode") { showingQR = true }
                            .disabled(name.isEmpty)
                        Button("Scan a device's code", systemImage: "qrcode.viewfinder") { scanning = true }
                            .disabled(name.isEmpty || !DataScannerViewController.isSupported)
                    } header: {
                        Text("Devices")
                    } footer: {
                        Text("Pairing takes one scan: one device shows its code, the other scans it, then the first taps Allow. Swipe left to remove a device.")
                    }
                } else {
                    Text("Could not load device keys. Check Config/Teleport.xcconfig and entitlements.")
                }
                if !status.isEmpty { Section { Text(status).font(.footnote) } }
            }
            .navigationTitle("Teleport")
            .onAppear {
                name = teleport?.store.deviceName ?? ""
                reload()
                // Ask once for add-only Photos access, so "Save" also works from the
                // Live Activity (a background intent can't show the prompt itself).
                if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
                    PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
            .onReceive(NotificationCenter.default.publisher(for: .teleportPushStateChanged)) { _ in reload() }
            // From the Control Center button (or Siri / Shortcuts): send what's on the clipboard.
            .sheet(isPresented: $clipboardRequest.pending) {
                ClipboardSendSheet { clipboardRequest.pending = false }
            }
            .sheet(isPresented: $showingQR) {
                if let teleport { PairingCodeSheet(teleport: teleport, name: name) }
            }
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    scan(code)
                }
                .ignoresSafeArea()
            }
        }
    }

    private func reload() {
        guard let teleport else { return }
        peers = teleport.store.sortedPeers
        requests = teleport.store.pairRequests.values.sorted { $0.expires < $1.expires }
        waiting = teleport.store.pendingOutbound.values.filter { teleport.store.peers[$0.id] == nil }
        for peer in peers { ShareSuggestion.donate(for: peer) }
    }

    private func saveName() {
        guard let teleport else { return }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != teleport.store.deviceName else { return }
        teleport.store.deviceName = name
        Task { await teleport.announce(name: name) }
        status = "Name saved. Paired devices will show \"\(name)\"."
    }

    private func scan(_ code: String) {
        guard let teleport else { return }
        saveName()
        status = "Sending pairing request…"
        Task {
            do {
                let peer = try await teleport.scan(code, name: name)
                status = "Tap Allow on \(peer.name) to finish pairing."
            } catch RelayError.offline {
                status = "That Mac is offline. Check it's awake and connected, then scan again."
            } catch TeleportError.invalidCode {
                status = "That isn't a Teleport pairing code (or it's an old one — update the other app)."
            } catch {
                status = "Pairing failed: \(error)"
            }
            reload()
        }
    }

    private func allow(_ request: PairRequest) {
        guard let teleport else { return }
        Task {
            do {
                let peer = try await teleport.allow(request.id, name: name)
                status = "Paired with \(peer.name)"
            } catch {
                status = "Couldn't finish pairing: \(error)"
            }
            reload()
        }
    }
}

/// Our QR code with a fresh one-time secret. Closing and reopening makes a new one.
struct PairingCodeSheet: View {
    let teleport: Teleport
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let code {
                    QRCode(text: code)
                    Text("Scan this with Teleport on the other device, then tap **Allow** here.")
                        .multilineTextAlignment(.center)
                    Text("Valid for 10 minutes, for one device.").font(.footnote).foregroundStyle(.secondary)
                } else if FirebaseApp.app() == nil {
                    Text("GoogleService-Info.plist is missing from the app bundle.").foregroundStyle(.red)
                } else if let error = AppDelegate.pushRegistrationError {
                    Text("Push registration failed: \(error)").foregroundStyle(.red)
                } else {
                    ProgressView("Waiting for a push token…")
                }
            }
            .padding()
            .navigationTitle(name)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear(perform: makeCode)
            // A code is single-use and lasts 10 minutes: swap in a fresh one as soon as
            // it's spent (someone scanned it) or expired, so the QR shown always works.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if code != nil, teleport.store.currentPairingSecret == nil { makeCode() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .teleportPushStateChanged)) { _ in
                if code == nil { makeCode() }
                // Someone scanned us: close so the Allow prompt in the list is visible.
                if !teleport.store.pairRequests.isEmpty { dismiss() }
            }
        }
    }

    private func makeCode() {
        guard teleport.store.ownFCMToken != nil else { return }
        code = try? teleport.qrCode(name: name)
    }
}

extension Platform {
    var label: String {
        switch self {
        case .ios: "iPhone"
        case .android: "Android"
        case .mac: "Mac"
        case .windows: "Windows PC"
        }
    }

    var symbol: String {
        switch self {
        case .ios: "iphone"
        case .android: "candybarphone"
        case .mac: "laptopcomputer"
        case .windows: "pc"
        }
    }
}

struct QRCode: View {
    let text: String

    var body: some View {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let image = filter.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
        return Group {
            if let image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 260, height: 260)
            }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if !done, let s = code.payloadStringValue, s.hasPrefix(PairingCard.prefix) {
                    done = true
                    onCode(s)
                }
            }
        }
    }
}

import CoreImage.CIFilterBuiltins
import SwiftUI
import TeleportCore
import VisionKit

struct ContentView: View {
    @State private var teleport: Teleport? = try? Teleport()
    @State private var peer: Peer?
    @State private var scanning = false
    @State private var status = ""
    @State private var testText = "Hello from iPhone"

    var body: some View {
        NavigationStack {
            Form {
                if let teleport {
                    Section("This iPhone") {
                        if let card = try? teleport.myCard(name: UIDevice.current.name).encoded(),
                           teleport.store.ownFCMToken != nil {
                            QRCode(text: card).frame(maxWidth: .infinity)
                            Text("Scan this from the other phone.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Waiting for a push token… (needs GoogleService-Info.plist and notification permission)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Paired device") {
                        if let peer {
                            LabeledContent(peer.name, value: peer.platform.rawValue)
                            TextField("Text", text: $testText)
                            Button("Send test clip") { send(.text(testText)) }
                        } else {
                            Text("Not paired").foregroundStyle(.secondary)
                        }
                        Button(peer == nil ? "Scan other phone" : "Re-pair") { scanning = true }
                            .disabled(!DataScannerViewController.isSupported)
                    }
                } else {
                    Text("Could not load device keys. Check Config/Teleport.xcconfig and entitlements.")
                }
                if !status.isEmpty { Section { Text(status).font(.footnote) } }
            }
            .navigationTitle("Teleport")
            .onAppear { peer = teleport?.store.peer }
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    do {
                        peer = try teleport?.pair(with: code)
                        status = "Paired with \(peer?.name ?? "?")"
                    } catch {
                        status = "Not a Teleport code"
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func send(_ clip: Clip) {
        guard let teleport else { return }
        status = "Sending…"
        Task {
            do {
                try await teleport.send(clip)
                status = "Sent"
            } catch RelayError.peerGone {
                status = "The other phone's push token expired — re-pair."
            } catch {
                status = "Failed: \(error)"
            }
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

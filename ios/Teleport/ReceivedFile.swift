import Photos
import QuickLook
import SwiftUI
import TeleportCore
import UniformTypeIdentifiers

/// Large files opened from their notification. Works on iOS 16 and later (no Observation).
@MainActor
final class IncomingFiles: ObservableObject {
    struct Item: Identifiable { let env: String; let saveToPhotos: Bool; var id: String { env } }

    static let shared = IncomingFiles()
    /// The file being shown, if any.
    @Published var item: Item?

    /// `saveToPhotos`: the notification's "Save to Photos": save as soon as it's downloaded.
    func open(_ env: String, saveToPhotos: Bool = false) { item = Item(env: env, saveToPhotos: saveToPhotos) }
}

/// Downloads a received file with progress, previews it if Quick Look can, and offers
/// Save to Files, Save to Photos and Share. Nothing is kept unless you save it.
struct ReceivedFileView: View {
    let env: String
    var saveWhenReady = false
    let done: () -> Void

    enum Phase { case opening, downloading(Double), ready(URL), failed(String) }
    @State private var phase: Phase = .opening
    @State private var pointer: BlobPointer?
    @State private var sender = ""
    @State private var exporting: URL?
    @State private var sharing: URL?
    @State private var notice: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(pointer?.name ?? "File")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done", action: done) }
                    if case .ready(let url) = phase {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("Save to Files", systemImage: "folder") { exporting = url }
                                if isMedia { Button("Save to Photos", systemImage: "photo.on.rectangle") { saveToPhotos(url) } }
                                Button("Share…", systemImage: "square.and.arrow.up") { sharing = url }
                            } label: { Text("Save") }
                        }
                    }
                }
        }
        .task {
            await download()
            if saveWhenReady, case .ready(let url) = phase, isMedia { saveToPhotos(url) }
        }
        .safeAreaInset(edge: .bottom) {
            // Photos and videos: the obvious next step, one tap.
            if case .ready(let url) = phase, isMedia {
                Button {
                    saveToPhotos(url)
                } label: {
                    Label(saved ? "Saved to Photos" : "Save to Photos", systemImage: saved ? "checkmark.circle.fill" : "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saved)
                .padding()
                .background(.bar)
            }
        }
        .sheet(item: $exporting) { url in FileExporter(url: url).ignoresSafeArea() }
        .sheet(item: $sharing) { url in ShareSheet(items: [url]).ignoresSafeArea() }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK") {} }
    }

    private var isMedia: Bool {
        guard let mime = pointer?.mime else { return false }
        return mime.hasPrefix("image/") || mime.hasPrefix("video/")
    }

    @ViewBuilder
    private var content: some View {
        if case .ready(let url) = phase, QLPreviewController.canPreview(url as NSURL) {
            QuickLookView(url: url).ignoresSafeArea(edges: .bottom)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: FileSymbols.symbol(for: pointer?.name ?? "")).font(.system(size: 64)).foregroundStyle(.secondary)
                if let p = pointer {
                    Text(p.name ?? "File").font(.headline).multilineTextAlignment(.center)
                    Text("\(Int64(p.size).formatted(.byteCount(style: .file))) from \(sender)").font(.caption).foregroundStyle(.secondary)
                }
                switch phase {
                case .opening: ProgressView()
                case .downloading(let f):
                    ProgressView(value: f).frame(maxWidth: 240)
                    Text("Downloading… \(Int(f * 100))%").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                case .ready: Text("Can't preview this file. Use Save to keep it.").font(.footnote).foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await download() } }.buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding()
        }
    }

    private func download() async {
        // Started by the notification extension? Follow it instead of downloading twice.
        if let teleport = try? Teleport(), let item = teleport.inbox.item(env: env) {
            sender = item.from
            pointer = BlobPointer(id: "", mime: item.mime, size: item.size, key: "", n: "", name: item.name)
            while true {
                guard let now = teleport.inbox.item(item.id) else { break }
                switch now.state {
                case .ready: return phase = .ready(teleport.inbox.file(now))
                case .downloading: phase = .downloading(now.progress ?? 0)
                case .failed, .cancelled: break
                }
                if now.state != .downloading { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        do {
            let teleport = try Teleport()
            guard case .file(let p, _, let from) = try await teleport.receive(env, firstDelivery: false) else {
                return phase = .failed("This isn't a file Teleport can download.")
            }
            pointer = p
            sender = from.name
            phase = .downloading(0)
            let dir = URL.cachesDirectory.appending(path: "Received/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appending(path: (p.name ?? "File").replacingOccurrences(of: "/", with: "-"))
            try await teleport.downloadFile(p, to: dest) { [env] done, total in
                Task { @MainActor in
                    let f = total > 0 ? Double(done) / Double(total) : 0
                    phase = .downloading(f)
                    FileActivity.progress(env, f, name: p.name)
                }
            }
            phase = .ready(dest)
            if !(saveWhenReady && isMedia) { FileActivity.ready(env, name: p.name) }
        } catch RelayError.http(404, _) {
            phase = .failed("This file is no longer on the relay (files are kept for a day).")
            FileActivity.finish(env, note: "No longer available")
        } catch {
            phase = .failed("Couldn't download: \(error.localizedDescription)")
            FileActivity.finish(env, note: "Download failed")
        }
    }

    private func saveToPhotos(_ url: URL) {
        Task {
            do {
                let video = pointer?.mime.hasPrefix("video/") == true
                try await PhotoSaver.saveFile(url, video: video)
                saved = true
                FileActivity.finish(env, note: "Saved to Photos")
            } catch {
                notice = "Couldn't save to Photos: \(error.localizedDescription)"
            }
        }
    }
}

/// Presents `ReceivedFileView` when a file notification is tapped.
struct IncomingFileSheet: ViewModifier {
    @ObservedObject private var incoming = IncomingFiles.shared
    func body(content: Content) -> some View {
        content.fullScreenCover(item: $incoming.item) { item in
            ReceivedFileView(env: item.env, saveWhenReady: item.saveToPhotos) { incoming.item = nil }
        }
    }
}

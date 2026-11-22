// iOS 16 support: the computer file browser and preview with ObservableObject models.
// iOS 17+ uses the @Observable versions in Teleport/MacBrowser.swift and FilePreview.swift.
// Generated from those files: keep the two in step when changing either.
// Shared, unchanged pieces (Quick Look, share sheet, file icons, preview cache) live there.

import Combine
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import TeleportCore
import UniformTypeIdentifiers

/// One end-to-end encrypted file session with a Mac, shared by every folder screen
/// pushed while browsing it. Reconnects on demand if the session drops.
/// iOS 17+; iOS 16 uses `MacConnectionLegacy` (Legacy/MacBrowserLegacy.swift).
@MainActor
final class MacConnectionLegacy: ObservableObject {
    let teleport: Teleport
    let mac: Peer
    @Published private(set) var transfers: [TransferLegacy] = []
    private var client: FileSessionClient?
    private var connecting: Task<FileSessionClient, Error>?

    init(teleport: Teleport, mac: Peer) {
        self.teleport = teleport
        self.mac = mac
        try? FileManager.default.removeItem(at: PreviewCache.url)
    }

    private func session() async throws -> FileSessionClient {
        if let client { return client }
        if let connecting { return try await connecting.value }
        let task = Task { [teleport, mac] in try await FileSessionClient.connect(teleport: teleport, to: mac) }
        connecting = task
        defer { connecting = nil }
        let c = try await task.value
        client = c
        return c
    }

    /// Runs `op`, reconnecting once if the old session had gone away.
    func run<T: Sendable>(_ op: @escaping (FileSessionClient) async throws -> T) async throws -> T {
        do {
            return try await op(try await session())
        } catch FileSessionError.closed {
            await client?.close()
            client = nil
            return try await op(try await session())
        }
    }

    /// Ends the session (the Mac stops showing this phone as browsing). The next
    /// operation reconnects on its own.
    func close() {
        let c = client
        client = nil
        Task { await c?.close() }
    }

    /// Folder screens currently on screen. SwiftUI may keep a popped screen's state alive,
    /// so hanging up can't wait for this object to be released: when no folder screen has
    /// been visible for a moment (moving between folders briefly drops to zero), hang up.
    private var visibleScreens = 0
    private var hangUp: Task<Void, Never>?

    func screenAppeared() {
        visibleScreens += 1
        hangUp?.cancel()
    }

    func screenDisappeared() {
        visibleScreens = max(0, visibleScreens - 1)
        guard visibleScreens == 0 else { return }
        hangUp?.cancel()
        hangUp = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, visibleScreens == 0,
                  !transfers.contains(where: { if case .running = $0.state { true } else { false } })
            else { return }
            close()
        }
    }

    // MARK: Transfers

    func upload(_ file: URL, name: String, to dir: String, onSaved: @escaping @MainActor () -> Void) {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let t = TransferLegacy(name: name, upload: true, total: size)
        transfers.insert(t, at: 0)
        t.task = Task {
            defer { try? FileManager.default.removeItem(at: file) }  // our temporary copy
            do {
                let saved = try await run { try await $0.upload(file, to: dir, name: name) { d, total in Task { @MainActor in t.progress(d, total) } } }
                t.name = saved
                t.state = .finished(nil)
                onSaved()
            } catch is CancellationError {
                t.state = .cancelled
            } catch {
                t.state = .failed(error.localizedDescription)
            }
        }
    }

    func clearFinished() {
        transfers.removeAll { if case .running = $0.state { false } else { true } }
    }
}

@MainActor
final class TransferLegacy: ObservableObject, Identifiable {
    enum State { case running, finished(URL?), failed(String), cancelled }
    let id = UUID()
    @Published var name: String
    let upload: Bool
    @Published var done: Int64 = 0
    @Published var total: Int64
    @Published var state: State = .running
    var task: Task<Void, Never>?

    init(name: String, upload: Bool, total: Int64) {
        self.name = name; self.upload = upload; self.total = total
    }

    func progress(_ done: Int64, _ total: Int64) {
        self.done = done
        if total > 0 { self.total = total }
    }

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    func cancel() { task?.cancel() }
}

// MARK: Entry point

/// Owns one connection for the whole time the Mac's files are open, so redraws of the
/// device list don't start new sessions, and closes it when Teleport goes to the background.
struct LegacyMacBrowserRoot: View {
    @StateObject private var connection: MacConnectionLegacy
    @Environment(\.scenePhase) private var scenePhase

    init(teleport: Teleport, mac: Peer) {
        _connection = StateObject(wrappedValue: MacConnectionLegacy(teleport: teleport, mac: mac))
    }

    var body: some View {
        LegacyMacBrowserView(connection: connection, path: "")
            .onChange(of: scenePhase) { phase in
                if phase == .background { connection.close() }
            }
    }
}

// MARK: Folder screen

struct LegacyMacBrowserView: View {
    @ObservedObject var connection: MacConnectionLegacy
    let path: String

    @State private var entries: [FileEntry]?
    @State private var error: String?
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var sharing: URL?

    private var title: String {
        path.isEmpty ? connection.mac.name : (path as NSString).lastPathComponent
    }

    var body: some View {
        List {
            if !connection.transfers.isEmpty { transfersSection }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await load() } }
                }
            }
            if let entries {
                Section {
                    if entries.isEmpty {
                        Text("This folder is empty.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in row(entry) }
                } footer: {
                    if !path.isEmpty { Text("~/\(path)").font(.caption.monospaced()) }
                }
            } else if error == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to \(connection.mac.name)…").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(path.isEmpty ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("From Files", systemImage: "folder") { importing = true }
                    PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                        Label("From Photos", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label("Upload Here", systemImage: "square.and.arrow.up")
                }
            }
        }
        .refreshable { await load() }
        .onAppear { connection.screenAppeared() }
        .onDisappear { connection.screenDisappeared() }
        .task { if entries == nil { await load() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { uploadFromFiles(url) }
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items { uploadFromPhotos(item) }
        }
        .sheet(item: $sharing) { url in ShareSheet(items: [url]).ignoresSafeArea() }
    }

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        let child = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
        if entry.dir {
            NavigationLink {
                LegacyMacBrowserView(connection: connection, path: child)
            } label: {
                Label(entry.name, systemImage: "folder.fill")
            }
        } else {
            NavigationLink {
                LegacyFilePreviewView(connection: connection, path: child, entry: entry)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: FileSymbols.symbol(for: entry.name))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                        Text("\(entry.size.formatted(.byteCount(style: .file))) · \(Date(timeIntervalSince1970: TimeInterval(entry.mtime)).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var transfersSection: some View {
        Section {
            ForEach(connection.transfers) { t in LegacyTransferRow(transfer: t) { sharing = $0 } }
        } header: {
            HStack {
                Text("Transfers")
                Spacer()
                Button("Clear") { connection.clearFinished() }.font(.caption)
            }
        }
    }

    private func load() async {
        do {
            let list = try await connection.run { [path] in try await $0.list(path) }
            entries = list
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func uploadFromFiles(_ url: URL) {
        // Copy out of the provider first: the security scope ends when we return.
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let copy = tmp.appending(path: url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            connection.upload(copy, name: url.lastPathComponent, to: path) { Task { await load() } }
        } catch {
            self.error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func uploadFromPhotos(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let picked = try await item.loadTransferable(type: PickedMedia.self) else { return }
                connection.upload(picked.url, name: picked.url.lastPathComponent, to: path) { Task { await load() } }
            } catch {
                self.error = "Couldn't read that photo: \(error.localizedDescription)"
            }
        }
    }
}

private struct LegacyTransferRow: View {
    @ObservedObject var transfer: TransferLegacy
    let open: (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name).lineLimit(1)
                switch transfer.state {
                case .running:
                    ProgressView(value: transfer.fraction)
                    Text("\(transfer.done.formatted(.byteCount(style: .file))) of \(transfer.total.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .finished:
                    Text(transfer.upload ? "Uploaded" : "Downloaded").font(.caption).foregroundStyle(.green)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch transfer.state {
            case .running:
                Button("Cancel", systemImage: "xmark.circle.fill") { transfer.cancel() }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.borderless)
            case .finished(let url?):
                Button("Open", systemImage: "square.and.arrow.up") { open(url) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            default:
                EmptyView()
            }
        }
    }
}

/// A photo or video from the picker, copied to a temporary file with its original name.

// MARK: Preview

/// File → preview → save. Opening a file never saves it anywhere: the preview streams into
/// a temporary cache, and Save (Files, Photos or Share) is a separate, explicit step.
struct LegacyFilePreviewView: View {
    let connection: MacConnectionLegacy
    let path: String
    let entry: FileEntry

    /// Files above this size ask before fetching the whole thing just to look at it.
    static let autoPreviewLimit: Int64 = 50 * 1024 * 1024

    enum Phase: Equatable {
        case thumbnailOnly            // large file, waiting for "Load preview"
        case loading(Double)          // fetching the full file
        case ready(URL)               // full preview on screen
        case unsupported              // no viewer for this type
        case failed(String)
    }

    @State private var phase: Phase = .loading(0)
    @State private var thumbnail: UIImage?
    @State private var cached: URL?
    @State private var fetching: Task<URL, Error>?
    @State private var exporting: URL?
    @State private var sharing: URL?
    @State private var notice: String?

    private var type: UTType? { UTType(filenameExtension: (entry.name as NSString).pathExtension) }
    private var previewable: Bool { Self.previewable(type) }
    private var isMedia: Bool { type.map { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? false }

    var body: some View {
        content
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { saveMenu }
            }
            .task { await start() }
            .onAppear { connection.screenAppeared() }
            .onDisappear {
                fetching?.cancel()
                connection.screenDisappeared()
            }
            .sheet(item: $exporting) { url in FileExporter(url: url).ignoresSafeArea() }
            .sheet(item: $sharing) { url in ShareSheet(items: [url]).ignoresSafeArea() }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK") {}
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready(let url):
            QuickLookView(url: url).ignoresSafeArea(edges: .bottom)
        case .loading(let fraction):
            placeholder {
                ProgressView(value: fraction).frame(maxWidth: 220)
                Text("Loading preview… \(Int64(Double(entry.size) * fraction).formatted(.byteCount(style: .file))) of \(entry.size.formatted(.byteCount(style: .file)))")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        case .thumbnailOnly:
            placeholder {
                Text("This file is \(entry.size.formatted(.byteCount(style: .file))).").foregroundStyle(.secondary)
                Button("Load Preview") { loadFull() }.buttonStyle(.borderedProminent)
            }
        case .unsupported:
            placeholder {
                Text("Can't preview this file").font(.headline)
                Text("You can still save it.").font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let message):
            placeholder {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try Again") { loadFull() }.buttonStyle(.bordered)
            }
        }
    }

    /// Thumbnail (or a large file icon), the name and size, then `extra`.
    private func placeholder(@ViewBuilder _ extra: () -> some View) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 4, y: 2)
                } else {
                    Image(systemName: FileSymbols.symbol(for: entry.name))
                        .font(.system(size: 72)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                Text(entry.name).font(.headline).multilineTextAlignment(.center)
                Text("\(entry.size.formatted(.byteCount(style: .file))) · \(type?.localizedDescription ?? "File")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            extra()
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var saveMenu: some View {
        Menu {
            Button("Save to Files", systemImage: "folder") { withFile { exporting = $0 } }
            if isMedia {
                Button("Save to Photos", systemImage: "photo.on.rectangle") { withFile(saveToPhotos) }
            }
            Button("Share…", systemImage: "square.and.arrow.up") { withFile { sharing = $0 } }
        } label: {
            Text("Save")
        }
    }

    // MARK: Loading

    private func start() async {
        // The thumbnail first: it's small, and gives large or unpreviewable files a face.
        if previewable && entry.size <= Self.autoPreviewLimit {
            loadFull()
        } else {
            phase = previewable ? .thumbnailOnly : .unsupported
        }
        let data = try? await connection.run { [path] in try await $0.thumbnail(path, px: 600) }
        if let data, let image = UIImage(data: data) { thumbnail = image }
    }

    private func loadFull() {
        Task {
            do {
                let url = try await fetch()
                // Quick Look has the last word on what it can show.
                phase = QLPreviewController.canPreview(url as NSURL) ? .ready(url) : .unsupported
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The whole file in the preview cache (fetched once per screen).
    private func fetch() async throws -> URL {
        if let cached { return cached }
        if let fetching { return try await fetching.value }
        phase = .loading(0)
        let dest = PreviewCache.url.appending(path: UUID().uuidString).appending(path: entry.name)
        let size = entry.size
        let task = Task { [connection, path] in
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await connection.run {
                try await $0.download(path, to: dest) { done, total in
                    let t = total > 0 ? total : size
                    Task { @MainActor in phase = .loading(t > 0 ? Double(done) / Double(t) : 0) }
                }
            }
            return dest
        }
        fetching = task
        defer { fetching = nil }
        let url = try await task.value
        cached = url
        return url
    }

    /// Runs `action` with the full file, fetching it first if the preview didn't.
    private func withFile(_ action: @escaping (URL) -> Void) {
        if let cached { return action(cached) }
        Task {
            let before = phase
            do {
                let url = try await fetch()
                // Now the file is here anyway, show it if Quick Look can.
                phase = previewable && QLPreviewController.canPreview(url as NSURL) ? .ready(url) : .unsupported
                action(url)
            } catch is CancellationError {
                phase = before
            } catch {
                phase = before
                notice = "Couldn't get the file: \(error.localizedDescription)"
            }
        }
    }

    private func saveToPhotos(_ url: URL) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                notice = "Allow Teleport to add photos in Settings ▸ Privacy ▸ Photos."
                return
            }
            do {
                let video = type?.conforms(to: .movie) == true
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: video ? .video : .photo, fileURL: url, options: nil)
                }
                notice = "Saved to Photos"
            } catch {
                notice = "Couldn't save to Photos: \(error.localizedDescription)"
            }
        }
    }

    /// Types iOS's Quick Look can show. Checked again on the real file once it's here.
    static func previewable(_ type: UTType?) -> Bool {
        guard let type else { return false }
        let viewable: [UTType] = [
            .image, .audiovisualContent, .pdf, .text, .rtf, .rtfd, .spreadsheet, .presentation, .usdz,
        ]
        if viewable.contains(where: { type.conforms(to: $0) }) { return true }
        let documents = [
            "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
            "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages",
        ]
        return documents.contains(type.identifier)
    }
}

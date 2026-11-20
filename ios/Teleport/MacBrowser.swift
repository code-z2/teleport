import PhotosUI
import SwiftUI
import TeleportCore
import UniformTypeIdentifiers

/// One end-to-end encrypted file session with a Mac, shared by every folder screen
/// pushed while browsing it. Reconnects on demand if the session drops.
@MainActor
@Observable
final class MacConnection {
    let teleport: Teleport
    let mac: Peer
    private(set) var transfers: [Transfer] = []
    private var client: FileSessionClient?
    private var connecting: Task<FileSessionClient, Error>?

    init(teleport: Teleport, mac: Peer) {
        self.teleport = teleport
        self.mac = mac
        try? FileManager.default.removeItem(at: Self.previewCache)
    }

    /// Full files fetched for previews. Temporary: cleared each time a Mac's files are opened.
    static var previewCache: URL { URL.cachesDirectory.appending(path: "Previews", directoryHint: .isDirectory) }

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

    isolated deinit {
        let c = client
        Task { await c?.close() }
    }

    // MARK: Transfers

    func upload(_ file: URL, name: String, to dir: String, onSaved: @escaping @MainActor () -> Void) {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let t = Transfer(name: name, upload: true, total: size)
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
@Observable
final class Transfer: Identifiable {
    enum State { case running, finished(URL?), failed(String), cancelled }
    let id = UUID()
    var name: String
    let upload: Bool
    var done: Int64 = 0
    var total: Int64
    var state: State = .running
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
struct MacBrowserRoot: View {
    @State private var connection: MacConnection
    @Environment(\.scenePhase) private var scenePhase

    init(teleport: Teleport, mac: Peer) {
        _connection = State(initialValue: MacConnection(teleport: teleport, mac: mac))
    }

    var body: some View {
        MacBrowserView(connection: connection, path: "")
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { connection.close() }
            }
    }
}

// MARK: Folder screen

struct MacBrowserView: View {
    let connection: MacConnection
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
        .onChange(of: photoItems) { _, items in
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
                MacBrowserView(connection: connection, path: child)
            } label: {
                Label(entry.name, systemImage: "folder.fill")
            }
        } else {
            NavigationLink {
                FilePreviewView(connection: connection, path: child, entry: entry)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol(for: entry.name))
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
            ForEach(connection.transfers) { t in TransferRow(transfer: t) { sharing = $0 } }
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

    static func symbol(for name: String) -> String {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

private struct TransferRow: View {
    let transfer: Transfer
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
private struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try copy($0.file) }
        FileRepresentation(importedContentType: .image) { try copy($0.file) }
    }

    private static func copy(_ file: URL) throws -> PickedMedia {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: dest)
        return PickedMedia(url: dest)
    }
}

/// The system share sheet: Share, Save to Files, Save Image/Video and so on.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

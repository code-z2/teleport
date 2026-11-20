import Photos
import QuickLook
import SwiftUI
import TeleportCore
import UniformTypeIdentifiers

/// File → preview → save. Opening a file never saves it anywhere: the preview streams into
/// a temporary cache, and Save (Files, Photos or Share) is a separate, explicit step.
struct FilePreviewView: View {
    let connection: MacConnection
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
                    Image(systemName: MacBrowserView.symbol(for: entry.name))
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
        let dest = MacConnection.previewCache.appending(path: UUID().uuidString).appending(path: entry.name)
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

/// QLPreviewController for one local file: zoom, video playback, PDF pages, text…
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            vc.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// "Save to Files": the system folder picker, saving a copy.
struct FileExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

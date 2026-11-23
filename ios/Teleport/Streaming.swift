import AVKit
import CryptoKit
import SwiftUI
import TeleportCore
import UniformTypeIdentifiers

// Shared by the iOS 17+ preview (FilePreview.swift) and the iOS 16 copy (Legacy/): plain
// types, no Observation.

// MARK: Resumable downloads

/// Retries a download while the computer reconnects (a Wi-Fi blip, the Mac waking up…).
/// Each try resumes from the bytes already saved, so nothing is fetched twice.
enum ResumingDownload {
    static func run(_ attempt: @escaping @Sendable () async throws -> Void, retrying: @escaping @MainActor @Sendable (Int) -> Void = { _ in }) async throws {
        var tries = 0
        while true {
            do {
                return try await attempt()
            } catch where isTransient(error) && tries < 60 {
                tries += 1
                await retrying(tries)
                try await Task.sleep(nanoseconds: UInt64(min(tries, 5)) * 1_000_000_000)
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let e = error as? FileSessionError { return [.closed, .offline, .protocolError].contains(e) }
        return error is URLError
    }
}

extension PreviewCache {
    /// The same place for the same file (path, size, date), so a preview that was cut off,
    /// or closed and reopened, carries on instead of starting over.
    static func destination(computer: String, path: String, entry: FileEntry) -> URL {
        let key = Data(SHA256.hash(data: Data("\(computer)|\(path)|\(entry.size)|\(entry.mtime)".utf8))).prefix(12)
        return url.appending(path: key.map { String(format: "%02x", $0) }.joined()).appending(path: entry.name)
    }

    /// Previews are kept for a day (then a reopened file downloads again).
    static func prune() {
        let cutoff = Date().addingTimeInterval(-86_400)
        for dir in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: dir) }
        }
    }
}

// MARK: Streaming video and audio

enum Streamable {
    static func check(_ name: String) -> Bool {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }
}

/// Plays a video or audio file from the computer while the rest is still on it: the player
/// asks for byte ranges as it needs them (including after seeking), and each one is read
/// over the encrypted session.
struct StreamingPlayer: UIViewControllerRepresentable {
    let name: String
    let size: Int64
    let read: @Sendable (_ offset: Int64, _ length: Int) async throws -> Data

    func makeCoordinator() -> StreamLoader {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        return StreamLoader(size: size, uti: type?.identifier ?? UTType.movie.identifier, read: read)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let ext = (name as NSString).pathExtension
        // A custom scheme sends every request to our loader instead of the network.
        let asset = AVURLAsset(url: URL(string: "teleport-stream://file/stream.\(ext.isEmpty ? "mp4" : ext)")!)
        asset.resourceLoader.setDelegate(context.coordinator, queue: context.coordinator.queue)
        // Play sound even with the ringer on silent, like the Videos app (the default audio
        // session follows the silent switch, so videos played mute).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        vc.player?.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: StreamLoader) {
        vc.player?.pause()
        coordinator.cancelAll()
        // Let other apps' audio (music, podcasts) resume.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.teleport.stream")
    private let size: Int64
    private let uti: String
    private let read: @Sendable (Int64, Int) async throws -> Data
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Each read is one round trip through the relay: 1 MiB keeps up with ordinary video.
    private let step = 1024 * 1024

    init(size: Int64, uti: String, read: @escaping @Sendable (Int64, Int) async throws -> Data) {
        self.size = size; self.uti = uti; self.read = read
    }

    /// Each request is answered with at most this much; the player asks again as it plays.
    /// (A player often asks for "everything to the end": serving that in one go would keep
    /// fetching the whole file and hold up seeks.)
    private let readAhead: Int64 = 4 * 1024 * 1024

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = uti
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let start = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
        let wanted = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
        let end = min(wanted, start + readAhead)
        let box = RequestBox(request)
        let key = ObjectIdentifier(request)
        let queue = queue
        let task = Task { [read, step] in
            var offset = start
            var failures = 0
            while offset < end, !Task.isCancelled {
                do {
                    let chunk = try await read(offset, Int(min(Int64(step), end - offset)))
                    if chunk.isEmpty { break }
                    // AVFoundation expects answers on the queue it calls us on.
                    queue.sync { if !box.request.isCancelled { box.request.dataRequest?.respond(with: chunk) } }
                    offset += Int64(chunk.count)
                    failures = 0
                } catch is CancellationError {
                    return
                } catch where ResumingDownload.isTransient(error) && failures < 8 {
                    // The computer dropped off for a moment: the session reconnects. Keep
                    // trying for a while (the player shows it's buffering) before giving up.
                    failures += 1
                    try? await Task.sleep(nanoseconds: UInt64(min(failures, 4)) * 500_000_000)
                } catch {
                    queue.async { if !box.request.isCancelled { box.request.finishLoading(with: error) } }
                    return
                }
            }
            guard !Task.isCancelled else { return }
            queue.async { if !box.request.isCancelled { box.request.finishLoading() } }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(request)) }?.cancel()
    }

    func cancelAll() {
        let all = lock.withLock { () -> [Task<Void, Never>] in defer { tasks = [:] }; return Array(tasks.values) }
        all.forEach { $0.cancel() }
    }

    private final class RequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
    }
}

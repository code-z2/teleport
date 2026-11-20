import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif

/// The Mac's end of one file session: checks the phone's hello, then serves
/// list / download / upload inside the home folder (SPEC.md "File sessions").
public actor FileServer {
    public struct Options: Sendable {
        public var home: URL
        public var showHidden: Bool
        public init(home: URL, showHidden: Bool) { self.home = home; self.showHidden = showHidden }
    }

    private let pipe: any SessionPipe
    private let signer: any SigningKey
    private let mailbox: String
    private let phones: @Sendable (String) -> Peer?
    private let options: Options
    private let homeReal: URL
    private var tx: FrameCipher?
    private var rx: FrameCipher?

    private struct Download { var task: Task<Void, Never>; var acked: Int64; var waiter: CheckedContinuation<Void, Never>? }
    private var downloads: [UInt32: Download] = [:]

    private struct Upload {
        var dir: URL; var name: String; var size: Int64
        var partial: URL; var handle: FileHandle; var hasher = SHA256()
        var received: Int64 = 0; var acked: Int64 = 0
    }
    private var uploads: [UInt32: Upload] = [:]

    /// The phone that opened this session, once it's verified.
    public private(set) var phone: Peer?

    /// - Parameter phones: looks up a paired phone by fingerprint.
    public init(pipe: any SessionPipe, signer: any SigningKey, mailbox: String, options: Options,
                phones: @escaping @Sendable (String) -> Peer?) {
        self.pipe = pipe; self.signer = signer; self.mailbox = mailbox
        self.options = options; self.phones = phones
        self.homeReal = options.home.resolvingSymlinksInPath()
    }

    /// Runs until the phone goes away. Cleans up partial uploads on the way out.
    public func run(now: @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }) async {
        var it = pipe.incoming.makeAsyncIterator()
        do {
            guard let first = try await it.next() else { return finish() }
            guard try accept(first, now: now()) else { return finish() }
            while let frame = try await it.next() {
                guard var rx else { break }
                let plain = try rx.open(frame)
                self.rx = rx
                try await handle(try SessionFrame.decode(plain))
            }
        } catch {}
        finish()
    }

    private func finish() {
        for d in downloads.values { d.task.cancel(); d.waiter?.resume() }
        downloads = [:]
        for u in uploads.values { discard(u) }
        uploads = [:]
        pipe.close()
    }

    // MARK: Handshake

    private func accept(_ data: Data, now: Int) throws -> Bool {
        func refuse(_ code: String) -> Bool {
            pipe.send(Data(#"{"t":"error","code":"\#(code)"}"#.utf8))
            return false
        }
        guard let hello = try? JSONDecoder().decode(SessionCrypto.Hello.self, from: data), hello.t == "hello" else {
            return refuse("version")
        }
        guard hello.v == 1 else { return refuse("version") }
        guard let peer = phones(hello.from), peer.platform.isPhone else { return refuse("denied") }
        let helloT = SessionCrypto.helloTranscript(mailbox: mailbox, hello)
        guard let sig = Data(base64URL: hello.sig), let phoneEpk = Data(base64URL: hello.epk),
              SessionCrypto.verify(sig, of: helloT, by: peer.ks)
        else { return refuse("signature") }
        guard abs(hello.ts - now) <= 300 else { return refuse("stale") }

        let eph = P256.KeyAgreement.PrivateKey()
        let epk = eph.publicKey.x963Representation.base64URL
        let n = Data.random(16).base64URL
        let acceptT = SessionCrypto.acceptTranscript(hello: helloT, epk: epk, n: n)
        let accept = SessionCrypto.Accept(epk: epk, n: n, sig: try signer.sign(acceptT).base64URL)
        let keys = try SessionCrypto.keys(ownEphemeral: eph, otherEpk: phoneEpk, acceptTranscript: acceptT)
        tx = FrameCipher(key: keys.macToPhone, dir: SessionCrypto.macToPhone)
        rx = FrameCipher(key: keys.phoneToMac, dir: SessionCrypto.phoneToMac)
        phone = peer
        pipe.send(try JSONEncoder().encode(accept))
        return true
    }

    // MARK: Frames

    private func send(_ frame: SessionFrame) {
        guard var tx, let data = try? tx.seal(try frame.encoded()) else { return }
        self.tx = tx
        pipe.send(data)
    }

    private func fail(_ id: UInt32, _ code: String, _ message: String) {
        send(.control(.error(id, code, message)))
    }

    private func handle(_ frame: SessionFrame) async throws {
        switch frame {
        case .data(let id, let bytes):
            receiveUpload(id, bytes)
        case .control(let c):
            switch c.op {
            case "list": list(c)
            case "download": startDownload(c)
            case "thumbnail": startThumbnail(c)
            case "upload": startUpload(c)
            case "done": finishUpload(c)
            case "ack":
                guard var d = downloads[c.id] else { return }
                d.acked = max(d.acked, c.bytes ?? 0)
                d.waiter?.resume(); d.waiter = nil
                downloads[c.id] = d
            case "cancel":
                if let d = downloads.removeValue(forKey: c.id) { d.task.cancel(); d.waiter?.resume() }
                if let u = uploads.removeValue(forKey: c.id) { discard(u) }
            default:
                fail(c.id, "bad_path", "Unknown request \(c.op).")
            }
        }
    }

    // MARK: Paths

    enum PathError: Error { case bad, denied }

    /// Resolves a home-relative path, following symlinks, and keeps it inside home.
    func resolve(_ relative: String) throws -> URL {
        guard let clean = FilePaths.check(relative, showHidden: options.showHidden) else { throw PathError.bad }
        let url = clean.isEmpty ? homeReal : homeReal.appending(path: clean)
        let real = url.resolvingSymlinksInPath()
        guard inHome(real) else { throw PathError.denied }
        return real
    }

    private func inHome(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path, h = homeReal.standardizedFileURL.path
        return p == h || p.hasPrefix(h.hasSuffix("/") ? h : h + "/")
    }

    private func pathError(_ id: UInt32, _ error: Error) {
        switch error {
        case PathError.bad: fail(id, "bad_path", "That location isn't allowed.")
        case PathError.denied: fail(id, "denied", "That's outside your home folder.")
        case let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile:
            fail(id, "not_found", "That item no longer exists.")
        case let e as CocoaError where e.code == .fileReadNoPermission || e.code == .fileWriteNoPermission:
            fail(id, "denied", "macOS didn't allow Teleport to open that. Check Privacy & Security ▸ Files and Folders.")
        default: fail(id, "io", error.localizedDescription)
        }
    }

    // MARK: List

    private func list(_ c: Control) {
        do {
            let path = c.path ?? ""
            let dir = try resolve(path)
            let topLevel = FilePaths.check(path, showHidden: true)?.isEmpty ?? false
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
            let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
            var entries: [FileEntry] = []
            for item in items {
                let name = item.lastPathComponent
                guard FilePaths.visible(name, inTopLevel: topLevel, showHidden: options.showHidden) else { continue }
                var target = item
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    target = item.resolvingSymlinksInPath()
                    guard inHome(target) else { continue }  // links out of home aren't shown
                }
                guard let v = try? target.resourceValues(forKeys: Set(keys)) else { continue }
                entries.append(FileEntry(
                    name: name, dir: v.isDirectory ?? false, size: Int64(v.fileSize ?? 0),
                    mtime: Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0)))
            }
            entries.sort { a, b in
                a.dir != b.dir ? a.dir : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            var reply = Control("entries", id: c.id)
            reply.path = path; reply.entries = entries
            send(.control(reply))
        } catch {
            pathError(c.id, error)
        }
    }

    // MARK: Download

    private func startDownload(_ c: Control) {
        let id = c.id
        let url: URL, size: Int64
        do {
            url = try resolve(c.path ?? "")
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard v.isDirectory != true else { return fail(id, "bad_path", "Folders can't be downloaded.") }
            size = Int64(v.fileSize ?? 0)
            _ = try FileHandle(forReadingFrom: url).close()  // surfaces permission errors now
        } catch {
            return pathError(id, error)
        }
        var meta = Control("meta", id: id)
        meta.size = size
        meta.mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        send(.control(meta))

        let offset = max(0, min(c.offset ?? 0, size))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.stream(id, url: url, from: offset)
        }
        downloads[id] = Download(task: task, acked: offset, waiter: nil)
    }

    private func stream(_ id: UInt32, url: URL, from offset: Int64) async {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            // The final hash covers the whole file, including any skipped prefix.
            var hashed: Int64 = 0
            while hashed < offset, let chunk = try handle.read(upToCount: Int(min(Int64(SessionCrypto.chunkSize), offset - hashed))), !chunk.isEmpty {
                hasher.update(data: chunk); hashed += Int64(chunk.count)
            }
            var sent = offset
            while let chunk = try handle.read(upToCount: SessionCrypto.chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                await waitForWindow(id, sent: sent)
                try Task.checkCancellation()
                guard downloads[id] != nil else { return }
                send(.data(id, chunk))
                hasher.update(data: chunk)
                sent += Int64(chunk.count)
            }
            var done = Control("done", id: id)
            done.sha256 = Data(hasher.finalize()).base64URL
            send(.control(done))
        } catch is CancellationError {
            return
        } catch {
            pathError(id, error)
        }
        downloads[id] = nil
    }

    private func waitForWindow(_ id: UInt32, sent: Int64) async {
        while let d = downloads[id], sent - d.acked >= SessionCrypto.window, !Task.isCancelled {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                downloads[id]?.waiter = cont
            }
        }
    }

    // MARK: Thumbnail

    /// A Quick Look thumbnail as JPEG: `meta`, data, `done`, like a small download.
    /// Files Quick Look can't render get `error { code: "unsupported" }`.
    private func startThumbnail(_ c: Control) {
        let id = c.id
        let url: URL
        do {
            url = try resolve(c.path ?? "")
            guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else {
                return fail(id, "unsupported", "Folders have no preview.")
            }
        } catch {
            return pathError(id, error)
        }
        let px = CGFloat(min(max(c.px ?? 512, 64), 1024))
        Task { [weak self] in
            let jpeg = await Self.thumbnailJPEG(url, px: px)
            await self?.sendThumbnail(id, jpeg)
        }
    }

    private func sendThumbnail(_ id: UInt32, _ jpeg: Data?) {
        guard let jpeg else { return fail(id, "unsupported", "No preview for this file.") }
        var meta = Control("meta", id: id)
        meta.size = Int64(jpeg.count); meta.mime = "image/jpeg"
        send(.control(meta))
        var offset = 0
        while offset < jpeg.count {
            let end = min(offset + SessionCrypto.chunkSize, jpeg.count)
            send(.data(id, jpeg.subdata(in: offset..<end)))
            offset = end
        }
        var done = Control("done", id: id)
        done.sha256 = Data(SHA256.hash(data: jpeg)).base64URL
        send(.control(done))
    }

    static func thumbnailJPEG(_ url: URL, px: CGFloat) async -> Data? {
        #if canImport(QuickLookThumbnailing)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: px, height: px), scale: 1, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, rep.cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
        #else
        return nil
        #endif
    }

    // MARK: Upload

    private func startUpload(_ c: Control) {
        let id = c.id
        guard let name = c.name, !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              FilePaths.visible(name, inTopLevel: false, showHidden: options.showHidden)
        else { return fail(id, "bad_path", "That file name isn't allowed.") }
        do {
            let dir = try resolve(c.dir ?? "")
            guard (try dir.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                return fail(id, "not_found", "That folder no longer exists.")
            }
            let partial = dir.appending(path: ".teleport-\(UUID().uuidString).part")
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                return fail(id, "denied", "Teleport can't write to that folder.")
            }
            let handle = try FileHandle(forWritingTo: partial)
            let final = Self.uniqueName(name, in: dir)
            uploads[id] = Upload(dir: dir, name: final, size: c.size ?? 0, partial: partial, handle: handle)
            var ready = Control("ready", id: id)
            ready.name = final
            send(.control(ready))
        } catch {
            pathError(id, error)
        }
    }

    private func receiveUpload(_ id: UInt32, _ bytes: Data) {
        guard var u = uploads[id] else { return }  // cancelled: drop stragglers
        do {
            try u.handle.write(contentsOf: bytes)
        } catch {
            uploads[id] = nil
            discard(u)
            return pathError(id, error)
        }
        u.hasher.update(data: bytes)
        u.received += Int64(bytes.count)
        if u.received - u.acked >= SessionCrypto.ackEvery {
            var ack = Control("ack", id: id); ack.bytes = u.received
            send(.control(ack))
            u.acked = u.received
        }
        uploads[id] = u
    }

    private func finishUpload(_ c: Control) {
        guard let u = uploads.removeValue(forKey: c.id) else { return }
        try? u.handle.close()
        guard Data(u.hasher.finalize()).base64URL == c.sha256 else {
            discard(u)
            return fail(c.id, "hash", "The upload was corrupted in transit.")
        }
        // Re-check the name: something may have appeared there meanwhile.
        let name = FileManager.default.fileExists(atPath: u.dir.appending(path: u.name).path)
            ? Self.uniqueName(u.name, in: u.dir) : u.name
        do {
            try FileManager.default.moveItem(at: u.partial, to: u.dir.appending(path: name))
            var saved = Control("saved", id: c.id)
            saved.name = name
            send(.control(saved))
        } catch {
            discard(u)
            pathError(c.id, error)
        }
    }

    private func discard(_ u: Upload) {
        try? u.handle.close()
        try? FileManager.default.removeItem(at: u.partial)
    }

    /// `name`, or `name (2).ext`, `name (3).ext`… whichever is free.
    static func uniqueName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appending(path: name).path) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for i in 2... {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !fm.fileExists(atPath: dir.appending(path: candidate).path) { return candidate }
        }
        return name
    }
}

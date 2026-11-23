import Foundation

/// Incoming photos and files on an iPhone, shared by the notification extension (which
/// records them and starts the download), the app (which finishes, decrypts and saves) and
/// the Live Activity widget (which shows names, progress and buttons). One folder per
/// envelope in the App Group: `inbox/<id>/item.json` plus the decrypted file.
public struct InboxItem: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case downloading, ready, failed, cancelled }

    public var id: String
    public var env: String
    public var name: String
    public var mime: String
    public var size: Int
    public var from: String
    public var state: State
    public var progress: Double?
    public var updated: Date

    public init(id: String, env: String, name: String, mime: String, size: Int, from: String, state: State) {
        self.id = id; self.env = env; self.name = name; self.mime = mime; self.size = size; self.from = from
        self.state = state; self.updated = Date()
    }

    public var isMedia: Bool { mime.hasPrefix("image/") || mime.hasPrefix("video/") }
    public var isVideo: Bool { mime.hasPrefix("video/") }
}

public struct Inbox: Sendable {
    let root: URL

    public init(appGroup: String) {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.temporaryDirectory
        root = base.appending(path: "inbox", directoryHint: .isDirectory)
    }

    public func folder(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// Where the decrypted file lives once ready.
    public func file(_ item: InboxItem) -> URL { folder(item.id).appending(path: item.name.replacingOccurrences(of: "/", with: "-")) }

    /// Where a background download leaves the ciphertext before decrypting.
    public func ciphertext(_ id: String) -> URL { folder(id).appending(path: "blob.enc") }

    public func item(_ id: String) -> InboxItem? {
        guard let data = try? Data(contentsOf: folder(id).appending(path: "item.json")) else { return nil }
        return try? JSONDecoder().decode(InboxItem.self, from: data)
    }

    /// The item for an envelope (JSON), if one was recorded.
    public func item(env: String) -> InboxItem? {
        (try? Envelope.parse(env)).flatMap { item($0.id) }
    }

    public func put(_ item: InboxItem) {
        var copy = item
        copy.updated = Date()
        try? FileManager.default.createDirectory(at: folder(item.id), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(copy) {
            try? data.write(to: folder(item.id).appending(path: "item.json"), options: .atomic)
        }
    }

    public func update(_ id: String, _ change: (inout InboxItem) -> Void) {
        guard var item = item(id) else { return }
        change(&item)
        put(item)
    }

    public func remove(_ id: String) { try? FileManager.default.removeItem(at: folder(id)) }

    /// Drops items older than a day (downloads are kept until then for Copy / Save).
    public func prune(olderThan age: TimeInterval = 86_400) {
        let cutoff = Date().addingTimeInterval(-age)
        for dir in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if let item = item(dir.lastPathComponent), item.updated > cutoff { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

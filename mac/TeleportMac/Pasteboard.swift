import AppKit
import TeleportCore
import UniformTypeIdentifiers

/// Reading and writing the Mac clipboard. Unlike iOS, macOS lets an app write the
/// clipboard any time, so received clips land immediately.
enum Pasteboard {
    /// What's on a pasteboard (the clipboard by default, or a Services selection):
    /// an image if there is one, otherwise text.
    static func read(_ pb: NSPasteboard = .general) -> Clip? {
        // A copied image file in Finder: send the file's bytes.
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: url) {
            return portableImage(data, type: type)
        }
        if let data = pb.data(forType: .png) { return .image(data, mime: "image/png") }
        if let data = pb.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) { return .image(data, mime: "image/jpeg") }
        if let string = pb.string(forType: .string), !string.isEmpty { return .text(string) }
        if let url = pb.string(forType: .URL), !url.isEmpty { return .text(url) }
        if let data = pb.data(forType: .tiff) { return portableImage(data, type: .tiff) }
        return nil
    }

    static func write(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch clip {
        case .text(let text):
            pb.setString(text, forType: .string)
            if let url = URL(string: text), url.scheme?.hasPrefix("http") == true, !text.contains(" ") {
                pb.setString(text, forType: .URL)
            }
        case .image(let data, let mime):
            // Native type first, plus an NSImage so every app can paste it.
            let type: NSPasteboard.PasteboardType = mime == "image/png" ? .png : NSPasteboard.PasteboardType(mime == "image/gif" ? UTType.gif.identifier : UTType.jpeg.identifier)
            pb.setData(data, forType: type)
            if let image = NSImage(data: data) { pb.writeObjects([image]) }
        }
    }

    /// Keep PNG/JPEG/GIF; convert anything else (TIFF, HEIC…) to PNG so phones can paste it.
    private static func portableImage(_ data: Data, type: UTType) -> Clip {
        if type.conforms(to: .png) { return .image(data, mime: "image/png") }
        if type.conforms(to: .jpeg) { return .image(data, mime: "image/jpeg") }
        if type.conforms(to: .gif) { return .image(data, mime: "image/gif") }
        if let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            return .image(png, mime: "image/png")
        }
        return .image(data, mime: "image/png")
    }

    /// Saves a received image to ~/Downloads/Teleport and returns its location.
    static func saveToDownloads(_ data: Data, mime: String, from: String) -> URL? {
        let ext = mime == "image/png" ? "png" : (mime == "image/gif" ? "gif" : "jpg")
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let dir = downloads.appending(path: "Teleport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let url = dir.appending(path: "\(from) \(stamp).\(ext)")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}

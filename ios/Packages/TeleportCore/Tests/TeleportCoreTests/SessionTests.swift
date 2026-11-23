import CryptoKit
import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import TeleportCore

// MARK: Vectors (protocol/vectors.json "session")

private struct SessionVectors: Decodable {
    struct KP: Decodable { let d: String; let pub: String }
    struct Frame: Decodable { let dir: UInt32; let counter: UInt64; let plaintext: String; let frame: String }
    struct PathCase: Decodable { let path: String; let hidden: Bool; let ok: String? }
    struct Session: Decodable {
        let mailbox: String
        let mac_ks: KP
        let phone_eph: KP
        let mac_eph: KP
        let hello: SessionCrypto.Hello
        let accept: SessionCrypto.Accept
        let accept_transcript: String
        let k_p2m: String
        let k_m2p: String
        let frames: [Frame]
        let paths: [PathCase]
    }
    let sender_ks: KP
    let session: Session

    static let shared: SessionVectors = {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "protocol/vectors.json")
        return try! JSONDecoder().decode(SessionVectors.self, from: Data(contentsOf: url))
    }()
}

private func b(_ s: String) -> Data { Data(base64URL: s)! }
private let S = SessionVectors.shared.session

@Test func sessionSignaturesVerify() {
    let helloT = SessionCrypto.helloTranscript(mailbox: S.mailbox, S.hello)
    #expect(SessionCrypto.verify(b(S.hello.sig), of: helloT, by: b(SessionVectors.shared.sender_ks.pub)))
    let acceptT = SessionCrypto.acceptTranscript(hello: helloT, epk: S.accept.epk, n: S.accept.n)
    #expect(acceptT.base64URL == S.accept_transcript)
    #expect(SessionCrypto.verify(b(S.accept.sig), of: acceptT, by: b(S.mac_ks.pub)))
    let otherMailbox = SessionCrypto.helloTranscript(mailbox: "otherMailbx", S.hello)
    #expect(!SessionCrypto.verify(b(S.hello.sig), of: otherMailbox, by: b(SessionVectors.shared.sender_ks.pub)))
}

@Test func sessionKeysMatch() throws {
    let acceptT = b(S.accept_transcript)
    let phone = try SessionCrypto.keys(
        ownEphemeral: .init(rawRepresentation: b(S.phone_eph.d)), otherEpk: b(S.accept.epk), acceptTranscript: acceptT)
    let mac = try SessionCrypto.keys(
        ownEphemeral: .init(rawRepresentation: b(S.mac_eph.d)), otherEpk: b(S.hello.epk), acceptTranscript: acceptT)
    #expect(phone.phoneToMac.withUnsafeBytes { Data($0) } == b(S.k_p2m))
    #expect(mac.macToPhone.withUnsafeBytes { Data($0) } == b(S.k_m2p))
}

@Test func sessionFramesMatch() throws {
    for f in S.frames {
        let key = SymmetricKey(data: b(f.dir == 1 ? S.k_p2m : S.k_m2p))
        var sealer = FrameCipher(key: key, dir: f.dir, counter: f.counter)
        #expect(try sealer.seal(b(f.plaintext)) == b(f.frame))
        var opener = FrameCipher(key: key, dir: f.dir, counter: f.counter)
        #expect(try opener.open(b(f.frame)) == b(f.plaintext))
        var wrong = FrameCipher(key: key, dir: f.dir, counter: f.counter + 1)
        #expect(throws: (any Error).self) { try wrong.open(b(f.frame)) }
        _ = try SessionFrame.decode(b(f.plaintext))
    }
}

@Test func pathRulesMatch() {
    for p in S.paths {
        #expect(FilePaths.check(p.path, showHidden: p.hidden) == p.ok, "\(p.path)")
    }
}

// MARK: End to end, in memory

/// Two connected in-memory pipes.
private final class MemoryPipe: SessionPipe, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    let inbox: AsyncThrowingStream<Data, Error>.Continuation
    var peer: MemoryPipe?

    init() { (incoming, inbox) = AsyncThrowingStream<Data, Error>.makeStream() }

    static func pair() -> (MemoryPipe, MemoryPipe) {
        let a = MemoryPipe(), b = MemoryPipe()
        a.peer = b; b.peer = a
        return (a, b)
    }

    func send(_ data: Data) { peer?.inbox.yield(data) }
    func close() { inbox.finish(); peer?.inbox.finish() }
}

private struct Fixture {
    let home: URL
    let phoneKeys = SoftwareSigningKey()
    let macKeys = SoftwareSigningKey()
    let mailbox = "rcAUFPmhXeQ"

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "teleport-home-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appending(path: "Documents/Notes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".ssh"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Library"), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: home.appending(path: ".ssh/id_ed25519"))
        try Data("hello".utf8).write(to: home.appending(path: "Documents/a.txt"))
        try Data(".env".utf8).write(to: home.appending(path: "Documents/.env"))
        try fm.createSymbolicLink(at: home.appending(path: "Documents/escape"), withDestinationURL: URL(filePath: "/etc"))
    }

    func peer(_ key: some SigningKey, platform: Platform) -> Peer {
        try! Peer(card: PairingCard(name: "Test", platform: platform, ka: SoftwareAgreementKey().publicKey, ks: key.publicKey, fcm: nil, la: nil))
    }

    func connect(trusted: Bool = true, showHidden: Bool = false) async throws -> (FileSessionClient, Task<Void, Never>) {
        let (phoneEnd, macEnd) = MemoryPipe.pair()
        let phone = peer(phoneKeys, platform: .ios)
        let phoneID = TeleportCrypto.fingerprint(phoneKeys.publicKey)
        let server = FileServer(
            pipe: macEnd, signer: macKeys, mailbox: mailbox,
            options: .init(home: home, showHidden: showHidden),
            phones: { trusted && $0 == phoneID ? phone : nil })
        let running = Task { await server.run() }
        let client = try await FileSessionClient.handshake(
            pipe: phoneEnd, signer: phoneKeys, mailbox: mailbox, macKs: macKeys.publicKey)
        return (client, running)
    }
}

@Test func listHidesDotfilesLibraryAndEscapes() async throws {
    let f = try Fixture()
    let (client, _) = try await f.connect()
    let top = try await client.list("")
    #expect(top.map(\.name) == ["Documents"])
    let docs = try await client.list("Documents")
    #expect(docs.map(\.name) == ["Notes", "a.txt"])  // folders first; .env and the /etc link hidden
    #expect(docs.first?.dir == true)
    await #expect(throws: FileSessionError.self) { try await client.list(".ssh") }
    await #expect(throws: FileSessionError.self) { try await client.list("Documents/../..") }
    await #expect(throws: FileSessionError.self) { try await client.list("Documents/escape") }
    await client.close()
}

@Test func showHiddenRevealsDotfiles() async throws {
    let f = try Fixture()
    let (client, _) = try await f.connect(showHidden: true)
    let top = try await client.list("")
    #expect(Set(top.map(\.name)) == [".ssh", "Documents", "Library"])
    await client.close()
}

@Test func unknownPhoneIsRefused() async throws {
    let f = try Fixture()
    await #expect(throws: FileSessionError.refused("denied")) { _ = try await f.connect(trusted: false) }
}

@Test func wrongMacKeyIsUntrusted() async throws {
    let f = try Fixture()
    let (phoneEnd, macEnd) = MemoryPipe.pair()
    let phone = f.peer(f.phoneKeys, platform: .ios)
    let server = FileServer(pipe: macEnd, signer: SoftwareSigningKey(), mailbox: f.mailbox,
                            options: .init(home: f.home, showHidden: false), phones: { _ in phone })
    Task { await server.run() }
    await #expect(throws: FileSessionError.untrusted) {
        _ = try await FileSessionClient.handshake(pipe: phoneEnd, signer: f.phoneKeys, mailbox: f.mailbox, macKs: f.macKeys.publicKey)
    }
}

@Test func largeDownloadAndUploadRoundTrip() async throws {
    let f = try Fixture()
    // 5 MiB + a bit: several windows and a short last chunk.
    let big = Data((0..<(5 * 1024 * 1024 + 12345)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try big.write(to: f.home.appending(path: "Documents/big.bin"))
    let (client, _) = try await f.connect()

    let out = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString).bin")
    let seen = Counter()
    try await client.download("Documents/big.bin", to: out) { done, _ in seen.set(done) }
    #expect(try Data(contentsOf: out) == big)
    #expect(seen.value == Int64(big.count))

    // Uploading the same name twice keeps both.
    let first = try await client.upload(out, to: "Documents/Notes", name: "copy.bin") { _, _ in }
    let second = try await client.upload(out, to: "Documents/Notes", name: "copy.bin") { _, _ in }
    #expect(first == "copy.bin")
    #expect(second == "copy (2).bin")
    #expect(try Data(contentsOf: f.home.appending(path: "Documents/Notes/copy (2).bin")) == big)
    // No partial files left behind.
    let notes = try FileManager.default.contentsOfDirectory(atPath: f.home.appending(path: "Documents/Notes").path)
    #expect(Set(notes) == ["copy.bin", "copy (2).bin"])
    await client.close()
}

@Test func uploadRejectsBadNames() async throws {
    let f = try Fixture()
    let src = f.home.appending(path: "Documents/a.txt")
    let (client, _) = try await f.connect()
    await #expect(throws: FileSessionError.self) { _ = try await client.upload(src, to: "Documents", name: "../x") }
    await #expect(throws: FileSessionError.self) { _ = try await client.upload(src, to: "Documents", name: ".bashrc") }
    await #expect(throws: FileSessionError.self) { _ = try await client.upload(src, to: ".ssh", name: "x") }
    await client.close()
}

@Test func cancelledDownloadLeavesNothing() async throws {
    let f = try Fixture()
    try Data(count: 8 * 1024 * 1024).write(to: f.home.appending(path: "Documents/zero.bin"))
    let (client, _) = try await f.connect()
    let dir = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let task = Task {
        try await client.download("Documents/zero.bin", to: dir.appending(path: "zero.bin")) { done, _ in
            if done > 1024 * 1024 { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    // The session still works afterwards.
    #expect(try await client.list("Documents").contains { $0.name == "zero.bin" })
    await client.close()
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int64 = 0
    var value: Int64 { lock.withLock { v } }
    func set(_ x: Int64) { lock.withLock { v = x } }
}

@Test func thumbnailOfAnImage() async throws {
    let f = try Fixture()
    // A 64×48 PNG drawn with ImageIO.
    let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let png = NSMutableData()
    let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    try (png as Data).write(to: f.home.appending(path: "Documents/pic.png"))

    let (client, _) = try await f.connect()
    let thumb = try #require(try await client.thumbnail("Documents/pic.png", px: 128))
    #expect(thumb.prefix(2) == Data([0xFF, 0xD8]))  // JPEG
    // Folders and hidden files: no thumbnail / refused.
    #expect(try await client.thumbnail("Documents") == nil)
    await #expect(throws: FileSessionError.self) { _ = try await client.thumbnail(".ssh/id_ed25519") }
    await client.close()
}

@Test func rangeReadsForStreaming() async throws {
    let f = try Fixture()
    let data = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    try data.write(to: f.home.appending(path: "Documents/video.mp4"))
    let (client, _) = try await f.connect()
    #expect(try await client.read("Documents/video.mp4", offset: 1000, length: 5000) == data[1000..<6000])
    // Capped at 2 MiB per read; reading past the end returns what's there.
    #expect(try await client.read("Documents/video.mp4", offset: 0, length: 9_000_000).count == 2 * 1024 * 1024)
    #expect(try await client.read("Documents/video.mp4", offset: Int64(data.count - 10), length: 100) == data.suffix(10))
    await client.close()
}

@Test func interruptedDownloadResumes() async throws {
    let f = try Fixture()
    let big = Data((0..<(6 * 1024 * 1024 + 99)).map { UInt8(truncatingIfNeeded: $0 &* 17) })
    try big.write(to: f.home.appending(path: "Documents/big.bin"))
    let dest = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString).bin")

    // First attempt: the connection drops part-way (we close the session at ~2 MiB).
    let (first, _) = try await f.connect()
    await #expect(throws: FileSessionError.self) {
        try await first.download("Documents/big.bin", to: dest) { done, _ in
            if done > 2 * 1024 * 1024 { Task { await first.close() } }
        }
    }
    let kept = (try? FileManager.default.attributesOfItem(atPath: FileSessionClient.partialURL(for: dest).path)[.size] as? Int) ?? 0
    #expect(kept > 0)

    // Second attempt on a new session picks up from there and verifies the whole file.
    let (second, _) = try await f.connect()
    let firstByte = Counter()
    try await second.download("Documents/big.bin", to: dest) { done, _ in if firstByte.value == 0 { firstByte.set(done) } }
    #expect(firstByte.value >= Int64(kept))  // didn't start from zero
    #expect(try Data(contentsOf: dest) == big)
    await second.close()
}

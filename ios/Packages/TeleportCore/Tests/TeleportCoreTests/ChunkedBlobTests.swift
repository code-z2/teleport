import CryptoKit
import Foundation
import Testing
@testable import TeleportCore

/// protocol/vectors.json "chunked" (SPEC.md "Large blobs").
private struct ChunkedVectors: Decodable {
    struct Case: Decodable { let name: String; let plaintext: String; let ciphertext: String }
    struct Chunked: Decodable { let key: String; let n: String; let c: Int; let cases: [Case] }
    let chunked: Chunked

    static let shared: ChunkedVectors = {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "protocol/vectors.json")
        return try! JSONDecoder().decode(ChunkedVectors.self, from: Data(contentsOf: url))
    }()
}

private let C = ChunkedVectors.shared.chunked
private func b(_ s: String) -> Data { Data(base64URL: s)! }

@Test func chunkedSealMatchesAndOpens() throws {
    let key = SymmetricKey(data: b(C.key))
    for v in C.cases {
        let plain = b(v.plaintext)
        #expect(try ChunkedBlob.seal(plain, key: key, n: b(C.n), chunk: C.c) == b(v.ciphertext), "\(v.name)")
        #expect(try ChunkedBlob.open(b(v.ciphertext), size: plain.count, key: key, n: b(C.n), chunk: C.c) == plain, "\(v.name)")
    }
}

@Test func chunkedRejectsTruncationReorderingAndWrongSize() {
    let key = SymmetricKey(data: b(C.key))
    let ct = b(C.cases[0].ciphertext)  // 25 bytes in chunks of 10: 26 + 26 + 21
    #expect(throws: (any Error).self) { try ChunkedBlob.open(ct.prefix(52), size: 20, key: key, n: b(C.n), chunk: C.c) }
    let swapped = ct[26..<52] + ct[0..<26] + ct[52...]
    #expect(throws: (any Error).self) { try ChunkedBlob.open(Data(swapped), size: 25, key: key, n: b(C.n), chunk: C.c) }
    #expect(throws: (any Error).self) { try ChunkedBlob.open(ct, size: 24, key: key, n: b(C.n), chunk: C.c) }
}

@Test func chunkedRoundTripsAtRealChunkSize() throws {
    let key = SymmetricKey(size: .bits256)
    let n = Data.random(12)
    let plain = Data((0..<(9 * 1024 * 1024 + 7)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
    let ct = try ChunkedBlob.seal(plain, key: key, n: n)
    #expect(ct.count == plain.count + 16 * 3)
    #expect(try ChunkedBlob.open(ct, size: plain.count, key: key, n: n) == plain)
}

@Test func pointerKeepsOptionalFields() throws {
    let small = try JSONDecoder().decode(BlobPointer.self, from: Data(#"{"id":"a","mime":"image/png","size":3,"key":"k","n":"n"}"#.utf8))
    #expect(!small.isChunked)
    let big = BlobPointer(id: "a", mime: "video/mp4", size: 9, key: "k", n: "n", c: 4_194_304, name: "Clip.mp4")
    let json = String(decoding: try JSONEncoder().encode(big), as: UTF8.self)
    #expect(json.contains(#""c":4194304"#) && json.contains("Clip.mp4"))
}

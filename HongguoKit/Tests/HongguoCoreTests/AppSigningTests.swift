// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Byte-for-byte parity with the Electron reference implementations.
/// * `Fixtures/app-signing-vectors.json` comes from `scripts/gen-signing-vectors.cjs` (node, fixed
///   time and randomness, synthetic ids).
/// * `Fixtures/playback-v5-vectors` are the unmodified upstream hongguoTV vectors (copied from
///   `src/native/fixtures/playback-v5-vectors` of the Electron tree, which is no longer in this repository).
final class AppSigningTests: XCTestCase {
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    func json(_ url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    var vectors: [String: Any] {
        get throws { try json(Self.testsDir.appendingPathComponent("Fixtures/app-signing-vectors.json")) as! [String: Any] }
    }

    func hex(_ s: Any?) -> [UInt8] { AppCrypto.fromHex(s as! String)! }

    func testSM3() throws {
        for row in try vectors["sm3"] as! [[String: String]] {
            XCTAssertEqual(AppCrypto.hex(AppCrypto.sm3(hex(row["input"]))), row["digest"])
        }
    }

    func testUpstreamF13Vectors() throws {
        let url = Self.testsDir.appendingPathComponent("Fixtures/playback-v5-vectors/signing-v5-f13.json")
        let rows = try json(url) as! [[String: Any]]
        XCTAssertEqual(rows.count, 32)
        for (i, row) in rows.enumerated() {
            let ts = UInt32((row["ts"] as! NSNumber).uint32Value)
            let out = try PlaybackSignerV5.hashF13(query: hex(row["query"]), body: hex(row["body"]), ts: ts)
            XCTAssertEqual(out.count, 20)
            XCTAssertEqual(AppCrypto.hex(Array(out[0..<16])), row["digest"] as? String, "f13 class \(i)")
        }
    }

    func testUpstreamCarrierVectors() throws {
        let url = Self.testsDir.appendingPathComponent("Fixtures/playback-v5-vectors/signing-v5-carrier.json")
        let rows = try json(url) as! [[String: Any]]
        XCTAssertEqual(rows.count, 4)
        for (i, row) in rows.enumerated() {
            let ts = UInt32((row["ts"] as! NSNumber).uint32Value)
            let carrier = PlaybackSignerV5.Carrier(key: hex(row["key"]), ts: ts)
            let out = try carrier.encrypt(hex(row["source"]), iv: hex(row["iv"]))
            XCTAssertEqual(AppCrypto.hex(out), row["encrypted"] as? String, "carrier \(i)")
        }
    }

    func testPlaybackV5MatchesNode() throws {
        for (i, row) in (try vectors["v5"] as! [[String: Any]]).enumerated() {
            var randoms = (row["random32"] as! [NSNumber]).map { $0.uint32Value }
            let signer = PlaybackSignerV5(processNonce: row["processNonce"] as! String,
                                          processStarted: (row["processStarted"] as! NSNumber).int64Value,
                                          random32: { randoms.removeFirst() })
            let values = (row["values"] as! [[String]]).map { ($0[0], $0[1]) }
            let signed = try signer.sign(base: "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/player/v1",
                                         values: values, body: hex(row["body"]), nowMillis: (row["now"] as! NSNumber).int64Value)
            XCTAssertEqual(signed.url, row["url"] as? String, "v5 url \(i)")
            XCTAssertEqual(URL(string: signed.url)?.query(percentEncoded: true), signed.query, "query bytes survive URL \(i)")
            let expected = row["headers"] as! [String: String]
            XCTAssertEqual(Dictionary(signed.headers, uniquingKeysWith: { a, _ in a }), expected, "v5 headers \(i)")
            XCTAssertTrue(randoms.isEmpty)
        }
    }

    func testContentKeyAndSpadeURL() throws {
        let v = try vectors
        for row in v["contentKeys"] as! [[String: String]] {
            XCTAssertEqual(try AppCrypto.hex(AppSource.deriveContentKey(row["spade"]!)), row["key"])
        }
        XCTAssertThrowsError(try AppSource.deriveContentKey("AAAA"))
        for row in v["spadeUrls"] as! [[String: String]] {
            let seed = AppCrypto.base64Decode(row["seed"]!)
            XCTAssertEqual(try AppSource.decryptSpadeURL(row["cipher"]!, seed: seed), row["url"])
        }
    }

    func testGzipRoundTrip() throws {
        let payload = Array(#"{"mixed_video_id_map":{"1004":["7000000000000000001"]},"dr_scene":"player"}"#.utf8)
        let gz = try AppCrypto.gzip(payload)
        XCTAssertEqual(Array(gz[0..<3]), [0x1f, 0x8b, 8])
        XCTAssertEqual(try AppCrypto.gunzip(gz), payload)
        #if os(macOS)
        // System gunzip must accept it too (the server decompresses this body).
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hg-\(UUID().uuidString).gz")
        try Data(gz).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(Array(out), payload)
        #endif
    }

    func testCheckedURL() {
        let media = AppSource.mediaDomains
        XCTAssertNotNil(try? AppSource.checkedURL("https://v3-reading-video.qznovelvod.com/a.mp4", domains: media))
        XCTAssertNotNil(try? AppSource.checkedURL("https://x.douyinvod.com:443/a.mp4", domains: media))
        for bad in ["http://v3-reading-video.qznovelvod.com/a.mp4", "https://qznovelvod.com.evil.test/a.mp4",
                    "https://u:p@v.qznovelvod.com/a.mp4", "https://v.qznovelvod.com:8443/a.mp4", "https://evilqznovelvod.com/a.mp4",
                    "not a url"] {
            XCTAssertThrowsError(try AppSource.checkedURL(bad, domains: media), bad)
        }
    }
}

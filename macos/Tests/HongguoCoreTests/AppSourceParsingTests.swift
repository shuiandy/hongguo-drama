// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

final class AppSourceParsingTests: XCTestCase {
    // Key material produced by scripts/gen-signing-vectors.cjs (encodedKey of 00112233…eeff).
    let spade = "kLMT9VuyEvtZshL5X7UR+0G2DvlfqSbQXakm0luuJdClrA=="

    func model(_ list: [String: Any], extra: [String: Any] = [:]) throws -> JSONValue {
        var object: [String: Any] = ["video_list": list, "video_id": "v01", "video_duration": 60.5]
        object.merge(extra) { $1 }
        return JSONValue(any: object)
    }

    func row(_ codec: String, _ w: Int, _ h: Int, url: String, spade: String? = nil, encrypt: Any? = nil) -> [String: Any] {
        var item: [String: Any] = ["codec_type": codec, "vwidth": w, "vheight": h, "main_url": url]
        if let spade { item["spade_a"] = spade }
        if let encrypt { item["encrypt"] = encrypt }
        return item
    }

    func testPrefersH264AtBestTierAndDerivesKey() throws {
        let info = try model([
            "video_1": row("bytevc2", 1080, 1920, url: "https://a.qznovelvod.com/b2.mp4", spade: spade),
            "video_2": row("hevc", 1080, 1920, url: "https://a.qznovelvod.com/hevc.mp4", spade: spade),
            "video_3": row("h264", 1080, 1920, url: "https://a.qznovelvod.com/h264.mp4", spade: spade),
            "video_4": row("h264", 720, 1280, url: "https://a.qznovelvod.com/h264-720.mp4", spade: spade),
        ])
        let play = try AppSource.parsePlayModel(info, vid: "1", inline: true)
        XCTAssertEqual(play.url.lastPathComponent, "h264.mp4")
        XCTAssertEqual(play.source, .app)
        XCTAssertEqual(play.codec, "h264")
        XCTAssertEqual(play.contentKey.map { AppCrypto.hex($0) }, "00112233445566778899aabbccddeeff")
        XCTAssertTrue(play.isEncrypted)
        XCTAssertEqual(play.userAgent, AppSource.playbackUA)
    }

    func testFallsBackToHEVCAndNormalisesByteVC1() throws {
        let info = try model([
            "video_1": row("bytevc1", 1080, 1920, url: "https:\\/\\/a.fqnovelvod.com\\/x.mp4?a=1\\u0026b=2", encrypt: false),
            "video_2": row("h264", 540, 960, url: "https://a.qznovelvod.com/low.mp4", encrypt: false),
        ])
        // HEVC wins only because H.264 is ranked first globally; here H.264 exists, so it is chosen.
        XCTAssertEqual(try AppSource.parsePlayModel(info, vid: "1", inline: true).url.lastPathComponent, "low.mp4")
        let hevcOnly = try model(["video_1": row("bytevc1", 1080, 1920, url: "https:\\/\\/a.fqnovelvod.com\\/x.mp4?a=1\\u0026b=2", encrypt: 0)])
        let play = try AppSource.parsePlayModel(hevcOnly, vid: "1", inline: true)
        XCTAssertEqual(play.codec, "hevc")
        XCTAssertEqual(play.url.absoluteString, "https://a.fqnovelvod.com/x.mp4?a=1&b=2")
        XCTAssertFalse(play.isEncrypted)
    }

    func testByteVC2OnlyIsReported() throws {
        let info = try model(["video_1": row("bytevc2", 1080, 1920, url: "https://a.qznovelvod.com/b2.mp4", spade: spade)])
        XCTAssertThrowsError(try AppSource.parsePlayModel(info, vid: "1", inline: true)) { error in
            XCTAssertEqual((error as? AppSourceError)?.code, .noCompatibleSource)
            XCTAssertTrue((error as? AppSourceError)?.message.contains("ByteVC2") == true)
        }
    }

    func testInlineWithoutEncryptionMetadataFlagsRecovery() throws {
        let info = try model(["video_1": row("h264", 720, 1280, url: "https://a.qznovelvod.com/a.mp4")])
        XCTAssertThrowsError(try AppSource.parsePlayModel(info, vid: "1", inline: true)) { error in
            let e = error as? AppSourceError
            XCTAssertEqual(e?.incompleteEncryptionMetadata, true)
            XCTAssertEqual(e?.minimumPixels, 720)
        }
        // The non-inline (fallback) model does not require the metadata.
        XCTAssertNoThrow(try AppSource.parsePlayModel(info, vid: "1", inline: false))
    }

    func testRejectsUnlistedMediaHosts() throws {
        let info = try model(["video_1": row("h264", 720, 1280, url: "https://evil.example.com/a.mp4", encrypt: false)])
        XCTAssertThrowsError(try AppSource.parsePlayModel(info, vid: "1", inline: true)) { error in
            XCTAssertEqual((error as? AppSourceError)?.code, .securityBlocked)
        }
    }

    func testParseFallback() {
        XCTAssertEqual(AppSource.parseFallback(.string(#"{"fallback_api":"https://vod.snssdk.com/info"}"#)), "https://vod.snssdk.com/info")
        XCTAssertEqual(AppSource.parseFallback(.string("https://vod.snssdk.com/x")), "https://vod.snssdk.com/x")
        XCTAssertEqual(AppSource.parseFallback(.array([.string(" https://vod.snssdk.com/y ")])), "https://vod.snssdk.com/y")
        XCTAssertNil(AppSource.parseFallback(.null))
    }

    func testRegistrationIdParsing() {
        let r = JSONValue(any: ["device_id": 123, "device_id_str": "7000000000000000001", "install_id_str": "", "install_id": "0"])
        XCTAssertEqual(PlaybackDevice.responseId(r, "device_id"), "7000000000000000001")
        XCTAssertEqual(PlaybackDevice.responseId(r, "install_id"), "")
    }
}

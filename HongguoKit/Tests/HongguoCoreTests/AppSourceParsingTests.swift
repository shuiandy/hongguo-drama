// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

final class AppSourceParsingTests: XCTestCase {
    // Key material produced by scripts/gen-signing-vectors.cjs (encodedKey of 00112233…eeff).
    let spade = "kLMT9VuyEvtZshL5X7UR+0G2DvlfqSbQXakm0luuJdClrA=="

    #if os(macOS)
    // These cases describe a Mac without the ByteVC2 helper, whatever is installed on the build machine.
    override func setUp() { ByteVC2Converter.setExecutableForTesting(nil) }
    override func tearDown() { ByteVC2Converter.setExecutableForTesting(nil) }

    func testByteVC2IsUsedLastWhenTheHelperExists() throws {
        ByteVC2Converter.setExecutableForTesting(URL(fileURLWithPath: "/usr/bin/true"))
        ByteVC2Converter.configure(enabled: true, fast: false)
        let only = try model(["video_1": row("bytevc2", 1080, 1920, url: "https://a.qznovelvod.com/b2.mp4", spade: spade)])
        let play = try AppSource.parsePlayModel(only, vid: "1", inline: true)
        XCTAssertTrue(play.isByteVC2)
        XCTAssertTrue(play.needsLocalFile)
        // H.264 at the same tier still wins.
        let mixed = try model(["video_1": row("bytevc2", 1080, 1920, url: "https://a.qznovelvod.com/b2.mp4", spade: spade),
                               "video_2": row("h264", 1080, 1920, url: "https://a.qznovelvod.com/a.mp4", spade: spade)])
        XCTAssertEqual(try AppSource.parsePlayModel(mixed, vid: "1", inline: true).codec, "h264")
        // Turned off in settings: reported again.
        ByteVC2Converter.configure(enabled: false, fast: false)
        XCTAssertThrowsError(try AppSource.parsePlayModel(only, vid: "1", inline: true))
        ByteVC2Converter.configure(enabled: true, fast: false)
    }

    #endif

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
        XCTAssertEqual(play.userAgent, AppSource.iosPlayerUA)
    }

    func testOffersOtherTiersAsVariants() throws {
        let info = try model([
            "video_1": row("h264", 1080, 1920, url: "https://a.qznovelvod.com/h264-1080.mp4", spade: spade),
            "video_2": row("hevc", 720, 1280, url: "https://a.qznovelvod.com/hevc-720.mp4", spade: spade),
            "video_3": row("h264", 720, 1280, url: "https://a.qznovelvod.com/h264-720.mp4", spade: spade),
            "video_4": row("h264", 480, 854, url: "https://a.qznovelvod.com/h264-480.mp4", spade: spade),
            "video_5": row("bytevc2", 1440, 2560, url: "https://a.qznovelvod.com/b2.mp4", spade: spade),
        ])
        let play = try AppSource.parsePlayModel(info, vid: "1", inline: true)
        XCTAssertEqual(play.url.lastPathComponent, "h264-1080.mp4")
        XCTAssertEqual(play.quality?.label, "1080P")
        XCTAssertEqual(play.qualityOptions.map(\.shortSide), [1080, 720, 480])
        XCTAssertEqual(play.variants.map(\.url.lastPathComponent), ["h264-720.mp4", "h264-480.mp4"], "H.264 preferred within a tier")
        XCTAssertTrue(play.variants.allSatisfy { $0.contentKey == play.contentKey })

        let low = play.selecting(shortSide: 720)
        XCTAssertEqual(low.url.lastPathComponent, "h264-720.mp4")
        XCTAssertEqual(low.qualityOptions.map(\.shortSide), [1080, 720, 480], "switching keeps every tier available")
        XCTAssertEqual(play.selecting(shortSide: 600).quality?.shortSide, 480, "best tier at or below the preference")
        XCTAssertEqual(play.selecting(shortSide: 240).quality?.shortSide, 480, "lowest tier when nothing is small enough")
        XCTAssertEqual(low.selecting(shortSide: 1080).url.lastPathComponent, "h264-1080.mp4")
        XCTAssertEqual(play.selecting(shortSide: nil), play)
        XCTAssertEqual(QualityOption(shortSide: 2160).label, "4K")
    }

    func testFallsBackToHEVCAndNormalisesByteVC1() throws {
        let info = try model([
            "video_1": row("bytevc1", 1080, 1920, url: "https:\\/\\/a.fqnovelvod.com\\/x.mp4?a=1\\u0026b=2", encrypt: false),
            "video_2": row("h264", 540, 960, url: "https://a.qznovelvod.com/low.mp4", encrypt: false),
        ])
        // Higher resolution hardware-decodable stream (1080p HEVC) beats lower resolution H.264 (540p).
        XCTAssertEqual(try AppSource.parsePlayModel(info, vid: "1", inline: true).url.lastPathComponent, "x.mp4")
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
        XCTAssertEqual(PersistentAppDevice.responseId(r, "device_id"), "7000000000000000001")
        XCTAssertEqual(PersistentAppDevice.responseId(r, "install_id"), "")
    }

    /// The one play request: the official iOS 7.4.3 profile on every app.
    func testModelRequestUsesTheOfficialIOSProfile() throws {
        let identity = PlaybackIdentity(deviceId: "7000000000000000001", iid: "7000000000000000002", cdid: "c")
        let request = try AppSource.modelRequest(base: AppSource.playerSceneAPI,
                                                 payload: try AppSource.modelPayload(vids: ["7000000000000000003"]),
                                                 identity: identity)
        let query = Dictionary(URLComponents(string: request.url)!.queryItems!.map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(request.url.hasPrefix(AppSource.playerSceneAPI))
        XCTAssertEqual(query["device_platform"], "iphone")
        XCTAssertEqual(query["version_code"], "74300")
        XCTAssertEqual(query["channel"], "App Store")
        XCTAssertEqual(query["device_id"], "7000000000000000001")
        let headers = Dictionary(request.headers, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(headers["User-Agent"], AppSource.iosPlayerUA)
        XCTAssertEqual(headers["x-ss-dp"], "8662")
        XCTAssertEqual(headers["Content-Encoding"], "gzip")
        let payload = try JSONValue.parse(Data(try AppSource.modelPayload(vids: ["1"])))
        XCTAssertEqual(payload["dr_scene"].string, "player")
        XCTAssertEqual(payload["biz_param"]["device_level"].number, 1)
        XCTAssertEqual(payload["mixed_video_id_map"]["1004"].array?.count, 1)
    }

    func testParseSeriesRecommendPrefersDetailCellAndFallsBack() throws {
        let withDetailCell = try JSONValue.parse("""
        {
          "code": 0,
          "session_id": "top-sess",
          "data": [
            {
              "show_type": 401,
              "cell_name": "更多好剧",
              "video_data": [
                {"series_id": "7000000000000000010", "title": "泛推荐剧", "episode_cnt": 50}
              ]
            },
            {
              "show_type": 160,
              "cell_name": "猜你喜欢",
              "session_id": "cell-sess",
              "video_data": [
                {"series_id": "7000000000000000001", "title": "当前剧本身", "episode_cnt": 60},
                {"series_id": "7000000000000000002", "title": "相关剧A", "episode_cnt": 80, "sub_title_list": [{"data_type": 27, "content": "3200万热度"}]},
                {"series_id": "7000000000000000002", "title": "相关剧A重复", "episode_cnt": 80}
              ]
            }
          ]
        }
        """)
        let rec = try DiscoveryAccess.parseSeriesRecommend(withDetailCell, excludingSeriesId: "7000000000000000001")
        XCTAssertEqual(rec.cellTitle, "猜你喜欢")
        XCTAssertEqual(rec.sessionId, "cell-sess")
        XCTAssertEqual(rec.items.map(\.seriesId), ["7000000000000000002"])
        XCTAssertEqual(rec.items.first?.heatText, "3200万热度")
        XCTAssertEqual(rec.items.first?.subtitle, "3200万热度 · 全80集")

        let fallbackOnly = try JSONValue.parse("""
        {
          "code": 0,
          "data": [
            {
              "show_type": 401,
              "cell_name": "更多好剧",
              "cell_data": [
                {"video_detail": {"series_id": "7000000000000000099", "series_title": "备用剧", "episode_cnt": 45}}
              ]
            }
          ]
        }
        """)
        let fb = try DiscoveryAccess.parseSeriesRecommend(fallbackOnly)
        XCTAssertEqual(fb.cellTitle, "更多好剧")
        XCTAssertEqual(fb.items.map(\.seriesId), ["7000000000000000099"])
    }

    func testParseSearchCuesDeduplicatesAndChecksCode() throws {
        let payload = try JSONValue.parse("""
        {
          "code": 0,
          "data_v1": [
            {"text": "家里家外"},
            {"text": " 家里家外 "},
            {"text": ""},
            {"text": "好一个乖乖女"}
          ]
        }
        """)
        XCTAssertEqual(try DiscoveryAccess.parseSearchCues(payload), ["家里家外", "好一个乖乖女"])
        XCTAssertThrowsError(try DiscoveryAccess.parseSearchCues(try JSONValue.parse(#"{"code":100001}"#)))
    }

    func testEmptyKeySeedDoesNotBreakPlainURL() throws {
        let info = try model(
            ["video_1": row("hevc", 1080, 1920, url: "https://a.fqnovelvod.com/plain.mp4", encrypt: false)],
            extra: ["key_seed": ""]
        )
        let play = try AppSource.parsePlayModel(info, vid: "1", inline: true)
        XCTAssertEqual(play.url.absoluteString, "https://a.fqnovelvod.com/plain.mp4")
        XCTAssertEqual(play.codec, "hevc")
    }
}

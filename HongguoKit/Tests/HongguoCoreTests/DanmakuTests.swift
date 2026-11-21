// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `Fixtures/danmaku-signing-vectors.json` comes from `scripts/gen-danmaku-vectors.cjs`, which runs
/// the Electron reference (src/native/danmaku-sign.js and danmaku.js) with fixed inputs.
final class DanmakuSigningTests: XCTestCase {
    static let fixture: JSONValue = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/danmaku-signing-vectors.json")
        return try! JSONValue.parse(Data(contentsOf: url))
    }()

    func testQueryAndHeadersMatchReference() throws {
        let cases = try XCTUnwrap(Self.fixture["cases"].array)
        XCTAssertEqual(cases.count, 3)
        for item in cases {
            let stampMs = try XCTUnwrap(item["stampMs"].number).toInt64
            // The vectors were made on the 7.3.5.32 query with Argus app version 6.8.1.32.
            let query = DanmakuSigner.buildQuery(stampMs: stampMs, deviceId: item["deviceId"].string!, installId: item["installId"].string!,
                                                 version: .init(code: "73532", name: "7.3.5.32"))
            XCTAssertEqual(query, item["rawQuery"].string)
            let headers = try DanmakuSigner.headers(rawQuery: query, stamp: stampMs / 1000, nonce: AppCrypto.fromHex(item["nonce"].string!)!,
                                                    argusVersion: "6.8.1.32")
            let expected = try XCTUnwrap(item["headers"].object)
            XCTAssertEqual(headers.map(\.0), ["X-Gorgon", "X-Khronos", "X-SS-Req-Ticket", "X-SS-STUB", "X-Argus", "X-Ladon"])
            for (name, value) in headers {
                XCTAssertEqual(value, expected[name]?.string, "\(name) for stamp \(stampMs)")
            }
        }
    }

    func testVarint() throws {
        for row in try XCTUnwrap(Self.fixture["uvarint"].array) {
            XCTAssertEqual(AppCrypto.hex(DanmakuSigner.uvarint(UInt64(row["value"].number!))), row["hex"].string)
        }
    }

    func testQuotePlusEscapesLikePython() {
        XCTAssertEqual(DanmakuSigner.quotePlus("1280*2772"), "1280%2A2772")
        XCTAssertEqual(DanmakuSigner.quotePlus("a b~c-d_e.f!"), "a+b~c-d_e.f%21")
        XCTAssertEqual(DanmakuSigner.quotePlus("红"), "%E7%BA%A2")
    }

    func testRejectsWrongNonceLength() {
        XCTAssertThrowsError(try DanmakuSigner.headers(rawQuery: "a=1", stamp: 1, nonce: [1, 2, 3]))
    }
}

final class DanmakuParsingTests: XCTestCase {
    var fixture: JSONValue { DanmakuSigningTests.fixture }

    func testParsePageMatchesReference() throws {
        let vid = fixture["vid"].string!
        for (i, row) in try XCTUnwrap(fixture["parse"].array).enumerated() {
            let page = DanmakuService.parsePage(row["payload"], vid: vid)
            let expected = row["expected"]
            XCTAssertEqual(page.items.map(\.text), expected["items"].array!.map { $0["text"].string! }, "case \(i)")
            XCTAssertEqual(page.items.map(\.color), expected["items"].array!.map { $0["color"].string! }, "case \(i)")
            XCTAssertEqual(page.items.map(\.mode.rawValue), expected["items"].array!.map { $0["mode"].string! }, "case \(i)")
            XCTAssertEqual(page.items.map(\.timeRaw), expected["items"].array!.map { $0["timeRaw"] }, "case \(i)")
            XCTAssertEqual(page.nextMs, expected["nextMs"].number.map { Int64($0) }, "case \(i)")
            XCTAssertEqual(page.hasMore, expected["hasMore"].bool, "case \(i)")
        }
    }

    func testNormalizersMatchReference() throws {
        for row in try XCTUnwrap(fixture["colors"].array) {
            XCTAssertEqual(DanmakuService.normalizeColor(row["input"]), row["expected"].string, "\(row["input"])")
        }
        for row in try XCTUnwrap(fixture["seconds"].array) {
            XCTAssertEqual(DanmakuService.toSeconds(row["input"]), row["expected"].number, "\(row["input"])")
        }
        for row in try XCTUnwrap(fixture["clean"].array) {
            XCTAssertEqual(DanmakuService.cleanControl(row["input"].string!), row["expected"].string)
        }
        for row in try XCTUnwrap(fixture["modes"].array) {
            XCTAssertEqual(DanmakuService.normalizeMode(row["input"].array!).rawValue, row["expected"].string)
        }
    }

    // MARK: fetch with a scripted transport

    final class ScriptedTransport: DanmakuTransport, @unchecked Sendable {
        var responses: [Result<String, Error>]
        private(set) var bodies: [[String: Any]] = []
        private(set) var urls: [URL] = []
        private(set) var headerSets: [[String: String]] = []
        let lock = NSLock()
        init(_ responses: [Result<String, Error>]) { self.responses = responses }
        func post(url: URL, body: Data, headers: [(String, String)], timeout: TimeInterval) async throws -> Data {
            let next: Result<String, Error> = lock.withLock {
                urls.append(url)
                bodies.append(try! JSONSerialization.jsonObject(with: body) as! [String: Any])
                headerSets.append(Dictionary(headers, uniquingKeysWith: { $1 }))
                return responses.isEmpty ? .failure(HongguoError(.network, "no more")) : responses.removeFirst()
            }
            return Data(try next.get().utf8)
        }
    }

    static let vid = "7300000000000000001"
    static let series = "7200000000000000002"

    static func page(_ rows: [(Int, String)], next: Int? = nil, hasMore: Bool? = nil) -> String {
        let list = rows.map { #"{"comment":{"common":{"group_id":"\#(vid)","status":1,"content":{"text":"\#($0.1)"}},"expand":{"offset_time":\#($0.0)}}}"# }
        var data = #""data_list":[\#(list.joined(separator: ","))]"#
        if let next { data += #","extra":{"next_query_danmaku_list_time":"\#(next)"}"# }
        if let hasMore { data += #","common_list_info":{"has_more":\#(hasMore)}"# }
        return #"{"code":0,"data":{\#(data)}}"#
    }

    func service(_ transport: ScriptedTransport) -> DanmakuService {
        DanmakuService(transport: transport,
                       identity: DanmakuIdentity(deviceId: "1234567890123456789", installId: "2234567890123456789"),
                       now: { Date(timeIntervalSince1970: 1_763_430_000.123) },
                       nonce: { Array(1...11) }, pageGap: .zero)
    }

    func testPagesUntilNoNextCursorAndSorts() async throws {
        let transport = ScriptedTransport([
            .success(Self.page([(9000, "后"), (1000, "前")], next: 60000)),
            .success(Self.page([(61000, "第二页"), (1000, "前")], hasMore: false)),
        ])
        let result = await service(transport).fetch(seriesId: Self.series, vid: Self.vid)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.items.map(\.text), ["前", "后", "第二页"])
        XCTAssertEqual(result.items.map(\.time), [1, 9, 61])
        XCTAssertEqual(result.notice, "")
        XCTAssertEqual(transport.urls.count, 2)
        let business = transport.bodies[1]["business_param"] as! [String: Any]
        XCTAssertEqual(business["start_offset_time"] as? Int, 60000)
        XCTAssertEqual(business["book_id"] as? String, Self.series)
        XCTAssertEqual(transport.bodies[0]["group_id"] as? String, Self.vid)
        XCTAssertTrue(transport.urls[0].absoluteString.contains("/comment/list/\(Self.vid)/v1/?_rticket=1763430000123&"))
        XCTAssertEqual(transport.headerSets[0]["X-Khronos"], "1763430000")
        XCTAssertNotNil(transport.headerSets[0]["X-Argus"])
    }

    func testFirstPageHTTPFailureIsReportedNotEmpty() async {
        let response = HTTPResponse(data: Data(), status: 403, headers: [:], url: URL(string: "https://example.com")!)
        let transport = ScriptedTransport([.failure(HTTPStatusError(status: 403, response: response))])
        let result = await service(transport).fetch(seriesId: Self.series, vid: Self.vid)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.notice, "弹幕接口不可用（HTTP 403），已尝试官方签名请求；可改用「本集评论」")
        XCTAssertNotEqual(result.notice, "本集暂无弹幕")
    }

    func testLaterPageFailureKeepsPartialResult() async {
        let transport = ScriptedTransport([.success(Self.page([(1000, "一")], next: 5000)), .failure(HongguoError(.timeout, "超时"))])
        let result = await service(transport).fetch(seriesId: Self.series, vid: Self.vid)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.partial)
        XCTAssertEqual(result.items.map(\.text), ["一"])
        XCTAssertEqual(result.notice, "后续弹幕加载中断，已保留已获取的部分")
    }

    func testEmptyEpisodeAndCache() async {
        let transport = ScriptedTransport([.success(Self.page([], hasMore: false))])
        let svc = service(transport)
        let first = await svc.fetch(seriesId: Self.series, vid: Self.vid)
        XCTAssertTrue(first.success)
        XCTAssertEqual(first.notice, "本集暂无弹幕")
        let second = await svc.fetch(seriesId: Self.series, vid: Self.vid)
        XCTAssertEqual(second, first)
        XCTAssertEqual(transport.urls.count, 1, "second call is served from cache")
    }

    func testHasMoreWithoutCursorIsTruncated() async {
        let transport = ScriptedTransport([.success(Self.page([(1000, "一")], hasMore: true))])
        let result = await service(transport).fetch(seriesId: Self.series, vid: Self.vid)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.notice, "弹幕较多，本次仅载入前 1 条")
    }

    func testLimitAndInvalidIds() async {
        let transport = ScriptedTransport([.success(Self.page([(1000, "一"), (2000, "二"), (3000, "三")], hasMore: false))])
        let limited = await service(transport).fetch(seriesId: Self.series, vid: Self.vid, limit: 2)
        XCTAssertEqual(limited.items.count, 2)
        XCTAssertTrue(limited.truncated)
        let bad = await service(transport).fetch(seriesId: "xifan:a:b", vid: Self.vid)
        XCTAssertEqual(bad.error, "仅红果来源的剧集支持弹幕")
    }
}

final class DanmakuStageTests: XCTestCase {
    func items(_ pairs: [(Double, String)]) -> [DanmakuItem] { pairs.map { DanmakuItem(time: $0.0, text: $0.1) } }
    let viewport = DanmakuStage.Viewport(width: 800, height: 450)

    func testGroupingMergesRepeatsWithinFiveSeconds() {
        let groups = DanmakuEntry.group(items([(1, "哈哈"), (3, "哈哈"), (9, "哈哈"), (4, "好")]))
        XCTAssertEqual(groups.map(\.text), ["哈哈", "哈哈", "好"])
        XCTAssertEqual(groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(DanmakuFilter.displayText("哈哈", count: 2), "哈哈 × 2")
    }

    func testEmitsByTimeAndMovesLeft() {
        var stage = DanmakuStage(items: items([(0.5, "一"), (1.0, "二"), (30, "后面")]))
        stage.advance(currentTime: 0, elapsed: 0, viewport: viewport)
        XCTAssertTrue(stage.items.isEmpty)
        var t = 0.0
        for _ in 0..<20 { t += 0.1; stage.advance(currentTime: t, elapsed: 0.1, viewport: viewport) }
        XCTAssertEqual(Set(stage.items.map(\.content)), ["一", "二"])
        XCTAssertTrue(stage.items.allSatisfy { $0.x < viewport.width })
    }

    func testSeekSkipsPastAndStaleComments() {
        var stage = DanmakuStage(items: items([(1, "早"), (100, "跳转后")]))
        stage.advance(currentTime: 0, elapsed: 0, viewport: viewport)
        stage.advance(currentTime: 100.05, elapsed: 0.016, viewport: viewport)
        XCTAssertEqual(stage.items.map(\.content), ["跳转后"])
    }

    func testBlockedWordsAreSkipped() {
        var settings = DanmakuSettings()
        settings.blockedWords = "剧透，spoiler"
        var stage = DanmakuStage(items: items([(0, "前方剧透"), (0, "SPOILER alert"), (0, "好看")]), settings: settings)
        stage.advance(currentTime: 0.1, elapsed: 0.1, viewport: viewport)
        XCTAssertEqual(stage.items.map(\.content), ["好看"])
        XCTAssertTrue(DanmakuFilter.isBlocked("ｓｐｏｉｌｅｒ", settings: settings), "NFKC folds full-width text")
    }

    func testLayoutAndSettingsClamp() {
        var settings = DanmakuSettings()
        settings.fontSize = 100
        settings.speed = 0
        settings = settings.normalized()
        XCTAssertEqual(settings.fontSize, 32)
        XCTAssertEqual(settings.speed, 0.5)
        let layout = DanmakuLayout.make(height: 450, settings: DanmakuSettings(), reducedMotion: false)
        XCTAssertEqual(layout.lineHeight, 34)
        XCTAssertEqual(layout.lanes, Int((225.0 - 12) / 34))
    }

    func testStatusNeverHidesErrors() {
        XCTAssertEqual(DanmakuStage.status(supported: true, enabled: true, active: true, error: "弹幕接口暂不可用", loading: false,
                                           notice: "", loaded: true, count: 0), "弹幕接口暂不可用")
        XCTAssertEqual(DanmakuStage.status(supported: true, enabled: true, active: true, error: "", loading: false,
                                           notice: "", loaded: true, count: 0), "本集暂无弹幕")
        XCTAssertEqual(DanmakuStage.status(supported: true, enabled: true, active: true, error: "", loading: false,
                                           notice: "弹幕较多", loaded: true, count: 5), "已载入 5 条弹幕（弹幕较多）")
    }
}

private extension Double {
    var toInt64: Int64 { Int64(self) }
}

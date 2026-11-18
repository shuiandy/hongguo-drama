// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `Fixtures/app-search-signing-vectors.json` comes from `scripts/gen-app-search-vectors.cjs`, which
/// runs the Electron reference (src/native/app-source.js) with fixed time, nonce and randoms.
final class AppSearchSigningTests: XCTestCase {
    static let fixture: JSONValue = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/app-search-signing-vectors.json")
        return try! JSONValue.parse(Data(contentsOf: url))
    }()

    final class Queue: @unchecked Sendable {
        var values: [UInt32]
        init(_ values: [UInt32]) { self.values = values }
        func next() -> UInt32 { values.removeFirst() }
    }

    func signer(_ randoms: [UInt32], deviceId: String = "1", installId: String = "1") -> (AppLegacySigner, Queue) {
        let queue = Queue(randoms)
        let nonce = AppCrypto.fromHex(Self.fixture["processNonceHex"].string!)!
        let signer = AppLegacySigner(processNonce: AppCrypto.base64(nonce).base64URL,
                                     processStarted: Int64(Self.fixture["processStarted"].number!),
                                     random32: { queue.next() }, metadataDeviceId: deviceId, metadataInstallId: installId)
        return (signer, queue)
    }

    func randoms(_ item: JSONValue) -> [UInt32] { (item["randoms"].array ?? []).map { UInt32($0.number!) } }

    func assertHeaders(_ signed: AppLegacySigner.Signed, _ item: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        let expected = item["headers"].object ?? [:]
        XCTAssertEqual(Set(signed.headers.map(\.0)), Set(expected.keys), file: file, line: line)
        for (name, value) in signed.headers {
            XCTAssertEqual(value, expected[name]?.string, "\(name)", file: file, line: line)
        }
    }

    func testSearchRequestMatchesReference() throws {
        let identity = Self.fixture["identity"]
        let id = PlaybackIdentity(deviceId: identity["device_id"].string!, iid: identity["iid"].string!, cdid: identity["cdid"].string!)
        for item in Self.fixture["search"].array ?? [] {
            let (signer, queue) = signer(randoms(item))
            let cursor = item["cursor"].object.map { c in
                AppLegacySigner.SearchCursor(searchId: c["search_id"]?.string ?? "", passback: c["passback"]?.string ?? "",
                                             nextOffset: c["next_offset"]?.number.map(Int.init))
            }
            let signed = try signer.search(keyword: item["keyword"].string!, page: Int(item["page"].number!), cursor: cursor,
                                           identity: id, nowMillis: Int64(item["now"].number!))
            XCTAssertEqual(signed.url, item["url"].string)
            assertHeaders(signed, item)
            XCTAssertEqual(queue.values.count, randoms(item).count - Int(item["used"].number!), "same number of random draws")
        }
    }

    func testCatalogueRequestMatchesReference() throws {
        for item in Self.fixture["metadata"].array ?? [] {
            let url = try XCTUnwrap(item["url"].string)
            let query = String(url.split(separator: "?")[1])
            let (signer, _) = signer(randoms(item), deviceId: AppCrypto.queryParam(query, "device_id")!, installId: AppCrypto.queryParam(query, "iid")!)
            // JS object order of the fixture values.
            let raw = try XCTUnwrap(item["values"].object)
            let order = ["offset", "limit", "genre", "a"].filter { raw[$0] != nil }
            let body = item["body"].string.map { Array($0.utf8) }
            let signed = try signer.metadata(path: item["apiPath"].string!, values: order.map { ($0, raw[$0]!.string!) },
                                             payload: body, nowMillis: Int64(item["now"].number!))
            XCTAssertEqual(signed.url, url)
            assertHeaders(signed, item)
        }
    }

    func testAccountRequestMatchesReference() throws {
        let identity = Self.fixture["identity"]
        let id = PlaybackIdentity(deviceId: identity["device_id"].string!, iid: identity["iid"].string!, cdid: identity["cdid"].string!)
        for item in Self.fixture["account"].array ?? [] {
            let (signer, _) = signer(randoms(item))
            let raw = item["values"].object ?? [:]
            let values = (item["valueOrder"].array ?? []).map { ($0.string!, raw[$0.string!]!.string!) }
            let signed = try signer.account(path: item["apiPath"].string!, values: values, identity: id, nowMillis: Int64(item["now"].number!))
            XCTAssertEqual(signed.url, item["url"].string)
            assertHeaders(signed, item)
        }
    }

    func testXGorgonAndBranchBasics() {
        let gorgon = AppLegacySigner.xGorgon(query: "a=1", body: nil, ts: 1_700_000_000, random: 0xabcd)
        XCTAssertTrue(gorgon.hasPrefix("8404cdab4001"))
        XCTAssertEqual(gorgon.count, 52)
        XCTAssertThrowsError(try AppLegacySigner.shared.metadata(path: "/other", values: [], payload: nil, nowMillis: 0))
    }
}

final class AppSearchParsingTests: XCTestCase {
    func testParsesShortDramaTab() throws {
        let payload = try JSONValue.parse("""
        {"code":0,"search_tabs":[{"tab_type":1,"data":[]},{"tab_type":11,"has_more":true,"search_id":"s9","passback":"pb","next_offset":"20","data":[
          {"cell_name":"广告"},
          {"search_high_light":{"title":{"text":"<em>霸总</em>归来 &amp; 重生"}},"video_data":[{"series_id":"7200000000000000001","cover":"https://p3.example.com/a.jpg","episode_cnt":"80","series_intro":" 简介 "}]},
          {"video_data":[{"series_id":"7200000000000000001","title":"重复"}]},
          {"video_data":[{"series_id":"7200000000000000002","title":"第二部","cover":"https://p3.example.com/b.heic?x=1"}]}
        ]}]}
        """)
        let page = try AppSearchService.parse(payload, page: 1)
        XCTAssertEqual(page.results.map(\.title), ["霸总归来 & 重生", "第二部"])
        XCTAssertEqual(page.results[0].episodeCount, 80)
        XCTAssertEqual(page.results[0].description, "简介")
        XCTAssertEqual(page.results[1].cover, "", "HEIC covers are dropped")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.cursor, AppSearchCursor(searchId: "s9", passback: "pb", nextOffset: 20))
        XCTAssertThrowsError(try AppSearchService.parse(try JSONValue.parse(#"{"code":1}"#), page: 1))
        XCTAssertThrowsError(try AppSearchService.parse(try JSONValue.parse(#"{"code":0,"search_tabs":[{"tab_type":1}]}"#), page: 1))
    }

    func testTitleHelpers() {
        XCTAssertEqual(SearchText.normalize("《霸总，归来》 Ⅱ!"), "霸总归来ii")
        XCTAssertEqual(SearchText.relaxedQueries("霸总，归来"), ["霸总归来", "霸总"])
        XCTAssertEqual(SearchText.relaxedQueries("霸总归来"), [])
        XCTAssertEqual(SearchText.catalogCover("https://p6-novel.byteimg.com/novel-pic/abc~tplv-x.heic"),
                       "https://p3-novel.byteimg.com/novel-pic/abc~tplv-shrink:640:0.image")
        XCTAssertEqual(SearchText.catalogCover("https://evil.example.com/novel-pic/abc~x.heic"), "")
    }
}

final class NewReleaseTests: XCTestCase {
    func row(_ id: String, _ title: String, tags: [String] = [], today: Bool = false) -> [String: Any] {
        var labels: [[String: Any]] = tags.map { ["content": $0] }
        if today { labels.append(["content": "今日上新"]) }
        return ["series_id": id, "title": title, "episode_cnt": 60, "tag_info": ["text": "新剧"], "sub_title_list": labels]
    }

    func page(_ rows: [[String: Any]], more: Bool = false, next: Int = 0) -> JSONValue {
        let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": ["video_data": rows, "has_more": more, "next_offset": next, "session_id": "s"]])
        return try! JSONValue.parse(data)
    }

    func testListsBothGenresMergesAndMatches() async throws {
        final class Bodies: @unchecked Sendable { let lock = NSLock(); var all: [[String: Any]] = []
            func add(_ b: [String: Any]) { lock.lock(); all.append(b); lock.unlock() } }
        let bodies = Bodies()
        let service = NewReleaseService(fetch: { body, _ in
            let json = try JSONSerialization.jsonObject(with: Data(body)) as! [String: Any]
            bodies.add(json)
            if json["req_scene"] as? String == "ai_series" { return self.page([self.row("7200000000000000003", "接班人", tags: ["都市"], today: true)]) }
            if (json["offset"] as? Int) == 0 {
                return self.page([self.row("7200000000000000001", "接班人的考题", tags: ["逆袭"]), self.row("7200000000000000003", "接班人")], more: true, next: 50)
            }
            return self.page([self.row("7200000000000000002", "接班")])
        })
        let listing = try await service.list()
        XCTAssertEqual(listing.items.map(\.series.seriesId), ["7200000000000000001", "7200000000000000003", "7200000000000000002"])
        XCTAssertFalse(listing.partial)
        let merged = listing.items[1]
        XCTAssertTrue(merged.releasedToday, "the AI list's today mark is kept")
        XCTAssertEqual(merged.series.tags, ["都市"])
        XCTAssertEqual(bodies.all.count, 3)
        XCTAssertTrue(bodies.all.contains { ($0["req_type"] as? String) == "only_content" && ($0["offset"] as? Int) == 50 })
        let matches = NewReleaseService.match(listing.items, keyword: "接班")
        XCTAssertEqual(matches.map(\.series.title), ["接班", "接班人", "接班人的考题"], "exact, then today, then the rest")
        XCTAssertEqual(NewReleaseService.match(listing.items, keyword: "接"), [])
        let cached = try await service.list()
        XCTAssertTrue(cached.cached)
        XCTAssertEqual(bodies.all.count, 3)
    }

    func testOneGenreFailingIsPartialAndNotCached() async throws {
        let service = NewReleaseService(fetch: { body, _ in
            let json = try JSONSerialization.jsonObject(with: Data(body)) as! [String: Any]
            if json["req_scene"] as? String == "ai_series" { throw HongguoError(.network, "down") }
            return self.page([self.row("7200000000000000001", "新剧")])
        })
        let first = try await service.list()
        XCTAssertTrue(first.partial)
        let second = try await service.list()
        XCTAssertFalse(second.cached)
    }
}

final class HongguoSearchFlowTests: XCTestCase {
    func summary(_ id: String, _ title: String) -> SeriesSummary { SeriesSummary(seriesId: id, title: title) }
    func webPage(_ items: [SeriesSummary], more: Bool = false) -> SearchPage {
        SearchPage(keyword: "", results: items, total: items.count, totalPages: 1, page: 1, hasMore: more)
    }

    func testWebWithRelaxedQueryAndNewReleaseSupplement() async throws {
        let search = HongguoSearch(web: { keyword, _ in
            if keyword == "霸总，归来" { return self.webPage([self.summary("7200000000000000009", "别的剧")]) }
            if keyword == "霸总归来" { return self.webPage([self.summary("7200000000000000001", "霸总归来之前传")]) }
            return self.webPage([])
        }, app: { _, _, _ in XCTFail("App search is off"); throw HongguoError(.unavailable, "") },
           newReleases: { _, _ in ([NewRelease(series: self.summary("7200000000000000002", "霸总归来"), releasedToday: true)], false) })
        let result = try await search.search("霸总，归来")
        XCTAssertEqual(result.channel, .web)
        XCTAssertEqual(result.relaxedQueries, ["霸总归来"])
        XCTAssertEqual(result.results.map(\.seriesId), ["7200000000000000009", "7200000000000000001", "7200000000000000002"])
        XCTAssertEqual(result.releasedTodayIds, ["7200000000000000002"])
        XCTAssertEqual(result.notice, "")
    }

    func testAppFirstAndFallbacks() async throws {
        let appPage = AppSearchPage(results: [summary("7200000000000000001", "霸总归来")], page: 1, hasMore: true,
                                    cursor: AppSearchCursor(searchId: "s", passback: "", nextOffset: 20))
        let appFirst = HongguoSearch(web: { _, _ in XCTFail("web not needed"); return self.webPage([]) },
                                     app: { _, page, cursor in
                                         if page == 2 { XCTAssertEqual(cursor?.nextOffset, 20) }
                                         return appPage
                                     }, newReleases: { _, _ in ([], false) })
        let first = try await appFirst.search("霸总归来", appFirst: true)
        XCTAssertEqual(first.channel, .app)
        let more = try await appFirst.search("霸总归来", page: 2, channel: .app, appCursor: first.appCursor)
        XCTAssertEqual(more.channel, .app)

        // Website down: the App answers without being enabled.
        let fallback = HongguoSearch(web: { _, _ in throw HongguoError(.upstream, "官网 502") }, app: { _, _, _ in appPage },
                                     newReleases: { _, _ in ([], false) })
        let rescued = try await fallback.search("霸总归来")
        XCTAssertEqual(rescued.channel, .app)
        XCTAssertTrue(rescued.notice.contains("官网 502"))

        // Website and App down: new releases still answer.
        let last = HongguoSearch(web: { _, _ in throw HongguoError(.upstream, "官网 502") },
                                 app: { _, _, _ in throw HongguoError(.unavailable, "App 不可用") },
                                 newReleases: { _, _ in ([NewRelease(series: self.summary("7200000000000000002", "霸总归来"), releasedToday: false)], false) })
        let found = try await last.search("霸总归来")
        XCTAssertEqual(found.channel, .appNew)
        XCTAssertEqual(found.results.count, 1)

        // Everything fails: an error, not an empty result.
        let none = HongguoSearch(web: { _, _ in throw HongguoError(.upstream, "官网 502") },
                                 app: { _, _, _ in throw HongguoError(.unavailable, "App 不可用") },
                                 newReleases: { _, _ in throw HongguoError(.timeout, "App 上新请求超时") })
        do { _ = try await none.search("霸总归来"); XCTFail("expected an error") }
        catch let error as HongguoError { XCTAssertTrue(error.message.contains("App 上新请求超时")) }
    }
}

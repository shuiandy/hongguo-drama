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

    func signer(_ randoms: [UInt32]) -> (AppLegacySigner, Queue) {
        let queue = Queue(randoms)
        let nonce = AppCrypto.fromHex(Self.fixture["processNonceHex"].string!)!
        let signer = AppLegacySigner(processNonce: AppCrypto.base64(nonce).base64URL,
                                     processStarted: Int64(Self.fixture["processStarted"].number!),
                                     random32: { queue.next() })
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

    /// The client version a reference vector was signed with (requests use `ClientVersion.current`).
    private func referenceVersion(_ item: JSONValue) throws -> AppLegacySigner.ClientVersion {
        let query = String(try XCTUnwrap(item["url"].string).split(separator: "?")[1])
        return .init(code: try XCTUnwrap(AppCrypto.queryParam(query, "version_code")),
                     name: try XCTUnwrap(AppCrypto.queryParam(query, "version_name")))
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
                                           identity: id, nowMillis: Int64(item["now"].number!), version: try referenceVersion(item))
            XCTAssertEqual(signed.url, item["url"].string)
            assertHeaders(signed, item)
            XCTAssertEqual(queue.values.count, randoms(item).count - Int(item["used"].number!), "same number of random draws")
        }
    }

    func testCatalogueRequestMatchesReference() throws {
        for item in Self.fixture["metadata"].array ?? [] {
            let url = try XCTUnwrap(item["url"].string)
            let query = String(url.split(separator: "?")[1])
            let (signer, _) = signer(randoms(item))
            // The reference signs without a cdid, so none is passed here.
            let device = PlaybackIdentity(deviceId: AppCrypto.queryParam(query, "device_id")!, iid: AppCrypto.queryParam(query, "iid")!, cdid: "")
            // JS object order of the fixture values.
            let raw = try XCTUnwrap(item["values"].object)
            let order = ["offset", "limit", "genre", "a"].filter { raw[$0] != nil }
            let body = item["body"].string.map { Array($0.utf8) }
            let path = try XCTUnwrap(item["apiPath"].string)
            if path == "/reading/distribution/category/landpage/v/" {
                XCTAssertEqual(AppLegacySigner.metadataPaths.first, "/reading/distribution/category/landpage/v1/")
                XCTAssertThrowsError(try signer.metadata(path: path, values: [], payload: body, identity: device, nowMillis: 0))
                continue
            }
            let signed = try signer.metadata(path: path, values: order.map { ($0, raw[$0]!.string!) },
                                             payload: body, identity: device, nowMillis: Int64(item["now"].number!),
                                             version: try referenceVersion(item))
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
            let signed = try signer.account(path: item["apiPath"].string!, values: values, identity: id, nowMillis: Int64(item["now"].number!),
                                            version: try referenceVersion(item))
            XCTAssertEqual(signed.url, item["url"].string)
            assertHeaders(signed, item)
        }
    }

    func testXGorgonAndBranchBasics() {
        let gorgon = AppLegacySigner.xGorgon(query: "a=1", body: nil, ts: 1_700_000_000, random: 0xabcd)
        XCTAssertTrue(gorgon.hasPrefix("8404cdab4001"))
        XCTAssertEqual(gorgon.count, 52)
        XCTAssertThrowsError(try AppLegacySigner.shared.metadata(path: "/other", values: [], payload: nil,
                                                                 identity: PlaybackIdentity(deviceId: "1", iid: "1", cdid: ""), nowMillis: 0))
    }

    func testAccountReadAndWriteUseCurrentClientVersion() throws {
        let id = PlaybackIdentity(deviceId: "1234567890123456789", iid: "2234567890123456789", cdid: "01234567-89ab-cdef-0123-456789abcdef")
        let read = try AppLegacySigner.shared.accountRead(
            path: "/reading/bookapi/bookmall/tab/v/",
            values: [("tab_type", "39"), ("bottom_tab_type", "7")],
            identity: id,
            nowMillis: 1_763_430_000_000
        )
        XCTAssertTrue(read.query.contains("version_code=\(AppLegacySigner.currentVersionCode)"))
        XCTAssertTrue(read.query.contains("version_name=\(AppLegacySigner.currentVersionName)"))
        XCTAssertEqual(read.headers.first { $0.0 == "User-Agent" }?.1, AppLegacySigner.currentSearchUA)

        let write = try AppLegacySigner.shared.accountWrite(
            path: "/reading/user/event/report",
            values: [],
            payload: Array("{}".utf8),
            identity: id,
            nowMillis: 1_763_430_000_000
        )
        XCTAssertTrue(write.query.contains("version_code=\(AppLegacySigner.currentVersionCode)"))
        XCTAssertTrue(write.query.contains("version_name=\(AppLegacySigner.currentVersionName)"))
    }
}

final class AppSearchParsingTests: XCTestCase {
    func testParsesShortDramaTab() throws {
        let payload = try JSONValue.parse("""
        {"code":0,"search_tabs":[{"tab_type":1,"data":[]},{"tab_type":11,"has_more":true,"search_id":"s9","passback":"pb","next_offset":"20","data":[
          {"cell_name":"广告"},
          {"search_high_light":{"title":{"text":"<em>霸总</em>归来 &amp; 重生"}},"video_data":[{"series_id":"7200000000000000001","cover":"https://p3.example.com/a.jpg","episode_cnt":"80","series_intro":" 简介 "}]},
          {"video_data":[{"series_id":"7200000000000000001","title":"重复"}]},
          {"video_data":[{"series_id":"7200000000000000002","title":"第二部","cover":"http://p3.example.com/b.heic?x=1","sub_title_list":[{"data_type":27,"content":"99万"},{"data_type":3,"content":"甜宠"}]}]}
        ]}]}
        """)
        let page = try AppSearchService.parse(payload, page: 1)
        XCTAssertEqual(page.results.map(\.title), ["霸总归来 & 重生", "第二部"])
        XCTAssertEqual(page.results[0].episodeCount, 80)
        XCTAssertEqual(page.results[0].description, "简介")
        XCTAssertEqual(page.results[0].episodeLabel, "全80集")
        XCTAssertEqual(page.results[1].cover, "https://p3.example.com/b.heic?x=1", "HEIC covers are kept, forced to https")
        XCTAssertEqual(page.results[1].heat, "99万热度")
        XCTAssertEqual(page.results[1].tags, ["甜宠"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.cursor, AppSearchCursor(searchId: "s9", passback: "pb", nextOffset: 20))
        XCTAssertThrowsError(try AppSearchService.parse(try JSONValue.parse(#"{"code":1}"#), page: 1))
        XCTAssertThrowsError(try AppSearchService.parse(try JSONValue.parse(#"{"code":0,"search_tabs":[{"tab_type":1}]}"#), page: 1))
    }

    func testTitleHelpers() {
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

    func testListsBothGenresAndMerges() async throws {
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

final class SearchSuggestionTests: XCTestCase {
    func testReadsShortDramaNamesFromQueryResultV2() throws {
        let payload = try JSONValue.parse(#"""
        {"code":0,"data":{"query_key":"家里","query_result":["家里家外","家里来了个活爹"],
          "query_result_v2":[{"name":"家里家外","word_type_str":"short_play_name"},{"name":"家里来了个活爹","word_type_str":"short_play_name"},
                             {"name":"家里家外","word_type_str":"short_play_name"},{"name":"","word_type_str":"x"}]}}
        """#)
        XCTAssertEqual(DiscoveryAccess.parseSuggestions(payload), ["家里家外", "家里来了个活爹"])
        XCTAssertEqual(DiscoveryAccess.parseSuggestions(try JSONValue.parse(#"{"code":1}"#)), [])
    }

    func testParsesSearchLandingLynxDataForGuessAndHotTopics() throws {
        let inner = #"""
        [
          {
            "cell_id_str": "7379204038375505982",
            "show_type": 483,
            "cell_name": "猜你想搜",
            "session_id": "2026112100001",
            "next_offset": 3,
            "video_data": [
              {
                "series_id": "7688692318190177304",
                "title": "过海",
                "cover": "https://p3-novel.byteimg.com/example.jpg",
                "episode_cnt": 58,
                "rec_text": "2947万热度",
                "sub_title": "全58集"
              }
            ]
          },
          {
            "cell_id_str": "6976950893023330335",
            "show_type": 624,
            "cell_data": [
              {
                "cell_id_str": "7611744712180891710",
                "show_type": 619,
                "cell_name": "热点话题榜",
                "video_topic": [
                  {
                    "topic_id": "7708986770972525098",
                    "hg_topic_type": 1,
                    "title": "鉴宝剧花小钱捡漏真古董赚大发了",
                    "url": "dragon8662://search?source=1&directQueryWord=%E9%89%B4%E5%AE%9D%E5%89%A7%E6%8D%A1%E6%BC%8F&directSearchSourceId=topic_board#1795242219#7708986770972525098##",
                    "secondary_info_list": [{"content": "5.3万热度"}],
                    "tag_info": {"text": "热"}
                  },
                  {
                    "topic_id": "7708986770972525098",
                    "title": "重复话题应去重"
                  },
                  {
                    "topic_id": "7708986604438536746",
                    "title": "重生剧恶女搞事业比恋爱更带感",
                    "url": "",
                    "secondary_info_list": [{"content": "4.9万热度"}]
                  }
                ]
              }
            ]
          }
        ]
        """#
        let escaped = inner
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
        let payload = try JSONValue.parse("""
        {"code":0,"data":[{"show_type":473,"cell_id_str":"1"},{"show_type":554,"lynx_data":"\(escaped)"}]}
        """)
        let landing = try DiscoveryAccess.parseSearchLanding(payload)
        XCTAssertEqual(landing.guessItems.count, 1)
        XCTAssertEqual(landing.guessItems[0].seriesId, "7688692318190177304")
        XCTAssertEqual(landing.guessItems[0].recommendText, "2947万热度")
        XCTAssertEqual(landing.guessItems[0].metaLine, "全58集")
        XCTAssertEqual(landing.guessSessionId, "2026112100001")
        XCTAssertEqual(landing.guessNextOffset, 3)

        XCTAssertEqual(landing.hotTopicCellId, "7611744712180891710")
        XCTAssertEqual(landing.hotTopics.count, 2)
        XCTAssertEqual(landing.hotTopics[0].topicId, "7708986770972525098")
        XCTAssertEqual(landing.hotTopics[0].title, "鉴宝剧花小钱捡漏真古董赚大发了")
        XCTAssertEqual(landing.hotTopics[0].query, "鉴宝剧捡漏")
        XCTAssertEqual(landing.hotTopics[0].heatText, "5.3万热度")
        XCTAssertEqual(landing.hotTopics[0].badgeText, "热")
        XCTAssertEqual(landing.hotTopics[1].query, "重生剧恶女搞事业比恋爱更带感")
        XCTAssertThrowsError(try DiscoveryAccess.parseSearchLanding(try JSONValue.parse(#"{"code":1}"#)))
    }
}

final class OfficialHostTests: XCTestCase {
    func testLoginCookieGoesOnlyToOfficialHosts() {
        XCTAssertTrue(AppBookMallAccess.isOfficialHost("https://reading.snssdk.com"))
        XCTAssertTrue(AppBookMallAccess.isOfficialHost("https://api5-normal-sinfonlineb.fqnovel.com"))
        XCTAssertFalse(AppBookMallAccess.isOfficialHost("http://reading.snssdk.com"))
        XCTAssertFalse(AppBookMallAccess.isOfficialHost("https://snssdk.com.example.com"))
        XCTAssertFalse(AppBookMallAccess.isOfficialHost("https://evilsnssdk.com"))
        XCTAssertFalse(AppBookMallAccess.isOfficialHost("https://reading.snssdk.com:8443"))
    }
}

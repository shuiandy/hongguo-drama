import XCTest
@testable import HongguoCore

final class ParsingTests: XCTestCase {
    private func page(_ router: Any, extra: String = "") -> String {
        let json = String(data: try! JSONSerialization.data(withJSONObject: router), encoding: .utf8)!
        return "<html><head><script>window._ROUTER_DATA = \(json);</script>\(extra)</head><body></body></html>"
    }

    func testRouterDataHandlesBracesInsideStrings() throws {
        let html = #"<script>_ROUTER_DATA={"a":"}{\"x","b":{"c":1}};var later={}</script>"#
        let value = try HTMLData.routerData(html)
        XCTAssertEqual(value["a"].string, "}{\"x")
        XCTAssertEqual(value["b"]["c"].number, 1)
    }

    func testRouterDataMissing() {
        XCTAssertThrowsError(try HTMLData.routerData("<html></html>"))
    }

    func testEpisodeListFromPlayerPage() throws {
        let html = page(["loaderData": ["player_(series_id)/page": [
            "series_id": "7400000000000000001",
            "seriesDetail": ["series_id": "7400000000000000001", "series_name": "测试剧", "series_cover": "https://p.example/c.jpg",
                             "vid_list": ["7400000000000000011", "7400000000000000012", 7400000000000000013], "accessible_episode_cnt": 2],
        ]]])
        let result = try SeriesService.parseEpisodeList(html, seriesId: "7400000000000000001")
        XCTAssertEqual(result.title, "测试剧")
        XCTAssertEqual(result.episodes.map(\.index), [1, 2, 3])
        XCTAssertEqual(result.episodes.last?.vid, "7400000000000000013")
        XCTAssertEqual(result.episodes.map(\.webAvailable), [true, true, false])
        XCTAssertEqual(result.webAccessibleEpisodes, 2)
    }

    func testEpisodeListRejectsOtherSeries() {
        let html = page(["loaderData": ["detail_page": [
            "seriesDetail": ["series_id": "999999", "vid_list": ["1"]],
        ]]])
        XCTAssertThrowsError(try SeriesService.parseEpisodeList(html, seriesId: "123456"))
    }

    func testEpisodeListRejectsDuplicateVids() {
        let html = page(["loaderData": ["detail_page": [
            "seriesDetail": ["series_id": "123456", "vid_list": ["1", "1"]],
        ]]])
        XCTAssertThrowsError(try SeriesService.parseEpisodeList(html, seriesId: "123456"))
    }

    private func playerPage(vid: String, contentURL: String, pageURL: String, protected: Bool = false) -> String {
        let ld = #"<script type="application/ld+json">{"@type":"VideoObject","url":"\#(pageURL)","contentUrl":"\#(contentURL)"}</script>"#
        let recommendation = #"<script type="application/ld+json">{"@type":"VideoObject","url":"https://hongguoduanju.com/player/2/99","contentUrl":"https://media.example/other.mp4"}</script>"#
        return page(["loaderData": ["player_(series_id)/(vid)/page": [
            "vid": vid, "series_id": "1", "seriesDetail": ["series_id": "1"], "protectedPlayback": protected,
            "publicVideoSeo": ["available": true, "itemId": vid, "seriesId": "1"],
        ]]], extra: recommendation + ld)
    }

    func testWebPlayInfoBindsToCurrentPlayer() throws {
        let html = playerPage(vid: "11", contentURL: "https://media.example/web.mp4?a=1&Range=bytes%3D0-100",
                              pageURL: "https://hongguoduanju.com/player/1/11")
        let info = try SeriesService.parseWebPlayInfo(html, vid: "11", seriesId: "1")
        XCTAssertEqual(info.url.absoluteString, "https://media.example/web.mp4?a=1")
        XCTAssertEqual(info.source, .web)
        XCTAssertNil(info.spadeA)
        XCTAssertEqual(info.referer, "https://hongguoduanju.com/")
    }

    func testWebPlayInfoRejectsPrivateMediaHost() {
        let html = playerPage(vid: "11", contentURL: "http://192.168.1.10/a.mp4", pageURL: "https://hongguoduanju.com/player/1/11")
        XCTAssertThrowsError(try SeriesService.parseWebPlayInfo(html, vid: "11", seriesId: "1")) { error in
            XCTAssertEqual((error as? HongguoError)?.kind, .security)
        }
    }

    func testWebPlayInfoPreviewOnly() {
        let html = playerPage(vid: "11", contentURL: "https://media.example/web.mp4", pageURL: "https://hongguoduanju.com/player/1/11", protected: true)
        XCTAssertThrowsError(try SeriesService.parseWebPlayInfo(html, vid: "11", seriesId: "1")) { error in
            XCTAssertEqual((error as? HongguoError)?.kind, .previewOnly)
        }
    }

    func testSearchParsing() throws {
        let payload: [String: Any] = [
            "searchList": [
                ["video_data": ["series_id": "7400000000000000001", "series_name": "霸总 &amp; 我", "series_cover": "https:\\/\\/p.example\\/a.jpg",
                                "episode_right_text": "全80集", "tags": ["甜宠", ["name": "都市"]]]],
                ["video_data": [:], "keyword": "7400000000000000002", "name": "仅关键字"],
                ["video_data": ["series_id": "7400000000000000001", "series_name": "重复"]],
                ["video_data": ["series_id": "12", "series_name": "太短的编号"]],
            ],
            "totalCount": 2, "totalPages": 1, "pageNum": 1, "hasMore": false,
        ]
        let page = try SearchService.parse(JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(page.results.map(\.seriesId), ["7400000000000000001", "7400000000000000002"])
        XCTAssertEqual(page.results[0].title, "霸总 & 我")
        XCTAssertEqual(page.results[0].episodeCount, 80)
        XCTAssertEqual(page.results[0].tags, ["甜宠", "都市"])
        XCTAssertEqual(page.results[0].cover, "https://p.example/a.jpg")
    }

    func testSearchUpstreamError() {
        XCTAssertThrowsError(try SearchService.parse(Data(#"{"code":"rate_limited","message":"busy"}"#.utf8)))
        XCTAssertThrowsError(try SearchService.parse(Data("<html>".utf8)))
    }

    func testCatalogParsing() throws {
        let html = page(["loaderData": ["category_page": [
            "categoryRoute": ["contentType": "real-drama"],
            "recommendList": [
                ["series_id": "7400000000000000001", "series_name": "剧一", "episode_cnt": 60, "episode_right_text": "全60集", "tags": ["逆袭"]],
                ["series_id": "bad", "series_name": "无效"],
            ],
            "selectorList": [["items": [["selector_item_id": "romance", "show_name": "恋爱"], ["selector_item_id": "BAD SLUG", "show_name": "x"]]]],
            "pagination": ["pageNum": 1, "total": 100, "totalPages": 5],
        ]]])
        let result = try CatalogService.parseCatalog(html, kind: .realDrama, page: 1, sourceURL: CatalogService.url(kind: .realDrama, genre: nil, page: 1))
        XCTAssertEqual(result.results.count, 1)
        XCTAssertEqual(result.results[0].completionStatus, .completed)
        XCTAssertEqual(result.genres, [Genre(slug: "romance", label: "恋爱")])
        XCTAssertEqual(result.totalPages, 5)
    }

    func testRankingFallbackFromArticles() throws {
        let html = """
        <title>热播榜</title>
        <article><span>1</span><h2 id="rank-title-7400000000000000001">榜首剧</h2>
        <a href="/detail?series_id=7400000000000000001">看</a><p>1.2万热度</p></article>
        """
        let result = try CatalogService.parseRanking(html, kind: .hotDrama, page: 1, sourceURL: CatalogService.url(kind: .hotDrama, genre: nil, page: 1))
        XCTAssertEqual(result.results.first?.title, "榜首剧")
        XCTAssertEqual(result.results.first?.rank, 1)
        XCTAssertEqual(result.results.first?.heat, "1.2万热度")
    }

    func testLegacyStreamPrefersH264AndSkipsByteVC2() {
        let model = """
        {"video_list":{
          "v1":{"main_url":"https://cdn.example/hevc.mp4","video_meta":{"codec_type":"h265","vwidth":1080,"vheight":1920},"encrypt_info":{"spade_a":"k1"}},
          "v2":{"main_url":"https://cdn.example/avc.mp4","video_meta":{"codec_type":"h264","vwidth":720,"vheight":1280},"encrypt_info":{"spade_a":"k2"}},
          "v3":{"main_url":"https://cdn.example/vvc.mp4","video_meta":{"codec_type":"bytevc2","vwidth":1080,"vheight":1920}},
          "v4":{"main_url":"http://10.0.0.1/private.mp4","video_meta":{"codec_type":"h264","vwidth":1080,"vheight":1920}}
        }}
        """
        let best = LegacyAPI.bestStream(model)
        XCTAssertEqual(best?.url.absoluteString, "https://cdn.example/avc.mp4")
        XCTAssertEqual(best?.spadeA, "k2")
    }

    func testSeriesIdFromShareURLs() {
        XCTAssertEqual(SeriesService.seriesIdFromURL(URL(string: "https://hongguoduanju.com/player/7400000000000000001/2")!), "7400000000000000001")
        XCTAssertEqual(SeriesService.seriesIdFromURL(URL(string: "https://x.example/s?video_series_id=123456")!), "123456")
        let scheme = "{\"video_id\":\"778899\"}".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(SeriesService.seriesIdFromURL(URL(string: "https://x.example/s?schemeParams=\(scheme)")!), "778899")
        XCTAssertNil(SeriesService.seriesIdFromURL(URL(string: "https://x.example/other")!))
    }

    func testNormalizeVideoURL() {
        XCTAssertEqual(SeriesService.normalizeVideoURL("https://a.example/v.mp4?Range=bytes%3D0-1"), "https://a.example/v.mp4")
        XCTAssertEqual(SeriesService.normalizeVideoURL("https:\\u002F\\u002Fa.example\\u002Fv.mp4?x=1\\u0026y=2"), "https://a.example/v.mp4?x=1&y=2")
    }
}

final class URLGuardTests: XCTestCase {
    func testSyntacticChecks() {
        XCTAssertTrue(URLGuard.isPublicURL("https://hongguoduanju.com/player/1"))
        XCTAssertTrue(URLGuard.isPublicURL("http://8.8.8.8/x"))
        XCTAssertFalse(URLGuard.isPublicURL("file:///etc/passwd"))
        XCTAssertFalse(URLGuard.isPublicURL("https://user:pw@example.com/"))
        XCTAssertFalse(URLGuard.isPublicURL("http://localhost:8080/"))
        XCTAssertFalse(URLGuard.isPublicURL("http://printer.local/"))
        XCTAssertFalse(URLGuard.isPublicURL("http://router.lan/"))
        XCTAssertFalse(URLGuard.isPublicURL("http://intranet/"))
        XCTAssertFalse(URLGuard.isPublicURL("http://127.0.0.1/"))
        XCTAssertFalse(URLGuard.isPublicURL("http://169.254.169.254/latest/meta-data"))
        XCTAssertFalse(URLGuard.isPublicURL("http://[::1]/"))
        XCTAssertFalse(URLGuard.isPublicURL("http://[fd00::1]/"))
        XCTAssertFalse(URLGuard.isPublicURL("http://[::ffff:192.168.0.1]/"))
        XCTAssertTrue(URLGuard.isPublicURL("http://[2606:4700::1111]/"))
    }

    func testAddressClassification() {
        XCTAssertTrue(URLGuard.isFakeIP("198.18.0.5"))
        XCTAssertFalse(URLGuard.isPublicAddress("198.18.0.5"))
        XCTAssertFalse(URLGuard.isPublicAddress("100.64.1.1"))
        XCTAssertFalse(URLGuard.isPublicAddress("224.0.0.1"))
        XCTAssertTrue(URLGuard.isPublicAddress("223.5.5.5"))
        XCTAssertFalse(URLGuard.isPublicAddress("2001:db8::1"))
    }

    func testCheckRejectsPrivateLiteralWithoutNetwork() async {
        do {
            try await URLGuard.check(URL(string: "http://10.1.2.3/a.mp4")!)
            XCTFail("private address must be rejected")
        } catch {
            XCTAssertEqual((error as? HongguoError)?.kind, .security)
        }
    }
}

final class LibraryStoreTests: XCTestCase {
    func testPersistsHistoryAndToleratesOldSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(directory: dir)
        store.savePosition(seriesId: "1", title: "剧", cover: "", total: 10, episodeIndex: 3, vid: "33", position: 12.5, duration: 60, finished: false)
        store.savePosition(seriesId: "1", title: "", cover: "", total: 10, episodeIndex: 3, vid: "33", position: 0, duration: 60, finished: true)
        let reopened = LibraryStore(directory: dir)
        let record = try XCTUnwrap(reopened.record(for: "1"))
        XCTAssertEqual(record.title, "剧")
        XCTAssertEqual(record.completedEpisode, 3)

        let legacy = #"{"theme":"dark"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertTrue(settings.autoNext)
    }
}

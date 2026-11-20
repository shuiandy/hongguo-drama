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
        XCTAssertEqual(result.source, .web)
        XCTAssertEqual(result.episodes.map(\.index), [1, 2, 3])
        XCTAssertEqual(result.episodes.last?.vid, "7400000000000000013")
        // Every episode plays through the App source, whatever the website lets anonymous viewers see.
        XCTAssertEqual(result.episodes.map(\.webAvailable), [nil, nil, nil])
        XCTAssertNil(result.webAccessibleEpisodes)
    }

    func testEpisodeListFromDetailPage() throws {
        let html = page(["loaderData": ["detail_page": [
            "isSuccess": true,
            "seriesDetail": ["series_id": "123456", "series_name": "详情页", "vid_list": ["11", "12"]],
        ]]])
        let result = try SeriesService.parseEpisodeList(html, seriesId: "123456")
        XCTAssertEqual(result.episodes.map(\.vid), ["11", "12"])
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

    func testSeriesIdFromShareURLs() {
        XCTAssertEqual(SeriesService.seriesIdFromURL(URL(string: "https://hongguoduanju.com/player/7400000000000000001/2")!), "7400000000000000001")
        XCTAssertEqual(SeriesService.seriesIdFromURL(URL(string: "https://x.example/s?video_series_id=123456")!), "123456")
        let scheme = "{\"video_id\":\"778899\"}".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(SeriesService.seriesIdFromURL(URL(string: "https://x.example/s?schemeParams=\(scheme)")!), "778899")
        XCTAssertNil(SeriesService.seriesIdFromURL(URL(string: "https://x.example/other")!))
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

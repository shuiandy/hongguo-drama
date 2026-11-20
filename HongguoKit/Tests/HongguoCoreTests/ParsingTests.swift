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

    /// The shape of GET video_tab/multi_video_detail as the official app gets it, cut down to the
    /// fields the parser reads. Ids, names and numbers are made up.
    static let officialDetail = #"""
    {"code":0,"message":"SUCCESS","data":{"video_detail_data":{"7400000000000000001":{"video_data":{
      "series_id":7400000000000000001,"series_id_str":"7400000000000000001","series_title":"测试剧",
      "series_cover":"http://p3-novel.byteimg.com/novel-pic/c.jpg","series_intro":" 简介 ","episode_right_text":"全3集",
      "episode_cnt":3,"series_status":1,"followed_cnt":24009,"series_play_cnt":964567,
      "record_info":{"record_number":"示例备案号","show":true},
      "video_list":[{"vid":7400000000000000012,"vid_index":2,"digged_count":4705,"disable_play":false},
                    {"vid":"7400000000000000011","vid_index":1,"digged_count":52100},
                    {"vid":7400000000000000013,"vid_index":3,"disable_play":true},
                    {"vid":"7400000000000000011","vid_index":1}]}}}}}
    """#

    func testOfficialDetailGivesTheEpisodeListLikesAndSeriesFacts() throws {
        let detail = try OfficialSeriesDetail.parse(try JSONValue.parse(Data(Self.officialDetail.utf8)), seriesId: "7400000000000000001")
        XCTAssertEqual(detail.episodes.map(\.vid), ["7400000000000000011", "7400000000000000012", "7400000000000000013"],
                       "in episode order, duplicates dropped, 19-digit ids kept exact")
        XCTAssertEqual(detail.likes(vid: "7400000000000000011"), 52_100)
        XCTAssertEqual(detail.likes(vid: "7400000000000000012"), 4_705)
        XCTAssertNil(detail.likes(vid: "7400000000000000013"))
        XCTAssertEqual(detail.episodes.map(\.disabled), [false, false, true])
        XCTAssertEqual(detail.title, "测试剧")
        XCTAssertEqual(detail.intro, "简介")
        XCTAssertEqual(detail.cover, "https://p3-novel.byteimg.com/novel-pic/c.jpg", "covers are requested over https")
        XCTAssertEqual(detail.episodeLabel, "全3集")
        XCTAssertEqual(detail.completion, .completed)
        XCTAssertEqual(detail.favoriteCount, 24_009)
        XCTAssertEqual(detail.playCount, 964_567)
        XCTAssertEqual(detail.recordNumber, "示例备案号")

        let list = SeriesService.episodes(from: detail)
        XCTAssertEqual(list.source, .api)
        XCTAssertEqual(list.title, "测试剧")
        XCTAssertEqual(list.episodes.map(\.index), [1, 2, 3])
        XCTAssertEqual(list.episodes.map(\.webAvailable), [nil, nil, nil])
        XCTAssertNil(list.webAccessibleEpisodes)
    }

    func testOfficialDetailRejectsErrorsEmptyListsAndOtherSeries() throws {
        let reply = try JSONValue.parse(Data(Self.officialDetail.utf8))
        XCTAssertThrowsError(try OfficialSeriesDetail.parse(reply, seriesId: "7400000000000000002"), "no entry for the asked series")
        let mismatched = Self.officialDetail.replacingOccurrences(of: #""series_id_str":"7400000000000000001""#, with: #""series_id_str":"7400000000000000009""#)
        XCTAssertThrowsError(try OfficialSeriesDetail.parse(try JSONValue.parse(Data(mismatched.utf8)), seriesId: "7400000000000000001"))
        let rejected = try JSONValue.parse(Data(#"{"code":100103,"message":"PARAM_INVALID","data":null}"#.utf8))
        XCTAssertThrowsError(try OfficialSeriesDetail.parse(rejected, seriesId: "7400000000000000001"))
        let empty = try JSONValue.parse(Data(#"{"code":0,"data":{"video_detail_data":{"7400000000000000001":{"video_data":{"video_list":[]}}}}}"#.utf8))
        XCTAssertThrowsError(try OfficialSeriesDetail.parse(empty, seriesId: "7400000000000000001"))
    }

    func testPublicDetailsTakeFactsFromTheAppAndTheScoreFromTheWebsite() throws {
        let detail = try OfficialSeriesDetail.parse(try JSONValue.parse(Data(Self.officialDetail.utf8)), seriesId: "7400000000000000001")
        let page = try JSONValue.parse(Data(#"{"seriesDetail":{"series_id":"7400000000000000001","series_intro":"官网简介"},"seriesSocialInfo":{"rating":"9.1","rating_count":"120","series_favorite_count":"1","reviews":{"total_count":"7","reviews":[{"content":"好看","user_name":"甲","rating":10}]}}}"#.utf8))
        let details = SeriesService.publicDetails(detail: detail, page: page)
        XCTAssertEqual(details.description, "简介", "the synopsis is the App's")
        XCTAssertEqual(details.favoriteCount, 24_009, "the collect count is the App's")
        XCTAssertEqual(details.completionStatus, .completed)
        XCTAssertEqual(details.rating, 9.1)
        XCTAssertEqual(details.ratingCount, 120)
        XCTAssertEqual(details.reviewTotal, 7)
        XCTAssertEqual(details.reviews.map(\.content), ["好看"])
        let offline = SeriesService.publicDetails(detail: detail, page: nil)
        XCTAssertNil(offline.rating)
        XCTAssertEqual(offline.description, "简介")
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

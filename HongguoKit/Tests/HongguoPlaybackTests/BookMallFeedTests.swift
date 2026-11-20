import XCTest
import HongguoCore
@testable import HongguoPlayback

final class BookMallFeedTests: XCTestCase {
    static let tabFixture = """
    {"code":0,"message":"SUCCESS","data":{"tab_index":0,"tab_item":[
      {"tab_type":8,"title":"找剧","session_id":"tab-session-0001","has_more":false,"next_offset":1,
       "cell_data":[
         {"cell_id_str":"6952850996422770718","next_offset":6,"show_type":506,"cell_data":[
           {"show_type":525,"video_data":[]},
           {"show_type":507,"video_data":[
             {"series_id":"7671966197985856536","vid":"7671977925326949400","title":"持械入宋：第一季","content_type":1004,
              "episode_cnt":100,"play_cnt":25481392,"vertical":true,"disable_play":false,
              "cover":"https://p3-reading-sign.fqnovelpic.com/novel-pic/3edbd9c6ab15ebff3fd0853ec74a4f27~tplv-xxxx:400:0.heic?x-expires=0&x-signature=removed",
              "video_desc":"宋末年，烽火连天。",
              "rec_text":"5930万热度",
              "rec_tags":[{"content":"历史古代·收藏榜 No.4"},{"content":"系列剧·新季榜 No.1"}]}
           ]},
           {"show_type":507,"video_data":[
             {"series_id":"7699859403758914622","vid":"7699861398091746329","title":"人前小保姆，人后是亲妈","content_type":1,
              "episode_cnt":60,"play_cnt":120000,"vertical":true,"disable_play":false,
              "cover":"","video_desc":"示例真人剧"}
           ]}
         ]}
       ]},
      {"tab_type":38,"title":"真人剧","cell_data":[]}
    ]}}
    """

    static let cellChangeFixture = """
    {"code":0,"message":"SUCCESS","data":{"has_more":true,"next_offset":12,"session_id":"tab-session-0002",
     "cell_view":{"cell_id_str":"6952850996422770718","cell_data":[
       {"show_type":507,"video_data":[
         {"series_id":"7694948718188973080","vid":"7694975932020313113","title":"带娃摆摊，前夫找上门第一季","content_type":1,
          "episode_cnt":80,"play_cnt":99000,"vertical":true,"disable_play":false}
       ]},
       {"show_type":523,"video_data":[]}
     ]}}}
    """

    func testParsesInitialTabFeedAndCursor() throws {
        let page = try BookMallFeed.parseTab(JSONValue.parse(Self.tabFixture), channel: .recommend)
        XCTAssertEqual(page.entries.map(\.series.seriesId), ["7671966197985856536", "7699859403758914622"])
        let first = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(first.firstVid, "7671977925326949400")
        XCTAssertEqual(first.series.heat, "5930万热度")
        XCTAssertEqual(first.series.tags, ["历史古代·收藏榜 No.4", "系列剧·新季榜 No.1"])
        XCTAssertEqual(first.series.episodeLabel, "全100集")
        XCTAssertEqual(
            first.series.cover,
            "https://p3-novel.byteimg.com/novel-pic/3edbd9c6ab15ebff3fd0853ec74a4f27~tplv-shrink:640:0.image"
        )
        XCTAssertEqual(
            page.next,
            AppFeedCursor(offset: 6, sessionId: "tab-session-0001", cellId: "6952850996422770718")
        )
    }

    func testParsesCellChangePaginationAndStopsWhenNoMore() throws {
        let cursor = AppFeedCursor(offset: 6, sessionId: "tab-session-0001", cellId: "6952850996422770718")
        let page = try BookMallFeed.parseCellChange(JSONValue.parse(Self.cellChangeFixture), after: cursor)
        XCTAssertEqual(page.entries.map(\.series.seriesId), ["7694948718188973080"])
        XCTAssertEqual(page.entries.first?.firstVid, "7694975932020313113")
        XCTAssertEqual(
            page.next,
            AppFeedCursor(offset: 12, sessionId: "tab-session-0002", cellId: "6952850996422770718")
        )

        let ended = Self.cellChangeFixture.replacingOccurrences(of: "\"has_more\":true", with: "\"has_more\":false")
        XCTAssertNil(try BookMallFeed.parseCellChange(JSONValue.parse(ended), after: cursor).next)

        let stalled = AppFeedCursor(offset: 12, sessionId: "tab-session-0001", cellId: "6952850996422770718")
        XCTAssertNil(try BookMallFeed.parseCellChange(JSONValue.parse(Self.cellChangeFixture), after: stalled).next)
    }

    func testBuildsQueriesPerChannel() {
        XCTAssertEqual(BookMallFeedChannel.recommend.tabType, 8)
        XCTAssertEqual(BookMallFeedChannel.liveAction.tabType, 38)
        XCTAssertEqual(BookMallFeedChannel.comic.tabType, 32)

        let tabParams = Dictionary(uniqueKeysWithValues: BookMallFeed.tabQuery(channel: .liveAction))
        XCTAssertEqual(tabParams["tab_type"], "38")
        XCTAssertEqual(tabParams["offset"], "0")

        let cursor = AppFeedCursor(offset: 6, sessionId: "sid", cellId: "cid")
        let changeParams = Dictionary(uniqueKeysWithValues: BookMallFeed.cellChangeQuery(channel: .comic, cursor: cursor))
        XCTAssertEqual(changeParams["tab_type"], "32")
        XCTAssertEqual(changeParams["offset"], "6")
        XCTAssertEqual(changeParams["cell_id"], "cid")
        XCTAssertEqual(changeParams["session_id"], "sid")
        XCTAssertEqual(changeParams["change_type"], "1")

        let ctx = BookMallFeedContext(
            clientReqType: 1,
            sessionUuid: "uuid-1234",
            recentImprGids: ["111", "222"],
            forceFilterIds: ["333", "111"]
        )
        let ctxTab = Dictionary(uniqueKeysWithValues: BookMallFeed.tabQuery(channel: .recommend, context: ctx))
        XCTAssertEqual(ctxTab["client_req_type"], "1")
        XCTAssertEqual(ctxTab["session_uuid"], "uuid-1234")
        XCTAssertEqual(ctxTab["recent_impr_gid"], "111,222")
        XCTAssertEqual(ctxTab["force_filter_ids"], "333,111")

        let ctxChange = Dictionary(uniqueKeysWithValues: BookMallFeed.cellChangeQuery(channel: .recommend, cursor: cursor, context: ctx))
        XCTAssertEqual(ctxChange["session_uuid"], "uuid-1234")
        XCTAssertEqual(ctxChange["force_filter_ids"], "333,111")
    }

    func testRejectsErrorsAndMalformedPayloads() {
        let cursor = AppFeedCursor(offset: 6, sessionId: "sid", cellId: "cid")
        XCTAssertThrowsError(try BookMallFeed.parseTab(JSONValue.parse("{\"code\":10001,\"data\":{\"tab_item\":[]}}"), channel: .recommend))
        XCTAssertThrowsError(try BookMallFeed.parseTab(JSONValue.parse("{\"code\":0,\"data\":{}}"), channel: .recommend))
        XCTAssertThrowsError(try BookMallFeed.parseCellChange(JSONValue.parse("{\"code\":10001,\"data\":{}}"), after: cursor))
        XCTAssertThrowsError(try BookMallFeed.parseCellChange(JSONValue.parse("{\"code\":0,\"data\":{}}"), after: cursor))
    }
}

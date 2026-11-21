import XCTest
import HongguoCore
@testable import HongguoPlayback

final class BookMallFeedTests: XCTestCase {
    static let tabFixture = """
    {"code":0,"message":"SUCCESS","data":{"tab_index":2,"tab_item":[
      {"tab_type":45,"title":"关注","cell_data":[]},
      {"tab_type":36,"title":"漫剧","session_id":"comic-session-0001","cell_data":[
        {"cell_id":0,"show_type":0,"cell_data":[]},
        {"cell_id_str":"7597343008509411390","show_type":407,"cell_data":[
          {"show_type":407,"video_data":[
            {"series_id":"7706427229428796441","vid":"","cover":"","disable_play":false,
             "video_detail":{
               "series_title":"一秒万年：万古第一废材肝穿武道","content_type":1004,"ai_usage_type":1,
               "episode_cnt":530,"series_play_cnt":8497951,"first_vid":"7706427237167270936",
               "series_cover":"https://p3-reading-sign.fqnovelpic.com/novel-pic/3edbd9c6ab15ebff3fd0853ec74a4f27~tplv-xxxx:400:0.heic?x-expires=0&x-signature=removed",
               "series_intro":"示例漫剧简介",
               "secondary_infos":[{"content":"逆袭","data_type":3},{"content":"玄幻仙侠","data_type":3}]
             }}
          ]},
          {"show_type":407,"video_data":[
            {"series_id":"7699859403758914622","vid":"7699861398091746329","title":"混入的真人剧","content_type":1,"episode_cnt":60}
          ]}
        ]}
      ]},
      {"tab_type":39,"title":"真人剧","session_id":"real-session-0001","cell_data":[
        {"cell_id_str":"7650476176527343678","show_type":407,"cell_data":[
          {"show_type":407,"video_data":[
            {"series_id":"7698299554948467736","vid":"","cover":"","disable_play":false,
             "video_detail":{
               "series_title":"分你七套房，我调去新疆","content_type":1,"episode_cnt":70,
               "series_play_cnt":23971238,"first_vid":"7698302444354145304",
               "series_cover":"https://p3-reading-sign.fqnovelpic.com/novel-pic/11111111111111111111111111111111~tplv-xxxx:400:0.heic?x-expires=0&x-signature=removed",
               "series_intro":"示例真人剧简介",
               "secondary_infos":[
                 {"content":"家庭","data_type":3},
                 {"content":"打脸反派","data_type":3},
                 {"content":"演员·赖艺 靳茗程","data_type":33},
                 {"content":"5930万热度","data_type":27}
               ]
             }}
          ]},
          {"show_type":407,"video_data":[
            {"series_id":"7671966197985856536","vid":"7671977925326949400","title":"混入的漫剧","content_type":1004,"episode_cnt":100}
          ]},
          {"show_type":407,"video_data":[
            {"series_id":"7671966197985856537","vid":"7671977925326949401","title":"混入的AI剧","content_type":1,"ai_usage_type":1,"episode_cnt":80}
          ]}
        ]}
      ]},
      {"tab_type":16,"title":"推荐","session_id":"tab-session-0001","has_more":false,"next_offset":0,
       "cell_data":[
         {"cell_id_str":"7294257141911650341","next_offset":6,"show_type":506,"cell_data":[
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
       ]}
    ]}}
    """

    static let cellChangeFixture = """
    {"code":0,"message":"SUCCESS","data":{"has_more":true,"next_offset":12,"session_id":"tab-session-0002",
     "cell_view":{"cell_id_str":"7650476176527343678","cell_data":[
       {"show_type":407,"video_data":[
         {"series_id":"7694948718188973080","vid":"","video_detail":{
           "series_title":"被弃机场，我掀翻前夫的盛世美梦","content_type":1,"episode_cnt":80,
           "first_vid":"7694975932020313113","series_play_cnt":99000}}
       ]},
       {"show_type":407,"video_data":[
         {"series_id":"7694948718188973081","vid":"7694975932020313114","title":"混入的漫剧","content_type":1004,"episode_cnt":50}
       ]},
       {"show_type":523,"video_data":[]}
     ]}}}
    """

    func testParsesInitialRecommendTabAndCursor() throws {
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
            AppFeedCursor(offset: 6, sessionId: "tab-session-0001", cellId: "7294257141911650341")
        )
    }

    func testParsesShowType407LiveActionAndFiltersComicAndAI() throws {
        let page = try BookMallFeed.parseTab(JSONValue.parse(Self.tabFixture), channel: .liveAction)
        XCTAssertEqual(page.entries.map(\.series.seriesId), ["7698299554948467736"])
        let first = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(first.firstVid, "7698302444354145304")
        XCTAssertEqual(first.series.title, "分你七套房，我调去新疆")
        XCTAssertEqual(first.series.episodeCount, 70)
        XCTAssertEqual(first.series.episodeLabel, "全70集")
        XCTAssertEqual(first.series.description, "示例真人剧简介")
        XCTAssertEqual(first.series.heat, "5930万热度")
        XCTAssertEqual(first.series.tags, ["家庭", "打脸反派"])
        XCTAssertEqual(first.playCount, 23_971_238)
        XCTAssertEqual(first.contentType, 1)
        XCTAssertEqual(first.aiUsageType, 0)
        XCTAssertEqual(
            first.series.cover,
            "https://p3-novel.byteimg.com/novel-pic/11111111111111111111111111111111~tplv-shrink:640:0.image"
        )
        // `next_offset` omitted on show_type=407: cursor advances by raw row count (3).
        XCTAssertEqual(
            page.next,
            AppFeedCursor(offset: 3, sessionId: "real-session-0001", cellId: "7650476176527343678")
        )
    }

    func testParsesShowType407ComicSkipsZeroCellAndFiltersLiveAction() throws {
        let page = try BookMallFeed.parseTab(JSONValue.parse(Self.tabFixture), channel: .comic)
        XCTAssertEqual(page.entries.map(\.series.seriesId), ["7706427229428796441"])
        let first = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(first.firstVid, "7706427237167270936")
        XCTAssertEqual(first.contentType, 1004)
        XCTAssertEqual(first.aiUsageType, 1)
        XCTAssertEqual(
            page.next,
            AppFeedCursor(offset: 2, sessionId: "comic-session-0001", cellId: "7597343008509411390")
        )
    }

    func testRejectsMissingTargetTabInsteadOfFallingBackToAnotherChannel() throws {
        let fallbackOnlyPayload = """
        {"code":0,"message":"SUCCESS","data":{"tab_item":[
          {"tab_type":8,"title":"找剧","session_id":"s1","cell_data":[
            {"cell_id_str":"12345","next_offset":6,"cell_data":[
              {"video_data":[{"series_id":"7671966197985856536","vid":"7671977925326949400","title":"漫剧","content_type":1004}]}
            ]}
          ]}
        ]}}
        """
        XCTAssertThrowsError(try BookMallFeed.parseTab(JSONValue.parse(fallbackOnlyPayload), channel: .liveAction))
        XCTAssertThrowsError(try BookMallFeed.parseTab(JSONValue.parse(fallbackOnlyPayload), channel: .recommend))
    }

    func testParsesCellChangePaginationAndAppliesChannelFilter() throws {
        let cursor = AppFeedCursor(offset: 3, sessionId: "real-session-0001", cellId: "7650476176527343678")
        let livePage = try BookMallFeed.parseCellChange(JSONValue.parse(Self.cellChangeFixture), after: cursor, channel: .liveAction)
        XCTAssertEqual(livePage.entries.map(\.series.seriesId), ["7694948718188973080"])
        XCTAssertEqual(livePage.entries.first?.firstVid, "7694975932020313113")
        XCTAssertEqual(
            livePage.next,
            AppFeedCursor(offset: 12, sessionId: "tab-session-0002", cellId: "7650476176527343678")
        )

        let anyPage = try BookMallFeed.parseCellChange(JSONValue.parse(Self.cellChangeFixture), after: cursor)
        XCTAssertEqual(anyPage.entries.map(\.series.seriesId), ["7694948718188973080", "7694948718188973081"])

        let ended = Self.cellChangeFixture.replacingOccurrences(of: "\"has_more\":true", with: "\"has_more\":false")
        XCTAssertNil(try BookMallFeed.parseCellChange(JSONValue.parse(ended), after: cursor, channel: .liveAction).next)

        let stalled = AppFeedCursor(offset: 12, sessionId: "real-session-0001", cellId: "7650476176527343678")
        XCTAssertNil(try BookMallFeed.parseCellChange(JSONValue.parse(Self.cellChangeFixture), after: stalled, channel: .liveAction).next)
    }

    func testBuildsQueriesPerChannelForVideoSeriesFeedTab() {
        XCTAssertEqual(BookMallFeed.feedBottomTabType, 7)
        XCTAssertEqual(BookMallFeedChannel.recommend.tabType, 16)
        XCTAssertEqual(BookMallFeedChannel.liveAction.tabType, 39)
        XCTAssertEqual(BookMallFeedChannel.comic.tabType, 36)

        let tabParams = Dictionary(uniqueKeysWithValues: BookMallFeed.tabQuery(channel: .liveAction))
        XCTAssertEqual(tabParams["tab_type"], "39")
        XCTAssertEqual(tabParams["bottom_tab_type"], "7")
        XCTAssertEqual(tabParams["offset"], "0")

        let cursor = AppFeedCursor(offset: 3, sessionId: "sid", cellId: "cid")
        let changeParams = Dictionary(uniqueKeysWithValues: BookMallFeed.cellChangeQuery(channel: .comic, cursor: cursor))
        XCTAssertEqual(changeParams["tab_type"], "36")
        XCTAssertEqual(changeParams["bottom_tab_type"], "7")
        XCTAssertEqual(changeParams["offset"], "3")
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
        XCTAssertEqual(ctxTab["tab_type"], "16")
        XCTAssertEqual(ctxTab["bottom_tab_type"], "7")
        XCTAssertEqual(ctxTab["client_req_type"], "1")
        XCTAssertEqual(ctxTab["session_uuid"], "uuid-1234")
        XCTAssertEqual(ctxTab["recent_impr_gid"], "111,222")
        XCTAssertEqual(ctxTab["force_filter_ids"], "333,111")

        let ctxChange = Dictionary(uniqueKeysWithValues: BookMallFeed.cellChangeQuery(channel: .recommend, cursor: cursor, context: ctx))
        XCTAssertEqual(ctxChange["tab_type"], "16")
        XCTAssertEqual(ctxChange["bottom_tab_type"], "7")
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

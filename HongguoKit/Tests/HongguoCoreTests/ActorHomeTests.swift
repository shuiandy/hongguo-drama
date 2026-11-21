import XCTest
@testable import HongguoCore

/// The fixtures have the shape of the official app's user profile replies (first screen, the 剧作
/// list), cut down to the fields the parser reads. Ids, names and numbers are made up.
final class ActorHomeTests: XCTestCase {
    static let home = #"""
    {"code":0,"message":"请求成功","data":{
      "hightlight":{"tab_type":8,"name":"剧作","total":52},
      "tabs":[
        {"tab_type":8,"name":"剧作","total":52,"extra":{"celebrity_works_tab_type":"three_col"},"sort_cfgs":[],
         "sub_tabs":[{"tab_type":100,"name":"全部","total":52},{"tab_type":20,"name":"预约","total":7}]},
        {"tab_type":5,"name":"动态","total":177,"sub_tabs":[{"tab_type":100,"name":"全部"},{"tab_type":13,"name":"合集","total":13}]},
        {"tab_type":9,"name":"私密","is_privacy_tab":true},
        {"tab_type":7,"name":"红果圈","total":1000,"sub_tabs":[]}],
      "common_list_info":{"cursor":"","has_more":true},"data_list":[]}}
    """#

    static let works = #"""
    {"code":0,"message":"请求成功","data":{
      "common_list_info":{"cursor":"c2","has_more":false,"prev_has_more":false},
      "data_list":[
        {"data_type":1,"subscribe_item":{"is_merged_data":true,"name":"7部剧可预约","item_id":"7400000000000000900"}},
        {"data_type":1,"video":{"video_id":"7400000000000000101",
          "common":{"title":"作品甲","cover":"http://p3-novel.byteimg.com/a.jpg","intro":" 简介甲 ","video_content_type":1},
          "expand":{"episode_cnt":81,"sub_title_list":["都市","逆袭"]},
          "stat":{"hot":15049000,"play_cnt":277748,"followed_cnt":59119,"digg_cnt":0}}},
        {"data_type":1,"video":{"video_id":"7400000000000000102",
          "common":{"title":"作品乙","cover":"https://x.example/b.jpg"},
          "expand":{"episode_cnt":0,"sub_title_list":[{"content":"年代"}]},"stat":{"hot":120000000}}},
        {"data_type":1,"video":{"video_id":"7400000000000000101","common":{"title":"作品甲"}}},
        {"data_type":1,"video":{"video_id":"","common":{"title":"无编号"}}},
        {"data_type":1,"subscribe_item":{"item_id":"7400000000000000201","name":"待播丙","cover":"https://x.example/c.jpg",
          "schedule_publish_time":1795622400,"is_subscribed":false}},
        {"data_type":1,"subscribe_item":{"item_id":"7400000000000000202","name":"待播丁","schedule_publish_time":0}}]}}
    """#

    func testHomeGivesTheServersTabs() throws {
        let home = try ActorHomeService.parseHome(try JSONValue.parse(Self.home))
        XCTAssertEqual(home.tabs.map(\.name), ["剧作", "动态", "红果圈"], "private tabs are left out")
        XCTAssertEqual(home.highlight, 8)
        let works = try XCTUnwrap(home.worksTab)
        XCTAssertEqual(works.total, 52)
        XCTAssertEqual(works.subTabs.map(\.name), ["全部", "预约"])
        XCTAssertEqual(works.subTabs.map(\.type), [100, 20])
        XCTAssertThrowsError(try ActorHomeService.parseHome(try JSONValue.parse(#"{"code":103001,"message":"参数错误"}"#)))
    }

    func testCurrentClientWorksTabIs作品() throws {
        let home = try ActorHomeService.parseHome(try JSONValue.parse(#"""
        {"code":0,"data":{"hightlight":23,"tabs":[
          {"tab_type":23,"name":"作品","total":220,"sub_tabs":[{"tab_type":100,"name":"全部","total":220},{"tab_type":22,"name":"剧作","total":45},
            {"tab_type":20,"name":"预约","total":7},{"tab_type":13,"name":"合集","total":0},{"tab_type":121,"name":"剧评","total":2}]},
          {"tab_type":7,"name":"红果圈","total":1000}]}}
        """#))
        let works = try XCTUnwrap(home.worksTab)
        XCTAssertEqual(works.type, 23)
        XCTAssertEqual(works.subTabs.map(\.name), ["全部", "剧作", "预约", "合集", "剧评"])
    }

    func testWorksListReadsReleasedAndUpcomingSeries() throws {
        let page = try ActorHomeService.parseWorks(try JSONValue.parse(Self.works))
        XCTAssertEqual(page.items.map(\.title), ["作品甲", "作品乙", "待播丙", "待播丁"], "repeats, items without an id and the merged card are left out")
        XCTAssertEqual(page.upcomingNote, "7部剧可预约")
        XCTAssertEqual(page.upcomingIds, ["7400000000000000201", "7400000000000000202"])
        XCTAssertEqual(page.cursor, "c2")
        XCTAssertFalse(page.hasMore)
        let first = page.items[0]
        XCTAssertEqual(first.seriesId, "7400000000000000101")
        XCTAssertEqual(first.cover, "https://p3-novel.byteimg.com/a.jpg")
        XCTAssertEqual(first.description, "简介甲")
        XCTAssertEqual(first.episodeCount, 81)
        XCTAssertEqual(first.tags, ["都市", "逆袭"])
        XCTAssertEqual(first.heat, "1504.9万热度")
        XCTAssertEqual(first.episodeLabel, "都市·81集", "genre and episode count, as under the official card")
        XCTAssertNil(first.publishedAt)
        XCTAssertEqual(page.items[1].heat, "1.2亿热度")
        XCTAssertEqual(page.items[1].episodeLabel, "年代")
        XCTAssertEqual(page.items[2].publishedAt, Date(timeIntervalSince1970: 1_795_622_400))
        XCTAssertTrue(page.items[2].episodeLabel.hasSuffix("日上线"))
        XCTAssertEqual(page.items[3].episodeLabel, "待上线")
        XCTAssertNil(page.items[3].publishedAt)
    }

    func testHeatTextAndHottestFirst() {
        XCTAssertEqual(ActorHomeService.heatText(15_049_000), "1504.9万热度")
        XCTAssertEqual(ActorHomeService.heatText(3_570_000), "357万热度")
        XCTAssertEqual(ActorHomeService.heatText(5300), "5300热度")
        XCTAssertEqual(ActorHomeService.heatText(nil), "")
        XCTAssertEqual(ActorHomeService.heatScore("4210万热度"), 42_100_000)
        XCTAssertEqual(ActorHomeService.heatScore("1.2亿热度"), 120_000_000)
        XCTAssertEqual(ActorHomeService.heatScore(""), 0)
        let a = SeriesSummary(seriesId: "1000001", title: "甲", heat: "300万热度")
        let b = SeriesSummary(seriesId: "1000002", title: "乙", heat: "1.1亿热度")
        let c = SeriesSummary(seriesId: "1000003", title: "丙")
        let d = SeriesSummary(seriesId: "1000004", title: "丁", heat: "300万热度")
        XCTAssertEqual(ActorHomeService.hottestFirst([c, a, b, d]).map(\.title), ["乙", "甲", "丁", "丙"], "ties keep their order, no heat goes last")
    }

    func testABadAccountIsNotAskedFor() async {
        do {
            _ = try await ActorHomeService.home(userId: "abc")
            XCTFail("expected an error")
        } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .input)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

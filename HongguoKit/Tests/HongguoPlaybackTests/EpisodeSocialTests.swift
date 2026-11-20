import XCTest
@testable import HongguoCore

/// The fixtures have the shape of the official app's replies (series detail, book_pack_fields on
/// inner_feed_detail, the comment list with the review page's values), cut down to the fields the
/// parsers read. Every id, name and text in them is made up.
final class EpisodeSocialTests: XCTestCase {
    static let sid = "7000000000000000001"

    static let officialDetail = #"""
    {"code":0,"data":{"video_detail_data":{"7000000000000000001":{"video_data":{
      "series_id_str":"7000000000000000001","series_title":"示例剧","series_intro":"示例简介","episode_cnt":2,
      "followed_cnt":24009,"record_info":{"record_number":"App备案号"},
      "celebrities":[{"nickname":"示例演员","sub_title":"饰 主角","role_name":"主角","avatar":"http://example.com/p.jpg","celebrity_id":"9001"},
                     {"nickname":"示例配角","sub_title":"","role_name":"配角","celebrity_id":9002},
                     {"nickname":"示例演员","sub_title":"饰 主角","celebrity_id":"9001"},
                     {"nickname":"","sub_title":"无名"}],
      "category_schema":"[{\"name\":\"都市\",\"schema\":\"sslocal://x\"},{\"name\":\"逆袭\"},{\"name\":\"都市\"},{\"name\":\" \"}]",
      "video_list":[{"vid":"7000000000000000011","vid_index":1,"digged_count":4705},
                    {"vid":"7000000000000000012","vid_index":2}]}}}}}
    """#

    static let packReply = #"""
    {"code":0,"message":"","data":{"7000000000000000001":{
      "action_info":{"digg_cnt":"88000","followed_cnt":24010},
      "base_info":{"publish_time":1786809814},
      "stat_info":{"hot_score_data":{"Score":52630687,"Text":"5263万热度"}}}}}
    """#

    static let reviewReply = #"""
    {"code":0,"message":"success","data":{
      "extra":{"credibility_score":"9.0","credibility_score_count":23973},
      "common_list_info":{"total":786,"cursor":"10","has_more":true},
      "data_list":[
        {"comment":{"comment_id":"8001","expand":{"score":"10"},"stat":{"digg_count":246},
          "common":{"create_timestamp":1794000000,"content":{"text":"很好看"},
            "user_info":{"base_info":{"user_name":"示例用户甲","user_avatar":"http://example.com/a.jpg"}}}}},
        {"comment":{"comment_id":"8002","expand":{"score":"0"},
          "common":{"create_timestamp":1794000100000,"content":{"text":"一般"},
            "user_info":{"base_info":{"user_name":"示例用户乙","expand_user_avatar":"https://example.com/b.jpg"}}}}},
        {"comment":{"comment_id":"8001","expand":{"score":"10"},
          "common":{"content":{"text":"很好看"},"user_info":{"base_info":{"user_name":"示例用户甲"}}}}},
        {"comment":{"comment_id":"8003","common":{"content":{"text":"   "}}}}]}}
    """#

    func testReviewListGivesScoreCountsAndScoredReviews() throws {
        let reviews = try OfficialSeriesReviews.parse(try JSONValue.parse(Self.reviewReply))
        XCTAssertEqual(reviews.rating, 9.0)
        XCTAssertEqual(reviews.ratingCount, 23_973)
        XCTAssertEqual(reviews.page.total, 786)
        XCTAssertEqual(reviews.page.cursor, "10")
        XCTAssertTrue(reviews.page.hasMore)
        let list = reviews.page.comments
        XCTAssertEqual(list.map(\.content), ["很好看", "一般"], "duplicates and blank reviews are dropped")
        XCTAssertEqual(list.map(\.rating), [10, nil], "a score outside 1...10 is treated as no score")
        XCTAssertEqual(list[0].likes, 246)
        XCTAssertEqual(list[0].avatar, "https://example.com/a.jpg", "http pictures are requested over https")
        XCTAssertEqual(list[1].avatar, "https://example.com/b.jpg")
        XCTAssertEqual(list[0].createdAt, Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertEqual(list[1].createdAt, Date(timeIntervalSince1970: 1_794_000_100), "millisecond times are accepted")

        let rejected = try JSONValue.parse(#"{"code":103001,"message":"参数错误"}"#)
        XCTAssertThrowsError(try OfficialSeriesReviews.parse(rejected))
        let unrated = try OfficialSeriesReviews.parse(try JSONValue.parse(#"{"code":0,"data":{"extra":{"credibility_score":-1,"credibility_score_count":-1},"data_list":[]}}"#))
        XCTAssertNil(unrated.rating, "-1 means not rated yet")
        XCTAssertNil(unrated.ratingCount)
        XCTAssertFalse(unrated.page.hasMore)
    }

    func testPackReadGivesHeatAndFirstShown() throws {
        let stats = try OfficialSeriesStats.parse(try JSONValue.parse(Self.packReply), seriesId: Self.sid)
        XCTAssertEqual(stats.heatText, "5263万热度", "the heat keys are capitalised")
        XCTAssertEqual(stats.heatScore, 52_630_687)
        XCTAssertEqual(stats.publishedAt, Date(timeIntervalSince1970: 1_786_809_814))

        XCTAssertThrowsError(try OfficialSeriesStats.parse(try JSONValue.parse(Self.packReply), seriesId: "7000000000000000002"),
                             "no entry for the asked series")
        let unpacked = try JSONValue.parse(#"{"code":200001,"message":"有字段不支持pack secondary_infos"}"#)
        XCTAssertThrowsError(try OfficialSeriesStats.parse(unpacked, seriesId: Self.sid))
    }

    func testDetailGivesCastAndTags() throws {
        let detail = try OfficialSeriesDetail.parse(try JSONValue.parse(Self.officialDetail), seriesId: Self.sid)
        XCTAssertEqual(detail.cast.map(\.name), ["示例演员", "示例配角"], "nameless and repeated entries are dropped")
        XCTAssertEqual(detail.cast.map(\.role), ["饰 主角", "配角"], "the role name stands in for an empty subtitle")
        XCTAssertEqual(detail.cast.map(\.id), ["9001", "9002"])
        XCTAssertEqual(detail.cast.first?.avatar, "https://example.com/p.jpg")
        XCTAssertEqual(detail.tags, ["都市", "逆袭"], "the JSON string is read, repeats and blanks dropped")
        XCTAssertEqual(OfficialSeriesDetail.tags(try JSONValue.parse(#"["悬疑",{"category_name":"复仇"}]"#)), ["悬疑", "复仇"])
    }

    func testEpisodePanelAndReviewsTakeEverythingFromTheApp() throws {
        let detail = try OfficialSeriesDetail.parse(try JSONValue.parse(Self.officialDetail), seriesId: Self.sid)
        let stats = try OfficialSeriesStats.parse(try JSONValue.parse(Self.packReply), seriesId: Self.sid)
        let page = EpisodeSocialService.CommentPage(comments: [], total: 31, cursor: "20", hasMore: true)
        let social = EpisodeSocialService.social(seriesId: Self.sid, vid: "7000000000000000011", detail: detail, stats: stats, comments: page)
        XCTAssertEqual(social.title, "示例剧")
        XCTAssertEqual(social.intro, "示例简介")
        XCTAssertEqual(social.episodeCount, 2)
        XCTAssertEqual(social.episodeLikes, 4_705)
        XCTAssertEqual(social.favoriteCount, 24_009)
        XCTAssertEqual(social.commentTotal, 31, "the comment count is the App comment API's")
        XCTAssertEqual(social.cast.map(\.name), ["示例演员", "示例配角"])
        XCTAssertEqual(social.tags, ["都市", "逆袭"])
        XCTAssertEqual(social.firstShown, Date(timeIntervalSince1970: 1_786_809_814))
        XCTAssertTrue(social.hasMoreComments)

        let second = EpisodeSocialService.social(seriesId: Self.sid, vid: "7000000000000000012", detail: detail, stats: nil, comments: nil)
        XCTAssertNil(second.episodeLikes, "an episode the detail gives no count for has none")
        XCTAssertNil(second.firstShown)
        XCTAssertEqual(second.favoriteCount, 24_009)

        let list = try OfficialSeriesReviews.parse(try JSONValue.parse(Self.reviewReply))
        let reviews = EpisodeSocialService.reviews(from: list, detail: detail, stats: stats)
        XCTAssertEqual(reviews.rating, 9.0)
        XCTAssertEqual(reviews.ratingCount, 23_973)
        XCTAssertEqual(reviews.reviewTotal, 786)
        XCTAssertEqual(reviews.heatText, "5263万热度")
        XCTAssertEqual(reviews.favoriteCount, 24_009, "the collect count is the detail's")
        XCTAssertEqual(reviews.recordNumber, "App备案号")
        XCTAssertEqual(reviews.cast.count, 2)
        XCTAssertEqual(reviews.nextCursor, "10")
        XCTAssertTrue(reviews.hasMoreReviews)

        let bare = EpisodeSocialService.reviews(from: list, detail: nil, stats: nil)
        XCTAssertEqual(bare.heatText, "")
        XCTAssertNil(bare.favoriteCount)
        XCTAssertEqual(bare.recordNumber, "")
        XCTAssertEqual(bare.rating, 9.0, "the score stands on its own")
    }
}

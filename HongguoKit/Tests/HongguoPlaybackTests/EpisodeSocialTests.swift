import XCTest
@testable import HongguoCore

/// The fixture has the shape of the public player page's router data, cut down to the fields
/// the parser reads. Every id, name and text in it is made up.
final class EpisodeSocialTests: XCTestCase {
    func testListMustCoverAllDeclaredEpisodesWithoutHoles() {
        XCTAssertFalse(EpisodeSocialService.isCompleteEpisodeList(Array(1...20), declaredCount: 63))
        XCTAssertFalse(EpisodeSocialService.isCompleteEpisodeList([1, 3, 4], declaredCount: 3))
        XCTAssertTrue(EpisodeSocialService.isCompleteEpisodeList([1, 2, 3], declaredCount: 3))
    }

    static let page = """
    <html><script>window._ROUTER_DATA = {"loaderData":{"player_page":{"isSuccess":true,"vid":"7000000000000000101",
      "seriesSocialInfo":{"series_favorite_count":"146000"},
      "episodeSocialInfo":{"episode_like_count":"9800","reviews":{"total_count":"422","reviews":[
        {"create_time":"1794000000","digg_count":"20","user_name":"示例用户甲","user_avatar":"http://example.com/a.jpg","content":"第一条"},
        {"create_time":1794000100000,"digg_count":8,"user_name":"示例用户乙","user_avatar":"https://example.com/b.jpg","content":"第二条"},
        {"create_time":"1794000000","digg_count":"20","user_name":"示例用户甲","user_avatar":"","content":"第一条"},
        {"create_time":"1794000200","digg_count":"1","user_name":"空内容","content":"   "}]}},
      "seriesDetail":{"series_id":"7000000000000000001","series_name":"示例剧","series_cover":"https://example.com/c.jpg",
        "series_intro":"示例简介","episode_cnt":95,"tags":["都市","逆袭"],"first_visible_time":"1793000000",
        "celebrities":[{"nickname":"示例演员","sub_title":"饰 主角","avatar":"https://example.com/p.jpg","celebrity_id":"9001"}]}}}};</script></html>
    """

    func testParsesCommentsWithAuthorDateAndLikes() throws {
        let social = try EpisodeSocialService.parse(Self.page, seriesId: "7000000000000000001", vid: "7000000000000000101")
        XCTAssertEqual(social.comments.map(\.content), ["第一条", "第二条"], "duplicates and blank comments are dropped")
        XCTAssertEqual(social.comments[0].author, "示例用户甲")
        XCTAssertEqual(social.comments[0].likes, 20)
        XCTAssertEqual(social.comments[0].avatar, "https://example.com/a.jpg", "http pictures are requested over https")
        XCTAssertEqual(social.comments[0].createdAt, Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertEqual(social.comments[1].createdAt, Date(timeIntervalSince1970: 1_794_000_100), "millisecond times are accepted")
        XCTAssertEqual(social.commentTotal, 422)
        XCTAssertEqual(social.episodeLikes, 9800)
    }

    func testParsesSeriesFigures() throws {
        let social = try EpisodeSocialService.parse(Self.page, seriesId: "7000000000000000001", vid: "7000000000000000101")
        XCTAssertEqual(social.title, "示例剧")
        XCTAssertEqual(social.episodeCount, 95)
        XCTAssertEqual(social.tags, ["都市", "逆袭"])
        XCTAssertEqual(social.favoriteCount, 146_000)
        XCTAssertEqual(social.firstShown, Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(social.cast.first?.name, "示例演员")
        XCTAssertEqual(social.cast.first?.role, "饰 主角")
    }

    static let detailPage = """
    <html><script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"isSuccess":true,
      "seriesDetail":{"series_id":"7000000000000000001","series_name":"示例剧"},
      "seriesSocialInfo":{"rating":"9.2","rating_count":"19248","series_favorite_count":"3286000",
        "hot_score_data":{"score":"37349818","text":"3734万热度"},
        "reviews":{"total_count":"2137","reviews":[
          {"create_time":"1794000000","digg_count":"246","rating":"10","user_name":"示例用户甲","user_avatar":"","content":"很好看"},
          {"create_time":"1794000001","digg_count":"3","rating":"0","user_name":"示例用户乙","user_avatar":"","content":"一般"}]}}}}};</script></html>
    """

    func testParsesSeriesReviewsWithScores() throws {
        let reviews = try EpisodeSocialService.parseReviews(Self.detailPage, seriesId: "7000000000000000001")
        XCTAssertEqual(reviews.rating, 9.2)
        XCTAssertEqual(reviews.ratingCount, 19248)
        XCTAssertEqual(reviews.heatText, "3734万热度")
        XCTAssertEqual(reviews.favoriteCount, 3_286_000)
        XCTAssertEqual(reviews.reviewTotal, 2137)
        XCTAssertEqual(reviews.reviews.map(\.rating), [10, nil], "a score outside 1...10 is treated as no score")
        XCTAssertEqual(reviews.reviews[0].likes, 246)
    }

    func testRejectsAnotherSeries() {
        XCTAssertThrowsError(try EpisodeSocialService.parse(Self.page, seriesId: "7000000000000000002", vid: "7000000000000000101"))
    }
}

import XCTest
@testable import HongguoCore

/// The fixture has the shape of the public series page's router data (read for the episode
/// list, the series facts, the score, written reviews and cast), cut down to the fields the parser reads. Every id,
/// name and text in it is made up.
final class EpisodeSocialTests: XCTestCase {
    static let detailPage = """
    <html><script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"isSuccess":true,
      "seriesDetail":{"series_id":"7000000000000000001","series_name":"示例剧","record_number":"示例备案号",
        "celebrities":[{"nickname":"示例演员","sub_title":"饰 主角","avatar":"http://example.com/p.jpg","celebrity_id":"9001"},
                       {"nickname":"","sub_title":"无名"}]},
      "seriesSocialInfo":{"rating":"9.2","rating_count":"19248","series_favorite_count":"3286000",
        "hot_score_data":{"score":"37349818","text":"3734万热度"},
        "reviews":{"total_count":"2137","reviews":[
          {"create_time":"1794000000","digg_count":"246","rating":"10","user_name":"示例用户甲","user_avatar":"http://example.com/a.jpg","content":"很好看"},
          {"create_time":1794000100000,"digg_count":3,"rating":"0","user_name":"示例用户乙","user_avatar":"","content":"一般"},
          {"create_time":"1794000000","digg_count":"246","rating":"10","user_name":"示例用户甲","user_avatar":"","content":"很好看"},
          {"create_time":"1794000200","digg_count":"1","user_name":"空内容","content":"   "}]}}}}};</script></html>
    """

    func testParsesSeriesReviewsWithScores() throws {
        let reviews = try EpisodeSocialService.parseReviews(Self.detailPage, seriesId: "7000000000000000001")
        XCTAssertEqual(reviews.rating, 9.2)
        XCTAssertEqual(reviews.ratingCount, 19248)
        XCTAssertEqual(reviews.heatText, "3734万热度")
        XCTAssertEqual(reviews.favoriteCount, 3_286_000)
        XCTAssertEqual(reviews.reviewTotal, 2137)
        XCTAssertEqual(reviews.recordNumber, "示例备案号")
        XCTAssertEqual(reviews.reviews.map(\.content), ["很好看", "一般"], "duplicates and blank reviews are dropped")
        XCTAssertEqual(reviews.reviews.map(\.rating), [10, nil], "a score outside 1...10 is treated as no score")
        XCTAssertEqual(reviews.reviews[0].likes, 246)
        XCTAssertEqual(reviews.reviews[0].avatar, "https://example.com/a.jpg", "http pictures are requested over https")
        XCTAssertEqual(reviews.reviews[0].createdAt, Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertEqual(reviews.reviews[1].createdAt, Date(timeIntervalSince1970: 1_794_000_100), "millisecond times are accepted")
    }

    func testParsesCastFromTheSeriesPage() throws {
        let reviews = try EpisodeSocialService.parseReviews(Self.detailPage, seriesId: "7000000000000000001")
        XCTAssertEqual(reviews.cast.map(\.name), ["示例演员"], "nameless entries are dropped")
        XCTAssertEqual(reviews.cast.first?.role, "饰 主角")
        XCTAssertEqual(reviews.cast.first?.avatar, "https://example.com/p.jpg")
    }

    static let playerPage = """
    <html><script>window._ROUTER_DATA = {"loaderData":{"player_(series_id)/(vid)/page":{"isSuccess":true,
      "seriesDetail":{"series_id":"7000000000000000001","series_name":"示例剧"},
      "episodeSocialInfo":{"episode_like_count":"52100","reviews":{"total_count":"9","reviews":[]}}}}};</script></html>
    """

    func testEpisodePanelTakesLikesFromThePlayerPageAndCollectsFromTheSeriesPage() throws {
        let series = try SitePages.loaderData(Self.detailPage, seriesId: "7000000000000000001")
        let player = try SitePages.loaderData(Self.playerPage, seriesId: "7000000000000000001")
        let page = EpisodeSocialService.CommentPage(comments: [], total: 31, cursor: "20", hasMore: true)
        let social = EpisodeSocialService.social(seriesId: "7000000000000000001", vid: "7000000000000000011",
                                                 series: series, player: player, comments: page)
        XCTAssertEqual(social.title, "示例剧")
        XCTAssertEqual(social.episodeLikes, 52_100)
        XCTAssertEqual(social.favoriteCount, 3_286_000)
        XCTAssertEqual(social.commentTotal, 31, "the comment count is the App comment API's")
        XCTAssertEqual(social.cast.map(\.name), ["示例演员"])
        XCTAssertTrue(social.hasMoreComments)

        let hidden = EpisodeSocialService.social(seriesId: "7000000000000000001", vid: "7000000000000000011",
                                                 series: series, player: nil, comments: nil)
        XCTAssertNil(hidden.episodeLikes, "an episode the website hides has no like count")
        XCTAssertEqual(hidden.favoriteCount, 3_286_000)
    }

    func testRejectsAnotherSeries() {
        XCTAssertThrowsError(try EpisodeSocialService.parseReviews(Self.detailPage, seriesId: "7000000000000000002"))
    }
}

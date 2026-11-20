import XCTest
import HongguoCore
@testable import HongguoPlayback

/// The fixture has the shape of a real category list response, cut down to the fields the
/// parser reads. Ids, titles, covers and the session value are made up; nothing in it came
/// from a device or an account.
final class AppFeedTests: XCTestCase {
    static let fixture = """
    {"code":0,"message":"success","data":{"has_more":true,"next_offset":15,"session_id":"fixture-session-0001","max_expand_num":0,
     "video_data":[
      {"series_id":"7000000000000000001","vid":"7000000000000000101","title":"示例真人剧 <b>第一部</b>","content_type":1,
       "cover":"https://p3-reading-sign.fqnovelpic.com/novel-pic/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~tplv-xxxx:400:0.heic?x-expires=0&x-signature=removed",
       "episode_cnt":96,"comment_count":12,"play_cnt":18279659,"vertical":true,"disable_play":false,"episode":true,
       "video_desc":"示例简介  第一行\\n第二行",
       "sub_title_list":[{"content":"第3季","data_type":0},{"content":"7031万","data_type":27},{"content":"家庭","data_type":0}],
       "tag_info":{"text":"新剧"}},
      {"series_id":7000000000000000002,"vid":"7000000000000000102","title":"示例漫剧","content_type":1004,
       "cover":"","episode_cnt":"76","comment_count":"0","play_cnt":"7331","vertical":false,"disable_play":false,
       "sub_title_list":[{"content":"1489万","data_type":27}]},
      {"series_id":"7000000000000000001","vid":"7000000000000000101","title":"重复的一行","content_type":1},
      {"series_id":"7000000000000000003","vid":"7000000000000000103","title":"不可播放","content_type":1,"disable_play":true},
      {"series_id":"7000000000000000004","vid":"7000000000000000104","title":"图文漫画","content_type":7},
      {"series_id":"7000000000000000005","title":"没有第一集","content_type":1},
      {"series_id":"abc","vid":"7000000000000000106","title":"编号无效","content_type":1},
      {"series_id":"7000000000000000007","vid":"7000000000000000107","title":"  ","content_type":1}
     ]}}
    """

    private func parsed(_ text: String = AppFeedTests.fixture, after cursor: AppFeedCursor = .first) throws -> AppFeedPage {
        try AppFeed.parse(JSONValue.parse(text), after: cursor)
    }

    func testKeepsOnlyPlayableShortDramasOnce() throws {
        let page = try parsed()
        XCTAssertEqual(page.entries.map(\.series.seriesId), ["7000000000000000001", "7000000000000000002"])
    }

    func testReadsFieldsOfALiveActionRow() throws {
        let entry = try XCTUnwrap(parsed().entries.first)
        XCTAssertEqual(entry.firstVid, "7000000000000000101")
        XCTAssertEqual(entry.series.title, "示例真人剧 第一部")
        XCTAssertEqual(entry.series.episodeCount, 96)
        XCTAssertEqual(entry.series.episodeLabel, "全96集")
        XCTAssertEqual(entry.series.tags, ["第3季", "家庭"])
        XCTAssertEqual(entry.series.heat, "7031万")
        XCTAssertEqual(entry.series.description, "示例简介 第一行 第二行")
        XCTAssertEqual(entry.commentCount, 12)
        XCTAssertEqual(entry.playCount, 18_279_659)
        XCTAssertTrue(entry.isVertical)
        // The signed HEIC address is replaced by the public JPEG variant, without the signature.
        XCTAssertEqual(entry.series.cover, "https://p3-novel.byteimg.com/novel-pic/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~tplv-shrink:640:0.image")
    }

    func testAcceptsNumbersSentAsStringsAndNumericIds() throws {
        let entry = try XCTUnwrap(parsed().entries.last)
        XCTAssertEqual(entry.series.seriesId, "7000000000000000002")
        XCTAssertEqual(entry.series.episodeCount, 76)
        XCTAssertEqual(entry.commentCount, 0)
        XCTAssertEqual(entry.playCount, 7331)
        XCTAssertFalse(entry.isVertical)
        XCTAssertEqual(entry.series.tags, [])
        XCTAssertEqual(entry.series.heat, "1489万")
    }

    func testCursorAdvancesOnlyWhenTheServiceSaysThereIsMore() throws {
        XCTAssertEqual(try parsed().next, AppFeedCursor(offset: 15, sessionId: "fixture-session-0001"))
        // Asking from offset 15 and being told "next is 15" would loop forever.
        XCTAssertNil(try parsed(after: AppFeedCursor(offset: 15, sessionId: "x")).next)
        let ended = AppFeedTests.fixture.replacingOccurrences(of: "\"has_more\":true", with: "\"has_more\":false")
        XCTAssertNil(try parsed(ended).next)
        let noSession = AppFeedTests.fixture.replacingOccurrences(of: "fixture-session-0001", with: "")
        XCTAssertNil(try parsed(noSession).next)
    }

    func testRejectsErrorsAndBrokenShapes() {
        XCTAssertThrowsError(try parsed("{\"code\":10001,\"data\":{\"video_data\":[]}}"))
        XCTAssertThrowsError(try parsed("{\"code\":0,\"data\":{}}"))
        XCTAssertThrowsError(try parsed("[]"))
    }
}

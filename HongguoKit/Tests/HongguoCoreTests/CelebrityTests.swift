import XCTest
@testable import HongguoCore

/// The fixture has the shape of the official app's actor works reply, cut down to the fields the
/// parser reads. Ids, names and numbers are made up.
final class CelebrityTests: XCTestCase {
    static let reply = #"""
    {"code":0,"message":"SUCCESS","data":{"works":{
      "enc_a":{"has_more":false,"total_count":37,"video_list":[
        {"series_id":7400000000000000101,"vid":"7400000000000000201","title":"作品甲","cover":"http://p3-novel.byteimg.com/a.jpg",
         "episode_cnt":0,"sub_title":"时空之旅·102集","play_cnt":60814291,"score":"8.1","content_type":1},
        {"series_id":"7400000000000000102","title":"作品乙","cover":"https://x.example/b.jpg","episode_cnt":12,"sub_title":"都市","play_cnt":5300},
        {"series_id":"7400000000000000103","title":"作品丙","sub_title":"全80集","play_cnt":230000000},
        {"series_id":"7400000000000000101","title":"作品甲"},
        {"series_id":"","title":"无编号"}]},
      "enc_b":{"has_more":false,"total_count":0,"video_list":[]}}}}
    """#

    func testParsesWorksPerActor() throws {
        let works = try CelebrityService.parse(try JSONValue.parse(Self.reply))
        let first = try XCTUnwrap(works["enc_a"])
        XCTAssertEqual(first.items.map(\.title), ["作品甲", "作品乙", "作品丙"], "duplicates and entries without an id are dropped")
        XCTAssertEqual(first.items.map(\.seriesId), ["7400000000000000101", "7400000000000000102", "7400000000000000103"], "19-digit ids stay exact")
        XCTAssertEqual(first.items[0].cover, "https://p3-novel.byteimg.com/a.jpg")
        XCTAssertEqual(first.items.map(\.episodeCount), [102, 12, 80], "the subtitle's count stands in for an episode_cnt of 0")
        XCTAssertEqual(first.items.map(\.tags), [["时空之旅"], ["都市"], []])
        XCTAssertEqual(first.items.map(\.heat), ["6081万播放", "5300播放", "2.3亿播放"])
        XCTAssertEqual(first.items[0].completionStatus, .unknown, "cards say nothing about completion")
        XCTAssertEqual(first.total, 37)
        let second = try XCTUnwrap(works["enc_b"])
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertEqual(second.total, 0)

        XCTAssertThrowsError(try CelebrityService.parse(try JSONValue.parse(#"{"code":100103,"message":"PARAM_INVALID"}"#)))
    }

    func testSubtitleSplitsGenreAndEpisodes() {
        XCTAssertEqual(CelebrityService.subtitle("时空之旅·102集").genre, "时空之旅")
        XCTAssertEqual(CelebrityService.subtitle("时空之旅·102集").episodes, 102)
        XCTAssertEqual(CelebrityService.subtitle("102集·逆袭").genre, "逆袭")
        XCTAssertNil(CelebrityService.subtitle("").episodes)
        XCTAssertEqual(CelebrityService.subtitle(nil).genre, "")
        XCTAssertEqual(CelebrityService.plays(0), "")
        XCTAssertEqual(CelebrityService.plays(nil), "")
    }

    func testAnActorWithoutAnEncryptedIdHasNoWorksToAskFor() async {
        let member = EpisodeSocial.CastMember(id: "9001", name: "示例演员", role: "饰 主角", avatar: "")
        do {
            _ = try await CelebrityService.works(of: member)
            XCTFail("expected an error")
        } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .unavailable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

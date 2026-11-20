import XCTest
@testable import HongguoCore

/// The fixture has the shape of the official app's actor works reply, cut down to the fields the
/// parser reads. Ids, names and numbers are made up.
final class CelebrityTests: XCTestCase {
    static let reply = #"""
    {"code":0,"message":"SUCCESS","data":{"works":{
      "enc_a":{"has_more":true,"total_count":37,"video_list":[
        {"series_id":7400000000000000101,"title":"作品甲","cover":"http://p3-novel.byteimg.com/a.jpg","episode_cnt":80,
         "episode_right_text":"全80集","sub_title_list":[{"content":"全80集"},{"content":"4210万热度","data_type":27}]},
        {"series_id":"7400000000000000102","video_detail":{"series_title":"作品乙","series_cover":"https://x.example/b.jpg","episode_cnt":12}},
        {"series_id":"7400000000000000101","title":"作品甲"},
        {"series_id":"","title":"无编号"}]},
      "enc_b":{"has_more":false,"total_count":0,"video_list":[]}}}}
    """#

    func testParsesWorksPerActor() throws {
        let works = try CelebrityService.parse(try JSONValue.parse(Self.reply))
        let first = try XCTUnwrap(works["enc_a"])
        XCTAssertEqual(first.items.map(\.title), ["作品甲", "作品乙"], "duplicates and entries without an id are dropped")
        XCTAssertEqual(first.items.map(\.seriesId), ["7400000000000000101", "7400000000000000102"], "19-digit ids stay exact")
        XCTAssertEqual(first.items[0].cover, "https://p3-novel.byteimg.com/a.jpg")
        XCTAssertEqual(first.items[0].heat, "4210万热度")
        XCTAssertEqual(first.items[0].episodeLabel, "全80集")
        XCTAssertEqual(first.items[0].completionStatus, .completed)
        XCTAssertEqual(first.items[1].episodeCount, 12, "the nested detail stands in for missing card fields")
        XCTAssertEqual(first.total, 37)
        XCTAssertTrue(first.hasMore)
        let second = try XCTUnwrap(works["enc_b"])
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertFalse(second.hasMore)

        XCTAssertThrowsError(try CelebrityService.parse(try JSONValue.parse(#"{"code":100103,"message":"PARAM_INVALID"}"#)))
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

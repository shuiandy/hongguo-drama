// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

final class OfficialAlbumDetailTests: XCTestCase {
    private func listing() throws -> JSONValue {
        try JSONValue.parse("""
        {"code":0,"data":{"album_data":{"album_id":7695396523919559704,"album_id_str":"7695396523919559704","title":"家庭恶报",
         "intro":"家庭恶报 ","episode_cnt":3,"followed_cnt":8,"sub_title_list":["全3集"],"cover":"https://p3-novel.byteimg.com/novel-pic/a~tplv-x.heic",
         "video_detail_list":[
          {"content_type":1001,"series_id":7695396503975627838,"series_id_str":"7695396503975627838","series_title":"家庭恶报01","video_list":[{"vid":""}]},
          {"content_type":1001,"series_id_str":"7695397014699248702","series_title":"家庭恶报01","video_list":[{"vid":""}]},
          {"content_type":1001,"series_id_str":"7695397021397568537","series_title":"家庭恶报02","video_list":[{"vid":"","disable_play":true}]}]}}}
        """)
    }

    func testParsesCollectionInListOrder() throws {
        let json = try listing()
        XCTAssertEqual(OfficialAlbumDetail.itemIds(json), ["7695396503975627838", "7695397014699248702", "7695397021397568537"])
        let details: [String: JSONValue] = [
            "7695396503975627838": try JSONValue.parse(#"{"video_data":{"video_list":[{"vid":"7695396503975627838","digged_count":2}]}}"#),
        ]
        let detail = try OfficialAlbumDetail.parse(json, details: details, albumId: "7695396523919559704")
        XCTAssertEqual(detail.title, "家庭恶报")
        XCTAssertEqual(detail.episodeCount, 3)
        XCTAssertEqual(detail.completion, .completed)
        XCTAssertEqual(detail.episodes.map(\.index), [1, 2, 3])
        XCTAssertEqual(detail.episodes.map(\.title), ["家庭恶报01", "家庭恶报01", "家庭恶报02"])
        XCTAssertEqual(detail.episodes[0].likes, 2)
        XCTAssertEqual(detail.episodes[1].vid, "7695397014699248702")
        XCTAssertTrue(detail.episodes[2].disabled)
    }

    func testRejectsOtherCollection() throws {
        XCTAssertThrowsError(try OfficialAlbumDetail.parse(try listing(), details: [:], albumId: "123456789"))
    }

    func testModelPayloadKeysCollectionVideos() throws {
        UGCVideos.insert(["7695396503975627838"])
        let payload = try JSONValue.parse(String(decoding: try AppSource.modelPayload(vids: ["7709806267153255448", "7695396503975627838"]), as: UTF8.self))
        XCTAssertEqual(payload["mixed_video_id_map"]["1004"].array?.compactMap(\.string), ["7709806267153255448"])
        XCTAssertEqual(payload["mixed_video_id_map"]["1001"].array?.compactMap(\.string), ["7695396503975627838"])
    }
}

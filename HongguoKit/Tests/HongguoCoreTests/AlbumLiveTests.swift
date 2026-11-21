// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `HONGGUO_LIVE=1 swift test --filter AlbumLiveTests` (optional `HONGGUO_ALBUM=<collection id>`):
/// a creator's collection loads as a series (album_detail), its first video plays under model key
/// 1001 and the media answers; a normal series still loads its own episode list. Read-only.
final class AlbumLiveTests: XCTestCase {
    func testCollectionPlays() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let albumId = env["HONGGUO_ALBUM"] ?? "7695396523919559704" // 家庭恶报 by 羿仔说剧
        let service = SeriesService()
        let list = try await service.episodes(seriesId: albumId, force: true)
        print("ALBUM \(list.title) eps=\(list.episodes.count) first=\(list.episodes.prefix(3).map { "\($0.index):\($0.title):\($0.vid)" })")
        XCTAssertGreaterThan(list.episodes.count, 1)
        XCTAssertEqual(list.episodes.map(\.index), Array(1...list.episodes.count))
        for episode in [list.episodes[0], list.episodes[list.episodes.count - 1]] {
            let info = try await service.playInfo(vid: episode.vid, seriesId: albumId, force: true)
            var request = URLRequest(url: info.url)
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            request.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let box = data.count >= 8 ? String(decoding: data[4..<8], as: UTF8.self) : ""
            print("PLAY ep\(episode.index) codec=\(info.codec) status=\(status) bytes=\(data.count) box=\(box) encrypted=\(info.contentKey != nil || info.spadeA != nil)")
            XCTAssertTrue([200, 206].contains(status))
            XCTAssertEqual(box, "ftyp")
        }
    }

    func testSeriesUnchanged() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let list = try await SeriesService().episodes(seriesId: "7709803199372217368", force: true) // 她的花开
        XCTAssertEqual(list.episodes.count, 49)
        let info = try await SeriesService().playInfo(vid: list.episodes[3].vid, seriesId: list.seriesId, force: true)
        print("SERIES \(list.title) eps=\(list.episodes.count) ep4 codec=\(info.codec)")
    }
}

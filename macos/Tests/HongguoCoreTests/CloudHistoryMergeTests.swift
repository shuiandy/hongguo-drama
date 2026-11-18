import XCTest
@testable import HongguoCore

final class CloudHistoryMergeTests: XCTestCase {
    func item(_ id: String, index: Int, position: Double, at seconds: TimeInterval, title: String = "云端剧") -> AccountHistoryItem {
        AccountHistoryItem(seriesId: id, seriesTitle: title, cover: "https://img.example.com/\(id).jpg", episodeId: "9\(id)\(index)",
                           episodeIndex: index, position: position, duration: 90, updatedAt: Date(timeIntervalSince1970: seconds), total: 40)
    }

    func testNewerSideWinsPerSeries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        store.savePosition(seriesId: "101", title: "本地新", cover: "", total: 10, episodeIndex: 5, vid: "v5", position: 30, duration: 90, finished: false)
        store.savePosition(seriesId: "102", title: "本地旧", cover: "c", total: 10, episodeIndex: 2, vid: "v2", position: 10, duration: 90, finished: false)
        store.updateRecord("102") { var r = $0; r.updatedAt = Date(timeIntervalSince1970: 1_000); return r }

        let changed = store.mergeCloudHistory([
            item("101", index: 3, position: 5, at: 2_000),          // older than the local record: only fills gaps
            item("102", index: 7, position: 44, at: 5_000),         // newer: moves local forward
            item("103", index: 0, position: 60, at: 3_000, title: "新剧"), // unknown episode: start at 1
        ])
        XCTAssertEqual(changed, 2)
        let a = try XCTUnwrap(store.record(for: "101"))
        XCTAssertEqual(a.episodeIndex, 5)
        XCTAssertEqual(a.position, 30)
        XCTAssertEqual(a.cover, "https://img.example.com/101.jpg")
        XCTAssertEqual(a.total, 40)
        let b = try XCTUnwrap(store.record(for: "102"))
        XCTAssertEqual(b.episodeIndex, 7)
        XCTAssertEqual(b.vid, "91027")
        XCTAssertEqual(b.position, 44)
        XCTAssertEqual(b.title, "云端剧")
        XCTAssertEqual(b.updatedAt, Date(timeIntervalSince1970: 5_000))
        let c = try XCTUnwrap(store.record(for: "103"))
        XCTAssertEqual(c.episodeIndex, 1)
        XCTAssertEqual(c.position, 0)
        XCTAssertEqual(store.history().map(\.seriesId), ["101", "102", "103"])
        XCTAssertEqual(store.mergeCloudHistory([item("102", index: 7, position: 44, at: 5_000)]), 0, "merging again changes nothing")
    }
}

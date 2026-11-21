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

    func testSwitchThenLogoutKeepsGuestHistory() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        store.savePosition(seriesId: "100", title: "本机", cover: "", total: 3, episodeIndex: 1,
                           vid: "1001", position: 5, duration: 30, finished: false)
        store.mergeCloudHistory([item("101", index: 1, position: 8, at: 100)], accountId: "a")
        store.mergeCloudHistory([item("102", index: 2, position: 9, at: 200)], accountId: "b")
        store.clearCloudHistory(exceptAccountId: "b")
        XCTAssertNil(store.record(for: "101"))
        XCTAssertEqual(store.record(for: "102")?.cloudAccountId, "b")
        store.clearCloudHistory()
        XCTAssertEqual(store.history().map(\.seriesId), ["100"])
        XCTAssertEqual(LibraryStore(directory: directory).history().map(\.seriesId), ["100"])
    }

}

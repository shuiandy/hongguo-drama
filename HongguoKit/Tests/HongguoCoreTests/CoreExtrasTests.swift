import XCTest
@testable import HongguoCore

final class ReleaseCheckTests: XCTestCase {
    func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> JSONValue {
        .object(["tag_name": .string(tag), "draft": .bool(draft), "prerelease": .bool(prerelease),
                 "html_url": .string("https://evil.example.com")])
    }

    func testAvailableRelease() {
        XCTAssertEqual(UpdateChecker.availableRelease(release("v0.2.0"), currentVersion: "0.1.0"),
                       AvailableRelease(version: "0.2", url: URL(string: "https://github.com/shuiandy/hongguo-drama/releases/tag/v0.2.0")!))
        XCTAssertEqual(UpdateChecker.availableRelease(release("v1.2.3"), currentVersion: "1.2")?.version, "1.2.3")
        XCTAssertNil(UpdateChecker.availableRelease(release("v0.1.0"), currentVersion: "0.1.0"))
        XCTAssertNil(UpdateChecker.availableRelease(release("v0.0.9"), currentVersion: "0.1.0"))
        XCTAssertNil(UpdateChecker.availableRelease(release("v9.0.0", draft: true), currentVersion: "0.1.0"))
        XCTAssertNil(UpdateChecker.availableRelease(release("v9.0.0", prerelease: true), currentVersion: "0.1.0"))
        XCTAssertNil(UpdateChecker.availableRelease(release("nightly"), currentVersion: "0.1.0"))
    }

    func body(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testAnnouncementSchema() {
        let good = body(["id": "a-1", "title": "标题", "body": "第一行\n第二行", "active": true])
        XCTAssertEqual(AnnouncementService.parse(status: 200, contentType: "text/plain; charset=utf-8", body: good, urgent: false)?.title, "标题")
        XCTAssertNil(AnnouncementService.parse(status: 200, contentType: "text/html", body: good, urgent: false))
        XCTAssertNil(AnnouncementService.parse(status: 200, contentType: "application/json",
                                               body: body(["id": "a-1", "title": "t", "body": "b", "active": false]), urgent: false))
        XCTAssertNil(AnnouncementService.parse(status: 200, contentType: "application/json",
                                               body: body(["id": "a-1", "title": "<b>t</b>", "body": "b", "active": true]), urgent: false))
        XCTAssertNil(AnnouncementService.parse(status: 200, contentType: "application/json",
                                               body: body(["id": "a-1", "title": "t", "body": "b", "active": true, "url": "x"]), urgent: false))
        XCTAssertNil(AnnouncementService.parse(status: 200, contentType: "application/json",
                                               body: body(["id": "a-1", "title": "两\n行", "body": "b", "active": true]), urgent: false))
    }

    func testEmergencyShownUntilAcknowledgedAndNormalMute() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ann-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let emergency = body(["id": "e-1", "title": "紧急", "body": "请更新", "active": true])
        let normal = body(["id": "n-1", "title": "普通", "body": "说明", "active": true])
        let fetch: @Sendable (URL) async throws -> (status: Int, contentType: String, body: Data) = { url in
            (200, "application/json", url.lastPathComponent == "emergency.json" ? emergency : normal)
        }
        let clock = TestClock()
        let service = AnnouncementService(version: "0.1.0", store: JSONFileStore(directory: dir, name: "a.json"),
                                          now: { clock.now }, fetch: fetch)
        let first = await service.check()
        XCTAssertEqual(first?.id, "e-1")
        try await service.acknowledge("e-1")
        let second = await service.check()
        XCTAssertEqual(second?.id, "n-1")
        try await service.mute(.version)
        let third = await service.check()
        XCTAssertNil(third)
        let reloaded = AnnouncementService(version: "0.1.0", store: JSONFileStore(directory: dir, name: "a.json"), now: { clock.now }, fetch: fetch)
        let afterRestart = await reloaded.check()
        XCTAssertNil(afterRestart, "read emergency and muted normal stay quiet after restart")
        let newVersion = AnnouncementService(version: "0.2.0", store: JSONFileStore(directory: dir, name: "a.json"), now: { clock.now }, fetch: fetch)
        let afterUpdate = await newVersion.check()
        XCTAssertEqual(afterUpdate?.id, "n-1", "a version mute ends with the next version")
    }
}

final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

final class WatchUpdateCheckerTests: XCTestCase {
    func testChecksDueRecordsAndFindsSequels() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        store.savePosition(seriesId: "7200000000000000001", title: "霸总归来", cover: "", total: 10, episodeIndex: 3,
                           vid: "v", position: 10, duration: 90, finished: false)
        store.savePosition(seriesId: "7200000000000000005", title: "别的剧", cover: "", total: 20, episodeIndex: 1,
                           vid: "v", position: 10, duration: 90, finished: false)
        let clock = TestClock()
        let checker = WatchUpdateChecker(store: store, episodeCount: { id in
            if id == "7200000000000000005" { throw HongguoError(.network, "down") }
            return 12
        }, searchCandidates: { keyword in
            XCTAssertTrue(["霸总归来", "别的剧"].contains(keyword))
            return [SeriesRef(seriesId: "7200000000000000002", title: "霸总归来第二季")]
        }, now: { clock.now })
        let summary = await checker.refresh()
        XCTAssertEqual(summary.checked, 2)
        XCTAssertEqual(summary.withUpdates, 1)
        XCTAssertEqual(summary.failed, 1)
        let record = try XCTUnwrap(store.record(for: "7200000000000000001"))
        XCTAssertEqual(record.unreadEpisodes, 2)
        XCTAssertEqual(record.unreadSequelIds, ["7200000000000000002"])
        XCTAssertEqual(store.record(for: "7200000000000000005")?.lastCheckError, "分集更新检查失败")
        // Nothing is due an hour later.
        clock.now = clock.now.addingTimeInterval(3600)
        let again = await checker.refresh()
        XCTAssertEqual(again.checked, 0)
        XCTAssertFalse(WatchUpdateChecker.isDue(record, now: clock.now))
    }
}

final class ElectronImportTests: XCTestCase {
    func testParsesElectronDataFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ei-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let video = dir.appendingPathComponent("ep1.mp4")
        try Data("video".utf8).write(to: video)
        let data: [String: Any] = [
            "settings": ["root": "/Users/x/Downloads", "name_format": "剧名 集数 标题", "max_concurrent": 5,
                         "auto_delete_watched": true, "proxy_password_ciphertext": "secret"],
            "series": [["series_id": "7200000000000000001", "series_title": "霸总归来", "cover": "https://p3.example.com/c.jpg",
                        "total": 60, "updatedAt": 1_700_000_000_000,
                        "episodes": [["vid": "7300000000000000003", "vid_index": 3]]]],
            "playback": ["7200000000000000001": ["vid_index": 3, "currentTime": 42.5, "updatedAt": 1_700_000_100_000,
                                                 "watched": true, "knownTotal": 62, "acknowledgedTotal": 60,
                                                 "sequels": [["series_id": "7200000000000000002", "series_title": "霸总归来第二季"]]],
                         "bad": ["vid_index": 0]],
            "tasks": [["status": "completed", "savePath": video.path, "startTime": 1_700_000_000_000,
                       "hongguoInfo": ["vid": "7300000000000000001", "series_id": "7200000000000000001",
                                       "series_title": "霸总归来", "vid_index": 1]],
                      ["status": "failed", "savePath": "/nope.mp4"]],
        ]
        let file = dir.appendingPathComponent("data.json")
        try JSONSerialization.data(withJSONObject: data).write(to: file)
        let result = try ElectronImport.read(file)
        XCTAssertEqual(result.series.map(\.title), ["霸总归来"])
        XCTAssertEqual(result.series.first?.episodeCount, 60)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.episodeIndex, 3)
        XCTAssertEqual(record.vid, "7300000000000000003")
        XCTAssertEqual(record.position, 42.5)
        XCTAssertEqual(record.total, 62)
        XCTAssertEqual(record.unreadEpisodes, 2)
        XCTAssertEqual(record.sequels?.first?.seriesId, "7200000000000000002")
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.downloads.map(\.vid), ["7300000000000000001"])
        XCTAssertEqual(result.settings?.downloadRoot, "/Users/x/Downloads")
        XCTAssertEqual(result.settings?.maxConcurrentDownloads, 5)
        XCTAssertEqual(result.settings?.autoDeleteWatched, true)
        XCTAssertEqual(result.settings?.downloadNameFormat, "剧名 集数 标题")
    }

    func testApplyKeepsNewerNativeData() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ea-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        store.savePosition(seriesId: "7200000000000000001", title: "新", cover: "", total: 10, episodeIndex: 9,
                           vid: "v", position: 1, duration: 90, finished: false)
        let older = WatchRecord(seriesId: "7200000000000000001", title: "旧", cover: "", total: 10, episodeIndex: 2, vid: "v",
                                position: 1, duration: 0, updatedAt: Date(timeIntervalSince1970: 1), completedEpisode: 0)
        let other = WatchRecord(seriesId: "7200000000000000002", title: "另", cover: "", total: 10, episodeIndex: 2, vid: "v",
                                position: 1, duration: 0, updatedAt: Date(timeIntervalSince1970: 1), completedEpisode: 0)
        var result = ElectronImport.Result()
        result.records = [older, other]
        let library = SeriesLibrary(directory: dir)
        let counts = try await ElectronImport.apply(result, store: store, library: library, applySettings: false)
        XCTAssertEqual(counts.records, 1)
        XCTAssertEqual(store.record(for: "7200000000000000001")?.episodeIndex, 9)
        XCTAssertEqual(store.record(for: "7200000000000000002")?.title, "另")
    }
}

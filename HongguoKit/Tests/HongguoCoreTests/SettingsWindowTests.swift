import XCTest
@testable import HongguoCore

/// Settings added with the settings window redesign: defaults, old files, clamping, and the
/// behaviour they drive in the core (cache cap, check interval, default picture mode).
final class SettingsWindowTests: XCTestCase {
    func testOldFileGetsDefaultsForNewSettings() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"dark","autoNext":false}"#.utf8))
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertEqual(settings.startPage, "last")
        XCTAssertNil(settings.lastPage)
        XCTAssertEqual(settings.playbackCacheLimitGB, 5)
        XCTAssertEqual(settings.defaultPictureMode, .fit)
        XCTAssertNil(settings.startVolume)
        XCTAssertEqual(settings.watchCheckHours, 6)
        XCTAssertFalse(settings.watchNotifications)
        XCTAssertTrue(settings.checkUpdatesAtLaunch)
        XCTAssertFalse(settings.autoExportText)
        XCTAssertTrue(settings.cloudHistorySync)
    }

    func testNewSettingsRoundTripAndClamp() throws {
        var settings = AppSettings()
        settings.startPage = "history"
        settings.lastPage = "ranking:real-drama"
        settings.playbackCacheLimitGB = 10
        settings.defaultPictureMode = .width
        settings.startVolume = 25
        settings.watchCheckHours = 12
        settings.watchNotifications = true
        settings.checkUpdatesAtLaunch = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)

        let bad = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"startPage":"nowhere","playbackCacheLimitGB":-3,"startVolume":250,"watchCheckHours":0}"#.utf8))
        XCTAssertEqual(bad.startPage, "last")
        XCTAssertEqual(bad.playbackCacheLimitGB, 0)
        XCTAssertEqual(bad.startVolume, 100)
        XCTAssertEqual(bad.watchCheckHours, 1)
    }

    func testDefaultPictureModeAppliesOnlyWithoutRememberedMode() {
        var settings = AppSettings()
        settings.defaultPictureMode = .width
        settings.pictureModes["7200000000000000001"] = .fit
        XCTAssertEqual(settings.pictureMode(for: "7200000000000000001"), .fit)
        XCTAssertEqual(settings.pictureMode(for: "7200000000000000002"), .width)
    }

    func testCheckIntervalFollowsSetting() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var record = WatchRecord(seriesId: "7200000000000000001", title: "甲", cover: "", total: 60, episodeIndex: 3, vid: "v",
                                 position: 1, duration: 90, updatedAt: now, completedEpisode: 2)
        record.lastCheckedAt = now.addingTimeInterval(-2 * 3600)
        XCTAssertTrue(WatchUpdateChecker.isDue(record, now: now, every: 3600))
        XCTAssertFalse(WatchUpdateChecker.isDue(record, now: now, every: 3 * 3600))
        XCTAssertFalse(WatchUpdateChecker.isDue(record, now: now))
        // Finished series wait at least a day whatever the setting.
        record.completedEpisode = 60
        record.lastCheckedAt = now.addingTimeInterval(-5 * 3600)
        XCTAssertFalse(WatchUpdateChecker.isDue(record, now: now, every: 3600))
    }

    func testCacheLimitRemovesOldestFilesButKeepsNewest() throws {
        // Its own temporary folder: never the real playback cache.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PlaybackCache(maxFiles: 12, directory: dir)
        let names = (0..<3).map { "\($0).mp4" }
        for (offset, name) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            try Data(count: 1000).write(to: url)
            // Newest last: offset 2 is the most recent.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(offset) * 10 + 3600)],
                                                  ofItemAtPath: url.path)
        }
        cache.setLimit(bytes: 1500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(names[2]).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(names[1]).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(names[0]).path))
    }
}

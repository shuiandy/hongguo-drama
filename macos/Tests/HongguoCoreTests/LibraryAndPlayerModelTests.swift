import XCTest
@testable import HongguoCore

final class SeriesLibraryTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testFavoritesLikesAndPersistence() throws {
        let library = SeriesLibrary(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try library.recordOpened(seriesId: "7200000000000000001", title: "甲", cover: "https://p3.example.com/a.jpg", episodeCount: 60, now: t0)
        try library.recordOpened(seriesId: "7200000000000000002", title: "乙", now: t0.addingTimeInterval(10))
        XCTAssertEqual(library.recent().map(\.title), ["乙", "甲"])
        XCTAssertTrue(try library.toggleFavorite(seriesId: "7200000000000000001", title: "甲"))
        XCTAssertEqual(library.favorites().map(\.title), ["甲"])
        XCTAssertTrue(try library.toggleEpisodeLike(seriesId: "7200000000000000001", title: "甲", vid: "v1"))
        XCTAssertFalse(try library.toggleEpisodeLike(seriesId: "7200000000000000001", title: "甲", vid: "v1"))
        // Opening again keeps the favourite and never blanks known metadata.
        try library.recordOpened(seriesId: "7200000000000000001", title: "", cover: "", episodeCount: 0, now: t0.addingTimeInterval(20))
        let reloaded = SeriesLibrary(directory: dir)
        let item = try XCTUnwrap(reloaded.series("7200000000000000001"))
        XCTAssertTrue(item.favorite)
        XCTAssertEqual(item.title, "甲")
        XCTAssertEqual(item.cover, "https://p3.example.com/a.jpg")
        XCTAssertEqual(item.episodeCount, 60)
        XCTAssertEqual(reloaded.recent().first?.seriesId, "7200000000000000001")
        try reloaded.remove("7200000000000000002")
        XCTAssertNil(SeriesLibrary(directory: dir).series("7200000000000000002"))
    }

    func testRejectsMissingTitleAndPrivateCover() throws {
        let library = SeriesLibrary(directory: dir)
        XCTAssertThrowsError(try library.recordOpened(seriesId: "1", title: "  "))
        try library.recordOpened(seriesId: "7200000000000000003", title: "丙", cover: "http://192.168.1.2/x.jpg")
        XCTAssertEqual(library.series("7200000000000000003")?.cover, "")
    }

    func testCalendarUsesBeijingDate() throws {
        let library = SeriesLibrary(directory: dir)
        // 2026-03-31 17:00 UTC is 2026-04-01 in Beijing.
        try library.recordOpened(seriesId: "7200000000000000004", title: "丁", publishedAt: Date(timeIntervalSince1970: 1_774_976_400))
        try library.recordOpened(seriesId: "7200000000000000005", title: "戊")
        let months = library.calendar()
        XCTAssertEqual(months.map(\.month), ["2026-04"])
        XCTAssertEqual(months.first?.series.first?.publicDateKey, "2026-04-01")
    }
}

final class WatchHistoryTests: XCTestCase {
    func testSeasonTitles() {
        XCTAssertEqual(WatchHistory.seasonTitle("霸总归来第二季"), .init(base: "霸总归来", season: 2, explicit: true))
        XCTAssertEqual(WatchHistory.seasonTitle("霸总归来（3）"), .init(base: "霸总归来", season: 3, explicit: true))
        XCTAssertEqual(WatchHistory.seasonTitle("霸总归来 第十二部"), .init(base: "霸总归来", season: 12, explicit: true))
        XCTAssertEqual(WatchHistory.seasonTitle("Hero Season 4"), .init(base: "hero", season: 4, explicit: true))
        XCTAssertEqual(WatchHistory.seasonTitle("年代剧(2024)"), .init(base: "年代剧(2024)", season: 1, explicit: false))
        XCTAssertEqual(WatchHistory.seasonTitle("霸总归来"), .init(base: "霸总归来", season: 1, explicit: false))
        XCTAssertEqual(WatchHistory.seasonTitle("剧名第零季").invalid, true)
    }

    func testSequelsAndSimilar() {
        let current = SeriesRef(seriesId: "7200000000000000001", title: "霸总归来")
        let candidates = [
            SeriesRef(seriesId: "7200000000000000003", title: "霸总归来第三季"),
            SeriesRef(seriesId: "7200000000000000002", title: "霸总归来第二季"),
            SeriesRef(seriesId: "7200000000000000009", title: "别的剧第二季"),
            SeriesRef(seriesId: "xifan:a:b", title: "霸总归来第四季"),
        ]
        XCTAssertEqual(WatchHistory.findSequels(of: current, in: candidates).map(\.title), ["霸总归来第二季", "霸总归来第三季"])
        XCTAssertEqual(WatchHistory.findSequels(of: current, in: candidates, afterSeason: 2).map(\.title), ["霸总归来第三季"])
        let similar = WatchHistory.findSimilar(to: SeriesRef(seriesId: "7200000000000000001", title: "战神归来之龙王"),
                                               in: [SeriesRef(seriesId: "7200000000000000005", title: "战神归来之龙帝"),
                                                    SeriesRef(seriesId: "7200000000000000006", title: "完全不同的剧名")])
        XCTAssertEqual(similar.map(\.seriesId), ["7200000000000000005"])
    }

    func record(index: Int = 3, position: Double = 30, duration: Double = 90, total: Int = 10) -> WatchRecord {
        WatchRecord(seriesId: "7200000000000000001", title: "甲", cover: "", total: total, episodeIndex: index, vid: "v",
                    position: position, duration: duration, updatedAt: Date(), completedEpisode: 0)
    }

    func testResumePoint() {
        XCTAssertEqual(ResumePoint.from(nil, episodeCount: 10), ResumePoint(episodeIndex: 1, position: 0))
        XCTAssertEqual(ResumePoint.from(record(), episodeCount: 10), ResumePoint(episodeIndex: 3, position: 30))
        XCTAssertEqual(ResumePoint.from(record(position: 88.5), episodeCount: 10), ResumePoint(episodeIndex: 4, position: 0))
        XCTAssertEqual(ResumePoint.from(record(index: 10, position: 89), episodeCount: 10), ResumePoint(episodeIndex: 10, position: 0))
        XCTAssertTrue(ResumePoint.shouldSeek(to: 30, duration: 90))
        XCTAssertFalse(ResumePoint.shouldSeek(to: 88, duration: 90))
        XCTAssertFalse(ResumePoint.shouldSeek(to: 0, duration: nil))
    }

    func testEpisodeUpdatesAndAcknowledge() {
        var r = record(total: 10)
        r = r.applyingEpisodeUpdate(freshTotal: 12)
        XCTAssertEqual(r.unreadEpisodes, 2)
        r = r.applyingEpisodeUpdate(freshTotal: 8)
        XCTAssertEqual(r.knownTotal, 12, "a slower, shorter refresh never rolls back")
        r = r.applyingSequels([SeriesRef(seriesId: "7200000000000000002", title: "甲第二季")])
        XCTAssertTrue(r.hasUpdates)
        r = r.acknowledging(visibleTotal: 11, sequelIds: [])
        XCTAssertEqual(r.unreadEpisodes, 1)
        XCTAssertEqual(r.unreadSequelIds, ["7200000000000000002"])
        r = r.acknowledging()
        XCTAssertFalse(r.hasUpdates)
    }

    func testOldLibraryFileStillDecodes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = #"{"version":1,"history":{"7200000000000000001":{"seriesId":"7200000000000000001","title":"甲","cover":"","total":10,"episodeIndex":2,"vid":"v","position":12,"duration":90,"updatedAt":1700000000000,"completedEpisode":1}},"settings":{"theme":"dark","playbackRate":9}}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: dir)
        XCTAssertEqual(store.record(for: "7200000000000000001")?.episodeIndex, 2)
        XCTAssertNil(store.record(for: "7200000000000000001")?.knownTotal)
        XCTAssertEqual(store.settings.theme, .dark)
        XCTAssertEqual(store.settings.playbackRate, 4, "out-of-range rate is clamped")
        XCTAssertEqual(store.settings.maxConcurrentDownloads, 3)
        XCTAssertEqual(store.settings.danmaku, DanmakuSettings())
        let updated = store.updateRecord("7200000000000000001") { $0.applyingEpisodeUpdate(freshTotal: 15) }
        XCTAssertEqual(updated?.unreadEpisodes, 5)
        XCTAssertEqual(store.resumePoint(for: "7200000000000000001", episodeCount: 15), ResumePoint(episodeIndex: 2, position: 12))
    }
}

final class PlayerModelTests: XCTestCase {
    func testRates() {
        XCTAssertEqual(PlaybackRate.menuRates.count, 16)
        XCTAssertEqual(PlaybackRate.menuRates.first, 0.25)
        XCTAssertEqual(PlaybackRate.menuRates.last, 4)
        XCTAssertEqual(PlaybackRate.cycled(1), 1.25)
        XCTAssertEqual(PlaybackRate.cycled(4), 1)
        XCTAssertEqual(PlaybackRate.stepped(0.25, by: 0.25, faster: false), 0.25)
        XCTAssertEqual(PlaybackRate.stepped(3.5, by: 1, faster: true), 4)
        XCTAssertEqual(PlaybackRate.label(1), "1×")
        XCTAssertEqual(PlaybackRate.label(1.25), "1.25×")
        XCTAssertEqual(PlaybackRate.label(0.5), "0.5×")
    }

    func testVolume() {
        var v = VolumeState(level: 0.6)
        v.toggleMute()
        XCTAssertEqual(v.effective, 0)
        v.toggleMute()
        XCTAssertEqual(v.effective, 0.6)
        v.set(0)
        XCTAssertTrue(v.muted)
        v.adjust(by: VolumeState.step)
        XCTAssertFalse(v.muted)
        XCTAssertEqual(v.level, 0.05, accuracy: 0.0001)
        v.set(2)
        XCTAssertEqual(v.level, 1)
        XCTAssertEqual(v.symbolName, "speaker.wave.3.fill")
    }

    func testTimeline() {
        let t = PlaybackTimeline(position: 30, duration: 120, buffered: [0...60])
        XCTAssertEqual(t.fraction, 0.25)
        XCTAssertEqual(t.bufferedFraction, 0.5)
        XCTAssertEqual(t.time(atFraction: 0.5), 60)
        XCTAssertEqual(t.seekTarget(by: -60), 0)
        XCTAssertEqual(t.seekTarget(by: 200), 119.9, accuracy: 0.001)
        XCTAssertEqual(PlaybackTimeline.format(65), "1:05")
        XCTAssertEqual(PlaybackTimeline.format(3725), "1:02:05")
        XCTAssertEqual(t.remainingLabel, "-1:30")
        XCTAssertTrue(PlaybackTimeline(position: 119.5, duration: 120).isAtEnd)
    }

    func testPictureModeAndEpisodeCursor() {
        var settings = AppSettings()
        XCTAssertEqual(settings.pictureMode(for: "x"), .fit)
        settings.pictureModes["x"] = .width
        XCTAssertEqual(settings.pictureMode(for: "x"), .width)
        XCTAssertEqual(PictureMode.width.toggled, .fit)
        let cursor = EpisodeCursor(index: 99, count: 65)
        XCTAssertEqual(cursor.index, 65)
        XCTAssertNil(cursor.next)
        XCTAssertEqual(cursor.previous, 64)
        XCTAssertEqual(cursor.ranges(), [1...30, 31...60, 61...65])
    }

    func testSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.danmaku.opacity = 55
        settings.maxConcurrentDownloads = 5
        settings.downloadRoot = "/tmp/hg"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.downloadConfiguration.maxConcurrent, 5)
        XCTAssertEqual(decoded.downloadConfiguration.root.path, "/tmp/hg")
    }
}

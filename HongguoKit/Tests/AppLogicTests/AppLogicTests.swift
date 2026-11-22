import XCTest
@testable import AppLogic

final class FeedFlowTests: XCTestCase {
    func testClipEndAdvancesThroughFeedThenReplaysLast() {
        var flow = FeedFlow(feedCount: 3)
        XCTAssertEqual(flow.clipEnded(), .showFeedItem(1))
        XCTAssertEqual(flow.clipEnded(), .showFeedItem(2))
        XCTAssertEqual(flow.clipEnded(), .replay)
        XCTAssertEqual(flow.feedIndex, 2)
    }

    func testDelayedSkipOnlyAppliesToTheCardItWasFor() {
        var flow = FeedFlow(feedCount: 4)
        // Card 0 is unplayable; before its delayed skip runs the viewer swipes to card 1.
        XCTAssertEqual(flow.userPaged(to: 1), .showFeedItem(1))
        XCTAssertEqual(flow.skipUnplayable(fromFeedItem: 0), .none)
        XCTAssertEqual(flow.feedIndex, 1)
        // Still on the unplayable card: skipped.
        XCTAssertEqual(flow.skipUnplayable(fromFeedItem: 1), .showFeedItem(2))
    }

    func testEmptyFeedDoesNothing() {
        var flow = FeedFlow()
        XCTAssertEqual(flow.clipEnded(), .none)
        XCTAssertEqual(flow.userPaged(to: 4), .none)
        XCTAssertEqual(flow.skipUnplayable(), .none)
    }

    func testPagingClampsAndIgnoresSamePage() {
        var flow = FeedFlow(feedCount: 5)
        XCTAssertEqual(flow.userPaged(to: 9), .showFeedItem(4))
        XCTAssertEqual(flow.userPaged(to: 4), .none)
        XCTAssertEqual(flow.userPaged(to: -3), .showFeedItem(0))
    }

    func testSeriesModePlaysEpisodeByEpisodeAndFinishes() {
        var flow = FeedFlow(feedCount: 4)
        _ = flow.userPaged(to: 2)
        XCTAssertEqual(flow.enterSeries(total: 3), .playEpisode(1))
        XCTAssertTrue(flow.isSeriesMode)
        XCTAssertEqual(flow.clipEnded(), .playEpisode(2))
        XCTAssertEqual(flow.clipEnded(), .playEpisode(3))
        XCTAssertEqual(flow.clipEnded(), .seriesFinished)
        XCTAssertEqual(flow.mode, .series(episode: 3, total: 3))
    }

    func testSeriesModeIgnoresFeedPagingAndReturnsToSameItem() {
        var flow = FeedFlow(feedCount: 4)
        _ = flow.userPaged(to: 1)
        _ = flow.enterSeries(total: 80, startEpisode: 12)
        XCTAssertEqual(flow.mode, .series(episode: 12, total: 80))
        XCTAssertEqual(flow.userPaged(to: 3), .none)
        XCTAssertEqual(flow.selectEpisode(40), .playEpisode(40))
        XCTAssertEqual(flow.selectEpisode(81), .none)
        XCTAssertEqual(flow.exitSeries(), .showFeedItem(1))
        XCTAssertEqual(flow.mode, .feed)
        XCTAssertEqual(flow.exitSeries(), .none)
    }

    func testEnterSeriesClampsStartAndRejectsEmptySeries() {
        var flow = FeedFlow(feedCount: 1)
        XCTAssertEqual(flow.enterSeries(total: 0), .none)
        XCTAssertFalse(flow.isSeriesMode)
        XCTAssertEqual(flow.enterSeries(total: 5, startEpisode: 99), .playEpisode(5))
    }

    func testSkipUnplayableNeverReplays() {
        var flow = FeedFlow(feedCount: 2)
        XCTAssertEqual(flow.skipUnplayable(), .showFeedItem(1))
        XCTAssertEqual(flow.skipUnplayable(), .none)
        _ = flow.enterSeries(total: 2)
        XCTAssertEqual(flow.skipUnplayable(), .playEpisode(2))
        XCTAssertEqual(flow.skipUnplayable(), .seriesFinished)
    }

    func testRefillAndShrinkingFeed() {
        var flow = FeedFlow(feedCount: 10)
        XCTAssertFalse(flow.needsMoreItems)
        _ = flow.userPaged(to: 7)
        XCTAssertTrue(flow.needsMoreItems)
        flow.setFeedCount(20)
        XCTAssertFalse(flow.needsMoreItems)
        flow.setFeedCount(3)
        XCTAssertEqual(flow.feedIndex, 2)
    }

    func testMixerDropsDuplicatesAndIsRepeatable() {
        let lists = [[1, 2, 3], [3, 4], [5, 1]]
        let first = FeedMixer.mix(lists, seed: 42)
        XCTAssertEqual(first.sorted(), [1, 2, 3, 4, 5])
        XCTAssertEqual(first, FeedMixer.mix(lists, seed: 42))
        let orders = Set((0..<20).map { FeedMixer.mix(lists, seed: UInt64($0)) })
        XCTAssertGreaterThan(orders.count, 1)
    }
}

final class PlayerGestureTests: XCTestCase {
    func testIntentNeedsMovementAndPicksAxisAndSide() {
        XCTAssertNil(PlayerGestures.intent(translation: CGSize(width: 5, height: 6), startX: 10, width: 800))
        XCTAssertEqual(PlayerGestures.intent(translation: CGSize(width: 30, height: 8), startX: 10, width: 800), .seek)
        XCTAssertEqual(PlayerGestures.intent(translation: CGSize(width: 4, height: -40), startX: 100, width: 800), .brightness)
        XCTAssertEqual(PlayerGestures.intent(translation: CGSize(width: 4, height: 40), startX: 500, width: 800), .volume)
        XCTAssertNil(PlayerGestures.intent(translation: CGSize(width: 40, height: 0), startX: 0, width: 0))
    }

    func testSeekTargetScalesWithWidthAndClamps() {
        XCTAssertEqual(PlayerGestures.seekTarget(from: 100, translationX: 400, width: 800, duration: 600), 145, accuracy: 0.001)
        XCTAssertEqual(PlayerGestures.seekTarget(from: 100, translationX: -400, width: 800, duration: 600), 55, accuracy: 0.001)
        XCTAssertEqual(PlayerGestures.seekTarget(from: 10, translationX: -800, width: 800, duration: 600), 0)
        XCTAssertEqual(PlayerGestures.seekTarget(from: 590, translationX: 800, width: 800, duration: 600), 600)
        // A 40 second clip: the full width covers the whole clip, not 90 seconds.
        XCTAssertEqual(PlayerGestures.seekTarget(from: 0, translationX: 400, width: 800, duration: 40), 20, accuracy: 0.001)
        XCTAssertEqual(PlayerGestures.seekTarget(from: 7, translationX: 100, width: 800, duration: 0), 7)
    }

    func testLevelMovesUpWhenDraggingUp() {
        XCTAssertEqual(PlayerGestures.level(from: 0.5, translationY: -100, height: 400), 0.75, accuracy: 0.0001)
        XCTAssertEqual(PlayerGestures.level(from: 0.5, translationY: 100, height: 400), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PlayerGestures.level(from: 0.9, translationY: -400, height: 400), 1)
        XCTAssertEqual(PlayerGestures.level(from: 0.1, translationY: 400, height: 400), 0)
        XCTAssertEqual(PlayerGestures.level(from: 1.4, translationY: 0, height: 0), 1)
    }

    func testLabels() {
        XCTAssertEqual(PlayerGestures.clock(0), "0:00")
        XCTAssertEqual(PlayerGestures.clock(75.9), "1:15")
        XCTAssertEqual(PlayerGestures.clock(3723), "1:02:03")
        XCTAssertEqual(PlayerGestures.clock(.nan), "0:00")
        XCTAssertEqual(PlayerGestures.seekDeltaLabel(from: 100, to: 112.4), "+0:12")
        XCTAssertEqual(PlayerGestures.seekDeltaLabel(from: 100, to: 35), "-1:05")
    }
}

final class SleepTimerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testOffNeverStops() {
        let timer = SleepTimer()
        XCTAssertFalse(timer.isDue(now: start.addingTimeInterval(99_999)))
        XCTAssertFalse(timer.stopsAtEpisodeEnd(now: start))
        XCTAssertNil(timer.statusLabel(now: start))
    }

    func testMinuteTimerBecomesDueAtDeadline() {
        var timer = SleepTimer()
        timer.set(.minutes15, now: start)
        XCTAssertFalse(timer.isDue(now: start.addingTimeInterval(899)))
        XCTAssertTrue(timer.isDue(now: start.addingTimeInterval(900)))
        XCTAssertEqual(timer.remaining(now: start.addingTimeInterval(1)), 899)
        XCTAssertEqual(timer.statusLabel(now: start.addingTimeInterval(1)), "剩余 14:59")
        XCTAssertFalse(timer.stopsAtEpisodeEnd(now: start.addingTimeInterval(10)))
        XCTAssertTrue(timer.stopsAtEpisodeEnd(now: start.addingTimeInterval(901)))
    }

    func testEndOfEpisodeStopsOnlyAtEpisodeEnd() {
        var timer = SleepTimer()
        timer.set(.endOfEpisode, now: start)
        XCTAssertFalse(timer.isDue(now: start.addingTimeInterval(99_999)))
        XCTAssertTrue(timer.stopsAtEpisodeEnd(now: start))
        XCTAssertEqual(timer.statusLabel(now: start), "播完本集后关闭")
    }

    func testSwitchingOffClearsDeadline() {
        var timer = SleepTimer()
        timer.set(.minutes60, now: start)
        timer.set(.off, now: start)
        XCTAssertNil(timer.deadline)
        XCTAssertFalse(timer.isDue(now: start.addingTimeInterval(4000)))
    }
}

final class EpisodeMathTests: XCTestCase {
    func testHistoryFilterAndLabel() {
        XCTAssertTrue(HistoryProgress.matches(.finished, completedEpisode: 135, total: 135))
        XCTAssertFalse(HistoryProgress.matches(.finished, completedEpisode: 3, total: 135))
        XCTAssertTrue(HistoryProgress.matches(.unfinished, completedEpisode: 3, total: 135))
        XCTAssertTrue(HistoryProgress.matches(.unfinished, completedEpisode: 5, total: 0))
        XCTAssertTrue(HistoryProgress.matches(.all, completedEpisode: 0, total: 0))
        XCTAssertEqual(HistoryProgress.label(episodeIndex: 3, total: 135), "3集/135集")
        XCTAssertEqual(HistoryProgress.label(episodeIndex: 3, total: 0), "3集")
    }
}

final class HistoryMergeTests: XCTestCase {
    private func entry(_ id: String, episode: Int, at seconds: TimeInterval, account: Bool, title: String = "剧", total: Int = 60, completed: Int = 0) -> HistoryEntry {
        HistoryEntry(seriesId: id, title: title, cover: account ? "" : "cover", episodeIndex: episode, total: total, completedEpisode: completed,
                     position: 0, updatedAt: Date(timeIntervalSince1970: seconds), fromAccount: account)
    }

    func testNewerRowWinsAndListIsNewestFirst() {
        let merged = HistoryMerge.merge(local: [entry("a", episode: 3, at: 100, account: false), entry("b", episode: 1, at: 50, account: false)],
                                        account: [entry("a", episode: 9, at: 200, account: true), entry("c", episode: 2, at: 150, account: true)])
        XCTAssertEqual(merged.map(\.seriesId), ["a", "c", "b"])
        XCTAssertEqual(merged[0].episodeIndex, 9)
        XCTAssertTrue(merged[0].fromAccount)
    }

    func testOlderAccountRowLosesAndWinnerBorrowsMissingFields() {
        let merged = HistoryMerge.merge(local: [entry("a", episode: 3, at: 300, account: false, completed: 2)],
                                        account: [entry("a", episode: 9, at: 200, account: true, completed: 8)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].episodeIndex, 3)
        XCTAssertFalse(merged[0].fromAccount)
        XCTAssertEqual(merged[0].completedEpisode, 8)
        let borrowed = HistoryMerge.merge(local: [entry("a", episode: 3, at: 100, account: false)],
                                          account: [entry("a", episode: 9, at: 200, account: true, title: "", total: 0)])
        XCTAssertEqual(borrowed[0].title, "剧")
        XCTAssertEqual(borrowed[0].cover, "cover")
        XCTAssertEqual(borrowed[0].total, 60)
    }

    func testCompletedEpisodeFromAccountRow() {
        XCTAssertEqual(HistoryMerge.completedEpisode(episodeIndex: 5, position: 10, duration: 100), 4)
        XCTAssertEqual(HistoryMerge.completedEpisode(episodeIndex: 5, position: 97, duration: 100), 5)
        XCTAssertEqual(HistoryMerge.completedEpisode(episodeIndex: 0, position: 0, duration: 0), 0)
        // Account history returns total series duration (e.g. 7530 s across 79 episodes); any row at the final episode counts as finished.
        XCTAssertEqual(HistoryMerge.completedEpisode(episodeIndex: 79, total: 79, position: 0, duration: 7530), 79)
        XCTAssertEqual(HistoryMerge.completedEpisode(episodeIndex: 69, total: 69, position: 27, duration: 3718), 69)
        XCTAssertEqual(HistoryMerge.completedEpisode(episodeIndex: 68, total: 69, position: 27, duration: 3718), 67)
    }
}

final class EpisodePositionBookTests: XCTestCase {
    func testRemembersPerEpisodeAndForgetsFinished() {
        var book = EpisodePositionBook()
        book.set(seriesId: "a", episode: 3, position: 42)
        book.set(seriesId: "a", episode: 4, position: 7)
        XCTAssertEqual(book.position(seriesId: "a", episode: 3), 42)
        XCTAssertEqual(book.positions(seriesId: "a").count, 2)
        // Played to the end, or barely started: nothing to resume.
        book.set(seriesId: "a", episode: 3, position: nil)
        book.set(seriesId: "a", episode: 4, position: 0.5)
        XCTAssertNil(book.position(seriesId: "a", episode: 3))
        XCTAssertTrue(book.series.isEmpty)
    }

    func testDropsLeastRecentlyTouchedSeriesOverTheLimit() {
        var book = EpisodePositionBook()
        for (index, id) in ["a", "b", "c"].enumerated() {
            book.set(seriesId: id, episode: 1, position: 10, now: Date(timeIntervalSince1970: Double(index)), limit: 2)
        }
        XCTAssertNil(book.position(seriesId: "a", episode: 1))
        XCTAssertEqual(book.position(seriesId: "b", episode: 1), 10)
        XCTAssertEqual(book.position(seriesId: "c", episode: 1), 10)
        // Touching an old one keeps it.
        book.set(seriesId: "b", episode: 2, position: 5, now: Date(timeIntervalSince1970: 10), limit: 2)
        book.set(seriesId: "d", episode: 1, position: 5, now: Date(timeIntervalSince1970: 11), limit: 2)
        XCTAssertNil(book.position(seriesId: "c", episode: 1))
        XCTAssertEqual(book.position(seriesId: "b", episode: 2), 5)
    }

    func testSurvivesEncoding() throws {
        var book = EpisodePositionBook()
        book.set(seriesId: "a", episode: 12, position: 33.5)
        let copy = try JSONDecoder().decode(EpisodePositionBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(copy, book)
    }
}

final class LocalStreamPathTests: XCTestCase {
    private var root: URL!
    private let token = "tokentokentoken"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("123-1080"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("123-1080/index.m3u8"))
        try Data("secret".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("outside-\(root.lastPathComponent).txt"))
    }

    private func file(_ path: String, token: String? = nil) -> URL? {
        LocalStreamPath.file(forRequestPath: path, token: token ?? self.token, root: root)
    }

    func testServesAFileUnderTheTokenOnly() {
        XCTAssertNotNil(file("/\(token)/123-1080/index.m3u8"))
        XCTAssertNotNil(file("/\(token)/123-1080/index.m3u8?x=1"))
        XCTAssertNil(file("/123-1080/index.m3u8"))
        XCTAssertNil(file("/wrongtoken/123-1080/index.m3u8"))
        XCTAssertNil(file("/\(token)/123-1080/missing.m4s"))
        XCTAssertNil(file("/\(token)/123-1080"))
        XCTAssertNil(file("/\(token)/123-1080/"))
    }

    func testRefusesAnythingThatCouldLeaveTheFolder() {
        XCTAssertNil(file("/\(token)/../index.m3u8"))
        XCTAssertNil(file("/\(token)/123-1080/../../etc/passwd"))
        XCTAssertNil(file("/\(token)/123-1080/%2e%2e%2findex.m3u8"))
        XCTAssertNil(file("/\(token)/123-1080%2findex.m3u8/x"))
        XCTAssertNil(file("/\(token)/123-1080/.hidden"))
        XCTAssertNil(file("/\(token)/123-1080/a/b"))
        XCTAssertNil(file("/\(token)//index.m3u8"))
        XCTAssertNil(file("/\(token)/123-1080/index.m3u8\\..\\x"))
    }

    func testRefusesASymbolicLinkLeadingOutside() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(root.lastPathComponent).txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("123-1080/link.m4s"), withDestinationURL: outside)
        XCTAssertNil(file("/\(token)/123-1080/link.m4s"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertNil(file("/\(token)/linked/\(outside.lastPathComponent)"))
    }
}

final class SearchHistoryRuleTests: XCTestCase {
    func testRecordDeduplicatesTrimsAndBounds() {
        var list = SearchHistoryRule.record("  重生  ", in: [], limit: 3)
        list = SearchHistoryRule.record("逆袭", in: list, limit: 3)
        list = SearchHistoryRule.record("甜宠", in: list, limit: 3)
        XCTAssertEqual(list, ["甜宠", "逆袭", "重生"])
        // Re-searching an existing keyword promotes it to the top.
        list = SearchHistoryRule.record("重生", in: list, limit: 3)
        XCTAssertEqual(list, ["重生", "甜宠", "逆袭"])
        // Exceeding the limit drops the oldest item.
        list = SearchHistoryRule.record("古装", in: list, limit: 3)
        XCTAssertEqual(list, ["古装", "重生", "甜宠"])
        // Empty/whitespace input is ignored.
        XCTAssertEqual(SearchHistoryRule.record("   ", in: list, limit: 3), list)
    }

    func testRemoveDecodeAndMatching() {
        let raw = "  古装 \n\n古装\n重生之豪门\n豪门逆袭\n"
        let decoded = SearchHistoryRule.decode(raw)
        XCTAssertEqual(decoded, ["古装", "重生之豪门", "豪门逆袭"])
        XCTAssertEqual(SearchHistoryRule.remove("古装", from: decoded), ["重生之豪门", "豪门逆袭"])
        // Prefix match comes before substring match.
        XCTAssertEqual(SearchHistoryRule.matching("豪门", in: decoded), ["豪门逆袭", "重生之豪门"])
    }

    func testNewlinesSanitizedInRecordAndEncode() {
        let recorded = SearchHistoryRule.record("第一行\n第二行\r\n第三行", in: [])
        XCTAssertEqual(recorded, ["第一行 第二行 第三行"])
        let encoded = SearchHistoryRule.encode(["甲\n乙", "丙"])
        XCTAssertEqual(SearchHistoryRule.decode(encoded), ["甲 乙", "丙"])
    }
}

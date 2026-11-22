import XCTest
@testable import AppLogic

final class AccountSyncRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstRunStarts() {
        var throttle = AccountSyncThrottle(interval: 60)
        XCTAssertTrue(throttle.begin(now: t0, force: false))
        XCTAssertTrue(throttle.isRunning)
    }

    func testNoReentryWhileRunningEvenWhenForced() {
        var throttle = AccountSyncThrottle(interval: 60)
        XCTAssertTrue(throttle.begin(now: t0, force: false))
        XCTAssertFalse(throttle.begin(now: t0.addingTimeInterval(1), force: false))
        XCTAssertFalse(throttle.begin(now: t0.addingTimeInterval(1), force: true))
    }

    func testUnforcedRunWithinIntervalIsSkipped() {
        var throttle = AccountSyncThrottle(interval: 60)
        XCTAssertTrue(throttle.begin(now: t0, force: false))
        throttle.end()
        XCTAssertFalse(throttle.begin(now: t0.addingTimeInterval(59), force: false))
        XCTAssertTrue(throttle.begin(now: t0.addingTimeInterval(60), force: false))
    }

    func testForcedRunIgnoresInterval() {
        var throttle = AccountSyncThrottle(interval: 60)
        XCTAssertTrue(throttle.begin(now: t0, force: false))
        throttle.end()
        XCTAssertTrue(throttle.begin(now: t0.addingTimeInterval(5), force: true))
    }

    func testSkippedRunDoesNotMoveTheWindow() {
        var throttle = AccountSyncThrottle(interval: 60)
        XCTAssertTrue(throttle.begin(now: t0, force: false))
        throttle.end()
        XCTAssertFalse(throttle.begin(now: t0.addingTimeInterval(30), force: false))
        XCTAssertTrue(throttle.begin(now: t0.addingTimeInterval(61), force: false))
    }

    func testRollbackOnlyWhileLocalStillMatchesFailedTarget() {
        // Favourited (target true), write failed, local still true: put it back.
        XCTAssertTrue(LocalRollback.shouldRevert(local: true, failedTarget: true))
        // The viewer tapped again meanwhile (local false now): leave the newer choice alone.
        XCTAssertFalse(LocalRollback.shouldRevert(local: false, failedTarget: true))
        XCTAssertTrue(LocalRollback.shouldRevert(local: false, failedTarget: false))
        XCTAssertFalse(LocalRollback.shouldRevert(local: true, failedTarget: false))
    }
}

final class HistoryMergeTieTests: XCTestCase {
    func testAccountRowWinsATieWithTheDeviceCopy() {
        // After a whole-history sync the device's store holds a copy with the same time.
        let at = Date(timeIntervalSince1970: 2_000_000)
        let local = HistoryEntry(seriesId: "s", title: "", cover: "", episodeIndex: 7, total: 0, completedEpisode: 6,
                                 position: 10, updatedAt: at, fromAccount: false)
        let account = HistoryEntry(seriesId: "s", title: "剧", cover: "c", episodeIndex: 7, total: 80, completedEpisode: 6,
                                   position: 10, updatedAt: at, fromAccount: true, category: "漫剧")
        let merged = HistoryMerge.merge(local: [local], account: [account])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].fromAccount)
        XCTAssertEqual(merged[0].category, "漫剧")
    }

    func testLaterDeviceRowStillWins() {
        let at = Date(timeIntervalSince1970: 2_000_000)
        let local = HistoryEntry(seriesId: "s", title: "剧", cover: "", episodeIndex: 9, total: 80, completedEpisode: 8,
                                 position: 3, updatedAt: at.addingTimeInterval(5), fromAccount: false)
        let account = HistoryEntry(seriesId: "s", title: "剧", cover: "c", episodeIndex: 7, total: 80, completedEpisode: 6,
                                   position: 10, updatedAt: at, fromAccount: true)
        let merged = HistoryMerge.merge(local: [local], account: [account])
        XCTAssertFalse(merged[0].fromAccount)
        XCTAssertEqual(merged[0].episodeIndex, 9)
        XCTAssertEqual(merged[0].cover, "c")
    }
}

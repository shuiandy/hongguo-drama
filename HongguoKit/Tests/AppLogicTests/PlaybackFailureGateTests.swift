import XCTest
@testable import AppLogic

final class PlaybackFailureGateTests: XCTestCase {
    func testFirstFailureOfCurrentItemIsTaken() {
        var gate = PlaybackFailureGate()
        XCTAssertTrue(gate.accept(token: 3, current: 3, isCurrentItem: true))
    }

    func testSecondSignalForSameLoadIsDropped() {
        // Status failed and failedToPlayToEndTime for one failure: only one reload.
        var gate = PlaybackFailureGate()
        XCTAssertTrue(gate.accept(token: 3, current: 3, isCurrentItem: true))
        XCTAssertFalse(gate.accept(token: 3, current: 3, isCurrentItem: true))
    }

    func testOldEpisodeNotificationCannotRetryNewOne() {
        var gate = PlaybackFailureGate()
        // Episode A was load 3; the viewer moved to B (load 4) before A's notification arrived.
        XCTAssertFalse(gate.accept(token: 3, current: 4, isCurrentItem: false))
        XCTAssertFalse(gate.accept(token: 3, current: 4, isCurrentItem: true))
        XCTAssertTrue(gate.accept(token: 4, current: 4, isCurrentItem: true))
    }

    func testItemKeptForPictureInPictureIsIgnored() {
        // In picture in picture the old item stays in the player while the new one loads.
        var gate = PlaybackFailureGate()
        XCTAssertFalse(gate.accept(token: 5, current: 5, isCurrentItem: false))
        XCTAssertTrue(gate.accept(token: 5, current: 5, isCurrentItem: true))
    }

    func testReloadAfterFailureCanFailAgain() {
        // The automatic reload is a new load: its own failure must reach the UI.
        var gate = PlaybackFailureGate()
        XCTAssertTrue(gate.accept(token: 6, current: 6, isCurrentItem: true))
        XCTAssertTrue(gate.accept(token: 7, current: 7, isCurrentItem: true))
    }
}

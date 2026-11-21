import XCTest
@testable import HongguoCore

final class AccountSessionGateTests: XCTestCase {
    func testSyncOfCurrentSessionWrites() {
        var gate = AccountSessionGate()
        let token = gate.signedIn(accountId: "a")
        XCTAssertEqual(gate.current, token)
        XCTAssertTrue(gate.accepts(token))
    }

    func testDelayedSyncAfterSignOutIsDropped() {
        // Login verified, favourites still loading (slow fallback), the viewer signs out.
        var gate = AccountSessionGate()
        let token = gate.signedIn(accountId: "a")
        gate.signedOut()
        XCTAssertNil(gate.current)
        XCTAssertFalse(gate.accepts(token))
    }

    func testDelayedSyncAfterAccountSwitchIsDropped() {
        var gate = AccountSessionGate()
        let first = gate.signedIn(accountId: "a")
        let second = gate.signedIn(accountId: "b")
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }

    func testSigningInAgainToSameAccountStartsANewSession() {
        // Sign out and back in as the same account: the old session's sync still must not write.
        var gate = AccountSessionGate()
        let old = gate.signedIn(accountId: "a")
        gate.signedOut()
        let fresh = gate.signedIn(accountId: "a")
        XCTAssertFalse(gate.accepts(old))
        XCTAssertTrue(gate.accepts(fresh))
    }
    func testRollbackPreservesOtherEdits() {
        var rows = ["c", "new"]
        AccountListRollback.restore(&rows, prior: (0, "a")) { $0 == "a" }
        XCTAssertEqual(rows, ["a", "c", "new"])
    }
}

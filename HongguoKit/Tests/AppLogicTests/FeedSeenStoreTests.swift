import XCTest
@testable import AppLogic

final class FeedSeenStoreTests: XCTestCase {
    func testRecordMovesToFrontAndCapsAtLimit() {
        var ids = FeedSeenStore.record("1", in: [], limit: 3)
        ids = FeedSeenStore.record("2", in: ids, limit: 3)
        ids = FeedSeenStore.record("3", in: ids, limit: 3)
        XCTAssertEqual(ids, ["3", "2", "1"])

        ids = FeedSeenStore.record("1", in: ids, limit: 3)
        XCTAssertEqual(ids, ["1", "3", "2"])

        ids = FeedSeenStore.record("4", in: ids, limit: 3)
        XCTAssertEqual(ids, ["4", "1", "3"])
    }

    func testFilterRemovesSeenAndDislikedAndRollsBackOnlyWhenEmptied() {
        let candidates = ["a", "b", "c", "d"]
        let filtered = FeedSeenStore.filter(
            candidates,
            id: { $0 },
            seen: ["a", "b"],
            disliked: ["c"]
        )
        XCTAssertEqual(filtered, ["d"])

        // When every non-disliked item is already seen, rollback preserves non-disliked items
        // while still strictly excluding disliked ones.
        let rolledBack = FeedSeenStore.filter(
            candidates,
            id: { $0 },
            seen: ["a", "b", "d"],
            disliked: ["c"]
        )
        XCTAssertEqual(rolledBack, ["a", "b", "d"])

        // Without rollback (e.g., when caller intends to backfill from next page first), returns empty.
        let strict = FeedSeenStore.filter(
            candidates,
            id: { $0 },
            seen: ["a", "b", "d"],
            disliked: ["c"],
            allowRollback: false
        )
        XCTAssertEqual(strict, [])
    }

    func testQueryParamAndCodecRoundTrip() {
        let encoded = FeedSeenStore.encode(["10", "20", "30", "40"])
        XCTAssertEqual(FeedSeenStore.decode(encoded), ["10", "20", "30", "40"])
        XCTAssertEqual(FeedSeenStore.queryParam(["10", "20", "30", "40"], limit: 2), "10,20")
    }
}

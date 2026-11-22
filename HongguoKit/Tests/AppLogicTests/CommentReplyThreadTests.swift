import XCTest
@testable import AppLogic

final class CommentReplyThreadTests: XCTestCase {
    private struct StubReply: Identifiable, Equatable {
        let id: String
        let text: String
    }

    func testExpandPaginatesDeduplicatesAndCollapses() {
        var thread = CommentReplyThread<StubReply>(reportedCount: 8)
        XCTAssertFalse(thread.isExpanded)
        XCTAssertEqual(thread.displayTotal(reportedCount: 8), 8)
        XCTAssertEqual(thread.remainingCount(reportedCount: 8), 8)

        // First expand fetches page 1 from cursor ""
        XCTAssertEqual(thread.beginExpandOrLoadMore(), "")
        XCTAssertTrue(thread.isExpanded)
        XCTAssertTrue(thread.isLoading)
        // Duplicate tap while loading is ignored
        XCTAssertNil(thread.beginExpandOrLoadMore())

        thread.applyPage(
            [StubReply(id: "r1", text: "a"), StubReply(id: "r2", text: "b")],
            total: 10,
            nextCursor: "2",
            hasMore: true,
            requestedCursor: ""
        )
        XCTAssertFalse(thread.isLoading)
        XCTAssertTrue(thread.loadedOnce)
        XCTAssertTrue(thread.hasMore)
        XCTAssertEqual(thread.replies.map(\.id), ["r1", "r2"])
        XCTAssertEqual(thread.remainingCount(reportedCount: 8), 8)
        XCTAssertEqual(thread.displayTotal(reportedCount: 8), 10)

        // Collapse preserves loaded replies; re-expanding does not re-fetch
        thread.collapse()
        XCTAssertFalse(thread.isExpanded)
        XCTAssertNil(thread.beginExpandOrLoadMore())
        XCTAssertTrue(thread.isExpanded)
        XCTAssertFalse(thread.isLoading)

        // Load more fetches cursor "2", deduplicates overlapping ids, and stops on hasMore=false
        XCTAssertEqual(thread.beginExpandOrLoadMore(), "2")
        thread.applyPage(
            [StubReply(id: "r2", text: "dup"), StubReply(id: "r3", text: "c")],
            total: 3,
            nextCursor: "3",
            hasMore: false,
            requestedCursor: "2"
        )
        XCTAssertEqual(thread.replies.map(\.id), ["r1", "r2", "r3"])
        XCTAssertFalse(thread.hasMore)
        XCTAssertEqual(thread.remainingCount(reportedCount: 3), 0)
    }

    func testStaleCursorStopsPaginationAndFailureAllowsRetry() {
        var thread = CommentReplyThread<StubReply>(reportedCount: 5)
        XCTAssertEqual(thread.beginExpandOrLoadMore(), "")
        thread.fail()
        XCTAssertTrue(thread.failed)
        XCTAssertFalse(thread.isLoading)

        // Retry after failure starts from ""
        XCTAssertEqual(thread.beginExpandOrLoadMore(), "")
        XCTAssertFalse(thread.failed)
        thread.applyPage(
            [StubReply(id: "r1", text: "a")],
            total: 5,
            nextCursor: "",
            hasMore: true,
            requestedCursor: ""
        )
        XCTAssertFalse(thread.hasMore, "empty nextCursor must stop pagination")

        // Unchanged cursor also stops pagination
        var second = CommentReplyThread<StubReply>(reportedCount: 5)
        _ = second.beginExpandOrLoadMore()
        second.applyPage([StubReply(id: "r1", text: "a")], total: 5, nextCursor: "5", hasMore: true, requestedCursor: "")
        XCTAssertTrue(second.hasMore)
        XCTAssertEqual(second.beginExpandOrLoadMore(), "5")
        second.applyPage([StubReply(id: "r2", text: "b")], total: 5, nextCursor: "5", hasMore: true, requestedCursor: "5")
        XCTAssertFalse(second.hasMore, "unchanged cursor must stop pagination")
    }
}

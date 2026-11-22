import AppLogic
import XCTest

final class PageRequestsTests: XCTestCase {
    func testLatePageAndCleanupCannotAffectNewFilterOrRefresh() throws {
        var pages = PageRequests<String>()
        _ = pages.reload("A")
        let old = try XCTUnwrap(pages.beginMore(showing: "A"))
        XCTAssertNil(pages.beginMore(showing: "B"))
        _ = pages.reload("B")
        let current = try XCTUnwrap(pages.beginMore(showing: "B"))
        XCTAssertFalse(pages.accepts(old, showing: "B"))
        pages.finishMore(old)
        XCTAssertTrue(pages.loadingMore)
        _ = pages.reload("B")
        XCTAssertFalse(pages.accepts(current, showing: "B"))
    }

    func testFailedPageCanRetryWithoutStartingNewList() throws {
        var pages = PageRequests<String>()
        let generation = pages.reload("episode")
        let page = try XCTUnwrap(pages.beginMore(showing: "episode"))
        pages.finishMore(page)
        XCTAssertEqual(pages.beginMore(showing: "episode"), generation)
    }
}

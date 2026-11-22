import XCTest
@testable import AppLogic

/// Plays swipeable tabs against `TabPages` the way the theatre pages use it: each tab keeps its own
/// list; replies may come back in any order.
final class TabPagesTests: XCTestCase {
    struct Row: Identifiable, Equatable, Sendable { let id: String }
    typealias Pages = TabPages<String, Row, Int>

    private func rows(_ ids: String...) -> [Row] { ids.map(Row.init) }

    func testAnUnloadedTabIsEmptyAndLoading() {
        var pages = Pages()
        XCTAssertTrue(pages.needsLoad("all"))
        _ = pages.beginLoad("all")
        XCTAssertEqual(pages.page("all").phase, .loading)
        XCTAssertTrue(pages.page("all").items.isEmpty)
        XCTAssertFalse(pages.needsLoad("all"))
    }

    func testSlowReplyForALeftTabFillsOnlyThatTab() {
        var pages = Pages()
        let a = pages.beginLoad("漫剧")
        let b = pages.beginLoad("真人剧")
        XCTAssertTrue(pages.finishLoad(b, items: rows("b1"), cursor: nil))
        // 漫剧's reply arrives after the viewer moved on to 真人剧.
        XCTAssertTrue(pages.finishLoad(a, items: rows("a1", "a2"), cursor: 2))
        XCTAssertEqual(pages.page("真人剧").items, rows("b1"))
        XCTAssertEqual(pages.page("漫剧").items, rows("a1", "a2"))
        XCTAssertEqual(pages.page("漫剧").cursor, 2)
    }

    func testCachedTabNeedsNoReload() {
        var pages = Pages()
        let t = pages.beginLoad("all")
        pages.finishLoad(t, items: rows("x"), cursor: nil)
        XCTAssertFalse(pages.needsLoad("all"))
        XCTAssertEqual(pages.page("all").phase, .loaded)
    }

    func testOvertakenReplyIsDropped() {
        var pages = Pages()
        let first = pages.beginLoad("all")
        let refresh = pages.beginLoad("all", keepingItems: true)
        XCTAssertTrue(pages.finishLoad(refresh, items: rows("new"), cursor: nil))
        XCTAssertFalse(pages.finishLoad(first, items: rows("old"), cursor: nil))
        XCTAssertFalse(pages.failLoad(first, message: "late"))
        XCTAssertEqual(pages.page("all").items, rows("new"))
        XCTAssertEqual(pages.page("all").phase, .loaded)
    }

    func testRefreshKeepsRowsAndAFailureLeavesThem() {
        var pages = Pages()
        let t = pages.beginLoad("all")
        pages.finishLoad(t, items: rows("x"), cursor: nil)
        let refresh = pages.beginLoad("all", keepingItems: true)
        XCTAssertEqual(pages.page("all").items, rows("x"))
        pages.failLoad(refresh, message: "offline")
        XCTAssertEqual(pages.page("all").items, rows("x"))
        XCTAssertEqual(pages.page("all").phase, .loaded)
    }

    func testFailureOnAnEmptyTabShowsTheErrorAndWaitsForRetry() {
        var pages = Pages()
        let t = pages.beginLoad("all")
        pages.failLoad(t, message: "offline")
        XCTAssertEqual(pages.page("all").phase, .failed("offline"))
        XCTAssertFalse(pages.needsLoad("all"))
    }

    func testMoreAppendsWithoutDuplicates() {
        var pages = Pages()
        let t = pages.beginLoad("all")
        pages.finishLoad(t, items: rows("1", "2"), cursor: 2)
        let more = pages.beginMore("all")
        XCTAssertNotNil(more)
        XCTAssertNil(pages.beginMore("all"), "one next page at a time")
        pages.finishMore(more!, items: rows("2", "3"), cursor: nil)
        XCTAssertEqual(pages.page("all").items, rows("1", "2", "3"))
        XCTAssertNil(pages.beginMore("all"), "no cursor, no more")
    }

    func testMoreAfterAReloadIsDropped() {
        var pages = Pages()
        let t = pages.beginLoad("all")
        pages.finishLoad(t, items: rows("1"), cursor: 1)
        let more = pages.beginMore("all")!
        let reload = pages.beginLoad("all")
        XCTAssertFalse(pages.finishMore(more, items: rows("stale"), cursor: 9))
        pages.finishLoad(reload, items: rows("a"), cursor: nil)
        XCTAssertEqual(pages.page("all").items, rows("a"))
    }

    func testFailedMoreLetsTheTabTryAgain() {
        var pages = Pages()
        let t = pages.beginLoad("all")
        pages.finishLoad(t, items: rows("1"), cursor: 1)
        let more = pages.beginMore("all")!
        pages.failMore(more)
        XCTAssertFalse(pages.page("all").loadingMore)
        XCTAssertNotNil(pages.beginMore("all"))
    }

    func testFirstReplyWithRepeatedRowsKeepsOneOfEach() {
        var pages = Pages()
        let t = pages.beginLoad("all")
        pages.finishLoad(t, items: rows("1", "1", "2"), cursor: nil)
        XCTAssertEqual(pages.page("all").items, rows("1", "2"))
    }
}

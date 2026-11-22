import XCTest

/// Starts the app offline and muted and checks that the six top tabs are there and that the
/// route switch opens the tab it names.
final class LaunchTests: XCTestCase {
    private func launch(route: String) -> XCUIApplication {
        freshLaunch(["-HongguoRoute", route])
    }

    func testSixTopTabs() {
        // 剧场 keeps the tab bar on screen (on 推荐 it fades while a clip plays).
        let app = launch(route: "theater")
        for title in ["推荐", "剧场", "排行", "追剧", "搜索", "我的"] {
            XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 10), "missing tab \(title)")
        }
    }

    func testRouteOpensTheater() {
        let app = launch(route: "theater")
        XCTAssertTrue(app.buttons["真人剧"].waitForExistence(timeout: 10))
    }

    /// Down from the tab bar moves the focus into the page (its chips).
    func testRemoteMovesFocusIntoShelf() {
        let app = launch(route: "theater")
        XCTAssertTrue(app.buttons["真人剧"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        // A chip or the 题材 menu (not a button element on tvOS), whichever lies under the tab.
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists,
                       "focus stayed on the tab bar")
    }

    /// 追剧 shows the favourites and the history the shared library was seeded with in a sample
    /// run; a long press offers 取消收藏 (a device-only change here: signed out, offline).
    func testFollowingShowsSeededFavourites() {
        let app = launch(route: "following")
        XCTAssertTrue(app.staticTexts["收藏"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["历史"].exists)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        let unfavorite = app.descendants(matching: .any)["取消收藏"]
        XCTAssertTrue(unfavorite.waitForExistence(timeout: 5), "the long-press menu")
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(unfavorite.waitForExistence(timeout: 2))
    }

    /// 剧场, in the iOS order: the category chips, the 题材 filter and the shortcuts, then the
    /// chosen category's grid.
    func testTheaterChipsAndGrid() {
        let app = launch(route: "theater")
        XCTAssertTrue(app.buttons["真人剧"].waitForExistence(timeout: 10))
        for title in ["漫剧", "AI 剧", "排行榜", "追剧日历", "新剧"] {
            XCTAssertTrue(app.buttons[title].exists, "missing chip \(title)")
        }
        XCTAssertTrue(app.buttons["真人剧"].isSelected, "the first category is chosen")
    }

    /// 排行: the categories on the left and the chosen 榜单's grid.
    func testRankingBoardsAndGrid() {
        let app = launch(route: "ranking")
        XCTAssertTrue(app.staticTexts["红果推荐榜"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["热播榜"].exists)
        XCTAssertTrue(app.buttons["真人剧"].exists)
    }

    /// 搜索, in the iOS order before anything is typed: the shortcuts, 猜你想搜 and the one card
    /// with the three boards as tabs.
    func testSearchLanding() {
        let app = launch(route: "search")
        XCTAssertTrue(app.staticTexts["猜你想搜"].waitForExistence(timeout: 10))
        for title in ["排行", "追剧日历", "上新", "热搜榜", "热点话题榜", "预约榜"] {
            XCTAssertTrue(app.buttons[title].exists, "missing \(title)")
        }
        XCTAssertTrue(app.buttons["热搜榜"].isSelected, "热搜榜 is the board shown first")
    }
}

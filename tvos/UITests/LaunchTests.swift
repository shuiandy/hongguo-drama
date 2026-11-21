import XCTest

/// Starts the app offline and muted and checks that the six top tabs are there and that the
/// route switch opens the tab it names.
final class LaunchTests: XCTestCase {
    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HongguoOfflineFixtures", "YES", "-HongguoMuted", "YES", "-HongguoRoute", route]
        app.launch()
        return app
    }

    func testSixTopTabs() {
        let app = launch(route: "recommend")
        for title in ["推荐", "剧场", "排行", "追剧", "搜索", "我的"] {
            XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 10), "missing tab \(title)")
        }
    }

    func testRouteOpensTheater() {
        let app = launch(route: "theater")
        XCTAssertTrue(app.staticTexts["真人剧"].waitForExistence(timeout: 10))
    }

    /// Down from the tab bar lands on the first poster of the first shelf.
    func testRemoteMovesFocusIntoShelf() {
        let app = launch(route: "theater")
        XCTAssertTrue(app.staticTexts["真人剧"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
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

    /// 剧场: 继续观看 and one shelf per category.
    func testTheaterContinueAndShelves() {
        let app = launch(route: "theater")
        XCTAssertTrue(app.staticTexts["继续观看"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["漫剧"].waitForExistence(timeout: 10))
    }

    /// 排行: the categories on the left and the chosen 榜单's grid.
    func testRankingBoardsAndGrid() {
        let app = launch(route: "ranking")
        XCTAssertTrue(app.staticTexts["红果推荐榜"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["热播榜"].exists)
        XCTAssertTrue(app.buttons["真人剧"].exists)
    }

    /// 搜索: the system search field, 猜你想搜 and the boards before anything is typed.
    func testSearchLanding() {
        let app = launch(route: "search")
        XCTAssertTrue(app.staticTexts["猜你想搜"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["热搜榜"].exists)
    }
}

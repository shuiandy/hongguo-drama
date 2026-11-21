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
        XCTAssertTrue(app.staticTexts["热播"].waitForExistence(timeout: 10))
    }

    /// Down from the tab bar lands on the first poster of the first shelf.
    func testRemoteMovesFocusIntoShelf() {
        let app = launch(route: "theater")
        XCTAssertTrue(app.staticTexts["热播"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists,
                       "focus stayed on the tab bar")
    }
}

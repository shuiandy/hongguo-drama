import XCTest

/// 推荐: the one button holds the focus, down changes the clip, a press opens the whole series in
/// place, Back returns to the feed. Offline and muted.
final class RecommendTests: XCTestCase {
    func testDownChangesClipAndPressOpensSeries() {
        let app = freshLaunch([])
        let main = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '观看完整剧集'")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 10), "the app opens on 推荐")
        let next = app.staticTexts["下一部"]
        XCTAssertTrue(next.exists)
        let focused = NSPredicate(format: "hasFocus == true")
        expectation(for: focused, evaluatedWith: main)
        waitForExpectations(timeout: 5) // the button takes the focus from the tab bar
        let titles = app.staticTexts.allElementsBoundByIndex.map(\.label)
        XCUIRemote.shared.press(.down)
        let changed = NSPredicate { _, _ in app.staticTexts.allElementsBoundByIndex.map(\.label) != titles }
        expectation(for: changed, evaluatedWith: NSObject())
        waitForExpectations(timeout: 5)
        XCTAssertTrue(main.hasFocus, "the one button keeps the focus")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '集' AND label BEGINSWITH '第'")).firstMatch
            .waitForExistence(timeout: 5) || app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(main.waitForExistence(timeout: 5), "back to the feed")
    }

    private func launchFocused() -> (XCUIApplication, XCUIElement) {
        let app = freshLaunch([])
        let main = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '观看完整剧集'")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        waitForFocus(main)
        return (app, main)
    }

    private func waitForFocus(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    /// What the page says (the clip's series and the next one): which clip is showing.
    private func shown(_ app: XCUIApplication) -> Set<String> {
        Set(app.staticTexts.allElementsBoundByIndex.map(\.label))
    }

    /// One press, then longer than the one-clip-per-swipe gate before the next.
    private func press(_ button: XCUIRemote.Button) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Up is the clip before, also while the tab bar shows: down, down, up is the second clip,
    /// and the focus stays on 观看完整剧集.
    func testUpGoesBackAClipNotToTheTabBar() {
        let (app, main) = launchFocused()
        press(.down)
        let second = shown(app)
        press(.down)
        XCTAssertNotEqual(shown(app), second, "the third clip")
        press(.up)
        XCTAssertEqual(shown(app), second, "up is the clip before")
        XCTAssertTrue(main.hasFocus, "the focus stays on the button")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "past the first clip the tab bar is not there to take the focus")
    }

    /// Only on the first clip does up go to the tab bar.
    func testUpOnTheFirstClipGoesToTheTabBar() {
        let (app, main) = launchFocused()
        let first = shown(app)
        press(.up)
        waitForFocus(app.tabBars.buttons["推荐"])
        XCTAssertFalse(main.hasFocus)
        press(.down)
        waitForFocus(main)
        XCTAssertEqual(shown(app), first, "still the first clip")
    }

    /// Past the first clip, Back brings the tab bar in with the focus on it; down returns to the
    /// button and the bar goes again, so up is the clip before once more.
    func testBackShowsTheTabBarPastTheFirstClip() {
        let (app, main) = launchFocused()
        let first = shown(app)
        press(.down)
        XCUIRemote.shared.press(.menu)
        waitForFocus(app.tabBars.buttons["推荐"])
        press(.down)
        waitForFocus(main)
        press(.up)
        XCTAssertEqual(shown(app), first, "up is the clip before, not the tab bar")
        XCTAssertTrue(main.hasFocus)
    }
}

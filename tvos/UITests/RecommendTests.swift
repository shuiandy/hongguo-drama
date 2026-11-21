import XCTest

/// 推荐: the one button holds the focus, down changes the clip, a press opens the whole series in
/// place, Back returns to the feed. Offline and muted.
final class RecommendTests: XCTestCase {
    func testDownChangesClipAndPressOpensSeries() {
        // Start from the home screen with the previous test's app fully gone: launched while
        // tvOS is still switching away from it, the app came up as a black, half-size window.
        XCUIApplication().terminate()
        XCUIRemote.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication()
        app.launchArguments = ["-HongguoOfflineFixtures", "YES", "-HongguoMuted", "YES"]
        app.launch()
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
}

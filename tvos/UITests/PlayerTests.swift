import XCTest

/// The player and the series page driven with the Siri Remote, offline and muted.
final class PlayerTests: XCTestCase {
    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HongguoOfflineFixtures", "YES", "-HongguoMuted", "YES", "-HongguoRoute", route]
        app.launch()
        return app
    }

    private let remote = XCUIRemote.shared

    /// Seconds shown on the left of the progress bar ("m:ss").
    private func elapsed(_ app: XCUIApplication) -> Int? {
        let clocks = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.range(of: #"^\d+:\d\d$"#, options: .regularExpression) != nil }
        guard let first = clocks.first else { return nil }
        let parts = first.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    func testClickShowsControlsThenBackClosesThePlayer() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["选集"].exists)
        remote.press(.select)
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 5), "the click shows the controls")
        remote.press(.menu)
        XCTAssertTrue(app.tabBars.buttons["推荐"].waitForExistence(timeout: 5), "back closes the player")
        XCTAssertFalse(app.staticTexts["离线示例，没有视频画面"].exists)
    }

    func testRightClickGoesForwardTenSeconds() throws {
        let app = launch(route: "player-controls")
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 10))
        remote.press(.select) // pause, so the clock holds still
        let before = try XCTUnwrap(elapsed(app))
        remote.press(.right)
        let deadline = Date().addingTimeInterval(3)
        var after = before
        while Date() < deadline { after = elapsed(app) ?? before; if after >= before + 10 { break } }
        XCTAssertGreaterThanOrEqual(after, before + 9)
    }

    func testDownOpensEpisodesAndBackClosesThePanelFirst() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        remote.press(.select)
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 5))
        remote.press(.down)
        remote.press(.select)
        XCTAssertTrue(app.buttons["31-60"].waitForExistence(timeout: 5), "选集 opens the episode panel")
        remote.press(.menu)
        XCTAssertFalse(app.buttons["31-60"].waitForExistence(timeout: 2), "back closes the panel")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].exists, "and the player stays")
        remote.press(.menu)
        XCTAssertTrue(app.tabBars.buttons["推荐"].waitForExistence(timeout: 5))
    }

    func testTheaterToSeriesPageToPlayer() {
        let app = launch(route: "theater")
        XCTAssertTrue(app.staticTexts["真人剧"].waitForExistence(timeout: 10))
        remote.press(.down)
        remote.press(.select)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '播放第1集' OR label BEGINSWITH '继续看第'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "the series page opens")
        XCTAssertTrue(app.buttons["12"].exists, "twelve episodes to a row")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 5), "the player opens")
        remote.press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: 5), "back returns to the series page")
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["真人剧"].waitForExistence(timeout: 5))
    }
}

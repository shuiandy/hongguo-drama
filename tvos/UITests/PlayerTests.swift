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
        remote.press(.down) // 继续观看
        remote.press(.down) // the first shelf
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

    private func advances(_ app: XCUIApplication, within seconds: Double = 2.5) -> Bool {
        guard let start = elapsed(app) else { return false }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if let now = elapsed(app), now > start { return true } }
        return false
    }

    /// The play key on the picture pauses and shows the controls, and plays again; with the focus
    /// on the buttons it does the same, once per press.
    func testPlayKeyOnThePictureAndOnTheButtons() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        remote.press(.playPause)
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 5), "paused, controls shown")
        XCTAssertFalse(advances(app), "paused")
        remote.press(.down) // focus to the buttons
        remote.press(.playPause)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["选集"])
        waitForExpectations(timeout: 3) // one press on the buttons plays (and the controls go)
        remote.press(.playPause)
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 3), "the next press pauses")
        XCTAssertFalse(advances(app), "paused")
    }

    /// In the last 5 seconds 下一集 shows and takes the focus; pressing it plays the next episode.
    func testNextButtonInTheLastFiveSeconds() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        for _ in 0..<7 { remote.press(.right) }
        let next = app.buttons["下一集"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.hasFocus, "下一集 takes the focus")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["第2集 / 共60集"].waitForExistence(timeout: 5))
    }

    /// At the end of an episode the next one plays by itself.
    func testNextEpisodePlaysAtTheEnd() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        for _ in 0..<7 { remote.press(.right) }
        let next = app.buttons["下一集"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        // Left alone, the episode runs out and the next one starts (its clock starts again).
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: next)
        waitForExpectations(timeout: 10)
        remote.press(.playPause) // pause, to show the controls
        XCTAssertTrue(app.staticTexts["第2集 / 共60集"].waitForExistence(timeout: 5))
    }
}

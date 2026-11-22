import XCTest

/// The player and the series page driven with the Siri Remote, offline and muted.
final class PlayerTests: XCTestCase {
    private func launch(route: String) -> XCUIApplication {
        freshLaunch(["-HongguoRoute", route])
    }

    private let remote = XCUIRemote.shared

    /// Seconds shown on the left of the progress bar ("m:ss").
    private func elapsed(_ app: XCUIApplication) -> Int? {
        let clocks = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.range(of: #"^\d+:\d\d$"#, options: .regularExpression) != nil }
        guard let first = clocks.first else { return nil }
        let parts = first.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    private func waitForFocus(_ element: XCUIElement, _ message: String = "") {
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    /// Back goes one layer out each time: the controls first, then the player.
    func testClickShowsControlsThenBackLeavesLayerByLayer() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["选集"].exists)
        remote.press(.select)
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 5), "the click shows the controls")
        waitForFocus(app.buttons["进度条"])
        remote.press(.menu)
        XCTAssertFalse(app.buttons["选集"].waitForExistence(timeout: 2), "back puts the controls away")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].exists, "and the player stays")
        remote.press(.menu)
        XCTAssertTrue(app.tabBars.buttons["推荐"].waitForExistence(timeout: 5), "back again closes the player")
    }

    /// Straight from the picture, one press of Back leaves the player.
    func testBackOnThePictureClosesThePlayer() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        remote.press(.menu)
        XCTAssertTrue(app.tabBars.buttons["推荐"].waitForExistence(timeout: 5))
    }

    func testRightOnTheProgressBarGoesForwardTenSeconds() throws {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        remote.press(.select) // pause and show the controls, so the clock holds still
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 5))
        waitForFocus(app.buttons["进度条"])
        let before = try XCTUnwrap(elapsed(app))
        remote.press(.right)
        let deadline = Date().addingTimeInterval(3)
        var after = before
        while Date() < deadline { after = elapsed(app) ?? before; if after >= before + 10 { break } }
        XCTAssertGreaterThanOrEqual(after, before + 9)
    }

    /// Down from the progress bar reaches the buttons, and left and right there move between the
    /// buttons without touching the playback position.
    func testLeftAndRightOnTheButtonsDoNotMoveThePosition() throws {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        remote.press(.select) // paused, the progress bar has the focus
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 5))
        waitForFocus(app.buttons["进度条"])
        let before = try XCTUnwrap(elapsed(app))
        remote.press(.down)
        waitForFocus(app.buttons["选集"])
        remote.press(.right)
        waitForFocus(app.buttons["评论"])
        remote.press(.right)
        remote.press(.left)
        waitForFocus(app.buttons["评论"])
        XCTAssertEqual(elapsed(app), before, "the position did not move")
        remote.press(.up)
        waitForFocus(app.buttons["进度条"])
    }

    /// Down on the picture brings the controls in with the focus on 选集; Back closes the panel
    /// first, then the player.
    func testDownShowsControlsOnEpisodesAndBackClosesThePanelFirst() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        remote.press(.down)
        XCTAssertTrue(app.buttons["选集"].waitForExistence(timeout: 5), "down shows the controls, not the episode panel")
        XCTAssertFalse(app.buttons["31-60"].exists)
        waitForFocus(app.buttons["选集"])
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
        XCTAssertTrue(app.buttons["真人剧"].waitForExistence(timeout: 10))
        remote.press(.down) // the chips
        remote.press(.down) // the grid
        remote.press(.select)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '播放第1集' OR label BEGINSWITH '继续看第'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "the series page opens")
        XCTAssertTrue(app.buttons["12"].exists, "twelve episodes to a row")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 5), "the player opens")
        remote.press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: 5), "back returns to the series page")
        remote.press(.menu)
        XCTAssertTrue(app.buttons["真人剧"].waitForExistence(timeout: 5))
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
        Thread.sleep(forTimeInterval: 1) // the picture takes the focus back from the button that went
        remote.press(.playPause) // pause, to show the controls
        XCTAssertTrue(app.staticTexts["第2集 / 共60集"].waitForExistence(timeout: 5))
    }

    /// 评论 in the player: the episode's comments, read only; Back closes the panel first.
    func testCommentsPanel() {
        let app = launch(route: "player")
        XCTAssertTrue(app.staticTexts["离线示例，没有视频画面"].waitForExistence(timeout: 10))
        remote.press(.select) // controls
        XCTAssertTrue(app.buttons["评论"].waitForExistence(timeout: 5))
        remote.press(.down) // to 选集
        remote.press(.right) // 评论
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: app.buttons["评论"])
        waitForExpectations(timeout: 5)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["422条评论"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["示例用户甲"].exists)
        remote.press(.menu)
        XCTAssertFalse(app.staticTexts["422条评论"].waitForExistence(timeout: 2))
    }

    /// 新剧推荐 and 追剧日历 (opened from 剧场; here by route).
    func testNewReleasesAndCalendar() {
        let app = launch(route: "new")
        XCTAssertTrue(app.buttons["新剧推荐"].waitForExistence(timeout: 10))
        let calendar = launch(route: "calendar")
        XCTAssertTrue(calendar.staticTexts["今天"].waitForExistence(timeout: 10), "the calendar's days")
        XCTAssertTrue(calendar.buttons["真人剧"].exists, "the content filter")
        remote.press(.menu)
        XCTAssertFalse(calendar.staticTexts["今天"].waitForExistence(timeout: 3), "Back closes it")
        XCTAssertTrue(calendar.buttons["新剧"].exists, "back on 剧场")
    }
}

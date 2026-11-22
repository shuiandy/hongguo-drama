import XCTest

/// 我的 and 扫码登录, offline and muted: no request is made and nobody signs in.
final class MeTests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        freshLaunch(["-HongguoRoute", "me"] + extra)
    }

    private func waitForFocus(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    func testSignedOutCardOpensLoginAndBack() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["未登录"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["自动连播"].exists)
        XCTAssertFalse(app.buttons["云端观看记录"].exists, "no history switch, as on iOS")
        XCUIRemote.shared.press(.down)
        let signIn = app.buttons["扫码登录"]
        waitForFocus(signIn)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["登录红果账号"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["示例数据下不能登录"].exists, "sample runs never ask the website for a code")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["未登录"].waitForExistence(timeout: 5))
    }

    /// Down, row by row, reaches every row of the page: the last one included.
    func testDownReachesEveryRow() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["未登录"].waitForExistence(timeout: 10))
        for title in ["扫码登录", "切换账号", "默认清晰度", "默认倍速", "弹幕", "自动连播"] {
            XCUIRemote.shared.press(.down)
            waitForFocus(app.buttons[title])
        }
        // A press on a settings row moves it to its next value.
        let row = app.buttons["自动连播"]
        let before = row.value as? String
        XCUIRemote.shared.press(.select)
        expectation(for: NSPredicate { _, _ in (row.value as? String) != before }, evaluatedWith: NSObject())
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select) // and back, so the sample run leaves nothing changed
    }

    func testPreviewAccountCardAndSignOutConfirmation() {
        let app = launch(["-HongguoAccountPreview", "YES"])
        XCTAssertTrue(app.staticTexts["示例用户"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        let signOut = app.buttons["退出登录"]
        waitForFocus(signOut)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["退出登录？"].waitForExistence(timeout: 5), "signing out asks first")
        XCUIRemote.shared.press(.menu) // cancel: nobody is signed out
        XCTAssertTrue(app.staticTexts["示例用户"].waitForExistence(timeout: 5))
    }

    func testLoginRoute() {
        let app = launch(["-HongguoShowLogin", "YES"])
        XCTAssertTrue(app.staticTexts["登录红果账号"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["跳过"].exists)
    }

    /// After a sync that could not read a list (shown with sample data, nothing is requested):
    /// the same text as iOS under the account, and 重试同步 as a row the remote reaches.
    func testSyncFailureShowsTheTextAndARetryRow() {
        let app = launch(["-HongguoAccountPreview", "YES", "-HongguoSyncFailurePreview", "YES"])
        XCTAssertTrue(app.staticTexts["示例用户"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '同步失败'")).firstMatch.exists)
        for title in ["退出登录", "切换账号", "重试同步", "默认清晰度"] {
            XCUIRemote.shared.press(.down)
            waitForFocus(app.buttons[title])
        }
    }

    /// 追剧 shows the same text with 重试 above the lists.
    func testSyncFailureOnFollowing() {
        let app = freshLaunch(["-HongguoRoute", "following", "-HongguoAccountPreview", "YES", "-HongguoSyncFailurePreview", "YES"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '同步失败'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["重试"].exists)
    }
}

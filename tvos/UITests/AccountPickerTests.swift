import XCTest

/// 选择账号 with the three made-up sample accounts: no login behind them and no request.
final class AccountPickerTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HongguoOfflineFixtures", "YES", "-HongguoMuted", "YES", "-HongguoRoute", "accounts"]
        app.launch()
        return app
    }

    private func recommendButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '观看完整剧集'")).firstMatch
    }

    func testMostRecentHasFocusAndChoosingGoesToRecommend() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["选择账号"].waitForExistence(timeout: 10))
        for name in ["小红果", "追剧达人", "家里的电视", "添加账号"] {
            XCTAssertTrue(app.staticTexts[name].exists, "missing \(name)")
        }
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS '小红果'")).firstMatch
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: first)
        waitForExpectations(timeout: 5) // the account used last
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select) // 追剧达人
        XCTAssertTrue(recommendButton(app).waitForExistence(timeout: 10), "on to 推荐")
        XCTAssertFalse(app.staticTexts["选择账号"].exists)
    }

    func testContinueSignedOut() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["选择账号"].waitForExistence(timeout: 10))
        let signedOut = app.buttons["不登录使用"]
        XCUIRemote.shared.press(.down)
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: signedOut)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(recommendButton(app).waitForExistence(timeout: 10))
    }

    func testAddAccountOpensLogin() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["选择账号"].waitForExistence(timeout: 10))
        let add = app.buttons.matching(NSPredicate(format: "label CONTAINS '添加账号'")).firstMatch
        for _ in 0..<3 { XCUIRemote.shared.press(.right) }
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: add)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["登录红果账号"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["选择账号"].waitForExistence(timeout: 5), "back to the picker")
    }
}

import XCTest

/// 我的 and 扫码登录, offline and muted: no request is made and nobody signs in.
final class MeTests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        freshLaunch(["-HongguoRoute", "me"] + extra)
    }

    func testSignedOutCardOpensLoginAndBack() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["未登录"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["设置"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["云端观看记录"].exists)
        XCUIRemote.shared.press(.down)
        let signIn = app.buttons["扫码登录"]
        let focused = NSPredicate(format: "hasFocus == true")
        expectation(for: focused, evaluatedWith: signIn)
        waitForExpectations(timeout: 5)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["登录红果账号"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["示例数据下不能登录"].exists, "sample runs never ask the website for a code")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["未登录"].waitForExistence(timeout: 5))
    }

    func testPreviewAccountCardAndSignOutConfirmation() {
        let app = launch(["-HongguoAccountPreview", "YES"])
        XCTAssertTrue(app.staticTexts["示例用户"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["点赞"].exists)
        XCTAssertTrue(app.staticTexts["预约"].exists)
        XCUIRemote.shared.press(.down)
        let signOut = app.buttons["退出登录"]
        expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: signOut)
        waitForExpectations(timeout: 5)
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
}

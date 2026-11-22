import XCTest

/// Launches the app offline and muted from the home screen, with the previous test's app fully
/// gone: launched while tvOS is still switching away from it, the app can come up as a black,
/// half-size window and ignore the remote.
func freshLaunch(_ arguments: [String]) -> XCUIApplication {
    XCUIApplication().terminate()
    XCUIRemote.shared.press(.home)
    Thread.sleep(forTimeInterval: 1.5)
    let app = XCUIApplication()
    app.launchArguments = ["-HongguoOfflineFixtures", "YES", "-HongguoMuted", "YES"] + arguments
    app.launch()
    return app
}

@testable import HongguoCore
import XCTest

final class PlatformBehaviorTests: XCTestCase {
    func testPresets() {
        XCTAssertEqual(PlatformBehavior.mac.clientProfile, .android)
        XCTAssertTrue(PlatformBehavior.mac.authenticatedSourceFirst)
        XCTAssertTrue(PlatformBehavior.mac.websiteFallbackChannel)
        XCTAssertFalse(PlatformBehavior.mac.persistentDataDevice)
        XCTAssertEqual(PlatformBehavior.iOS.clientProfile, .ios)
        // The iOS app's EpisodeResolver asks AuthenticatedPlaybackSource itself before SeriesService.
        XCTAssertFalse(PlatformBehavior.iOS.authenticatedSourceFirst)
        XCTAssertFalse(PlatformBehavior.iOS.websiteFallbackChannel)
        XCTAssertTrue(PlatformBehavior.iOS.persistentDataDevice)
    }

    func testDefaultIsMac() {
        XCTAssertEqual(PlatformBehavior.current, .mac)
    }
}

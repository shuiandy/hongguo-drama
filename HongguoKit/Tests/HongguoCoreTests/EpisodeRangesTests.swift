import XCTest
@testable import HongguoCore

final class EpisodeRangesTests: XCTestCase {
    func testRangesOfThirty() {
        XCTAssertEqual(EpisodeRanges.ranges(total: 0), [])
        XCTAssertEqual(EpisodeRanges.ranges(total: 30), [1...30])
        XCTAssertEqual(EpisodeRanges.ranges(total: 75), [1...30, 31...60, 61...75])
        XCTAssertEqual(EpisodeRanges.label(61...75), "61-75")
        XCTAssertEqual(EpisodeRanges.index(of: 30, total: 75), 0)
        XCTAssertEqual(EpisodeRanges.index(of: 31, total: 75), 1)
        XCTAssertEqual(EpisodeRanges.index(of: 999, total: 75), 2)
    }
}

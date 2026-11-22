import XCTest
@testable import AppLogic

final class ConvertedStreamKeyTests: XCTestCase {
    func testKeyRoundTrip() {
        XCTAssertEqual(ConvertedStreamKey.make(vid: "7400001", shortSide: 720), "7400001-720")
        XCTAssertEqual(ConvertedStreamKey.make(vid: "7400001", shortSide: nil), "7400001-0")
        XCTAssertEqual(ConvertedStreamKey.vid(of: "7400001-720"), "7400001")
        XCTAssertNil(ConvertedStreamKey.vid(of: "complete"))
    }

    func testAheadConversionForNextCardIsKept() {
        // Dwelling on A while B (next) is converted ahead: B is kept, so swiping to B reuses it.
        XCTAssertFalse(ConvertedStreamKey.isStaleAhead(jobKey: "222-720", isAhead: true, keeping: ["111", "222"]))
    }

    func testAheadConversionForSkippedCardGivesWay() {
        // Fast swipes A → B → C: B's ahead conversion is for neither C nor D.
        XCTAssertTrue(ConvertedStreamKey.isStaleAhead(jobKey: "222-720", isAhead: true, keeping: ["333", "444"]))
    }

    func testViewerConversionIsNeverStale() {
        XCTAssertFalse(ConvertedStreamKey.isStaleAhead(jobKey: "222-720", isAhead: false, keeping: ["333"]))
    }

    func testShortSide() {
        XCTAssertEqual(ConvertedStreamKey.shortSide(of: "7400001-720"), 720)
        XCTAssertNil(ConvertedStreamKey.shortSide(of: "7400001-0"))
    }

    private func kept(_ key: String, _ offered: [Int]?) -> ConvertedStreamKey.Finished { .init(key: key, offered: offered) }

    func testAutomaticQualityTakesAnyKeptConversion() {
        XCTAssertEqual(ConvertedStreamKey.pick(finished: [kept("999-720", [720]), kept("111-360", [720, 360])],
                                               vid: "111", preferredShortSide: nil), "111-360")
    }

    func testChosenQualityIgnoresKeptConversionAtAnotherQuality() {
        // 360P kept, viewer switches to 720P: no kept stream, so the lookup and conversion run.
        XCTAssertNil(ConvertedStreamKey.pick(finished: [kept("111-360", [720, 360])], vid: "111", preferredShortSide: 720))
        XCTAssertEqual(ConvertedStreamKey.pick(finished: [kept("111-360", [720, 360]), kept("111-720", [720, 360])],
                                               vid: "111", preferredShortSide: 720), "111-720")
    }

    func testChoiceAboveTheSourcesBestUsesTheBestKept() {
        // 1080P chosen, the source tops out at 720P: the kept 720P is what a lookup would give.
        XCTAssertEqual(ConvertedStreamKey.pick(finished: [kept("111-720", [720, 360])], vid: "111", preferredShortSide: 1080), "111-720")
        // Choice below every tier: the lowest.
        XCTAssertEqual(ConvertedStreamKey.pick(finished: [kept("111-360", [720, 360])], vid: "111", preferredShortSide: 240), "111-360")
    }

    func testSingleTierSourceAlwaysServes() {
        XCTAssertEqual(ConvertedStreamKey.pick(finished: [kept("111-540", [])], vid: "111", preferredShortSide: 1080), "111-540")
    }

    func testFolderWithoutRecordedQualitiesNeedsExactMatch() {
        XCTAssertNil(ConvertedStreamKey.pick(finished: [kept("111-360", nil)], vid: "111", preferredShortSide: 720))
        XCTAssertEqual(ConvertedStreamKey.pick(finished: [kept("111-720", nil)], vid: "111", preferredShortSide: 720), "111-720")
    }

    func testOtherEpisodeWithSharedPrefixIsNotPicked() {
        XCTAssertNil(ConvertedStreamKey.pick(finished: [kept("1111-360", nil)], vid: "111", preferredShortSide: nil))
    }
}

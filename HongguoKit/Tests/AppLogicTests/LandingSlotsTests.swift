import XCTest
@testable import AppLogic

final class LandingSlotsTests: XCTestCase {
    private struct Entry: Codable, Equatable {
        var tab: String
        var title: String
    }

    func testEachChannelKeepsItsOwnEntry() throws {
        var data = LandingSlots.storing(Entry(tab: "recommend", title: "A"), tab: "recommend", in: nil) { $0.tab }
        data = LandingSlots.storing(Entry(tab: "real", title: "B"), tab: "real", in: data) { $0.tab }
        let slots = LandingSlots.decode(try XCTUnwrap(data), as: Entry.self) { $0.tab }
        XCTAssertEqual(slots["recommend"]?.title, "A")
        XCTAssertEqual(slots["real"]?.title, "B")
    }

    func testSavingAChannelReplacesOnlyThatChannel() throws {
        var data = LandingSlots.storing(Entry(tab: "recommend", title: "A"), tab: "recommend", in: nil) { $0.tab }
        data = LandingSlots.storing(Entry(tab: "real", title: "B"), tab: "real", in: data) { $0.tab }
        data = LandingSlots.storing(Entry(tab: "real", title: "C"), tab: "real", in: data) { $0.tab }
        let slots = LandingSlots.decode(try XCTUnwrap(data), as: Entry.self) { $0.tab }
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots["recommend"]?.title, "A")
        XCTAssertEqual(slots["real"]?.title, "C")
    }

    func testLegacySingleEntryLandsInItsOwnTab() throws {
        let legacy = try JSONEncoder().encode(Entry(tab: "real", title: "Old"))
        let slots = LandingSlots.decode(legacy, as: Entry.self) { $0.tab }
        XCTAssertEqual(slots, ["real": Entry(tab: "real", title: "Old")])
        // Saving another channel on top of a legacy file keeps the legacy entry.
        let merged = LandingSlots.storing(Entry(tab: "recommend", title: "New"), tab: "recommend", in: legacy) { $0.tab }
        let both = LandingSlots.decode(try XCTUnwrap(merged), as: Entry.self) { $0.tab }
        XCTAssertEqual(both["real"]?.title, "Old")
        XCTAssertEqual(both["recommend"]?.title, "New")
    }

    func testUnreadableDataIsEmpty() {
        XCTAssertTrue(LandingSlots.decode(Data("nope".utf8), as: Entry.self) { $0.tab }.isEmpty)
    }
}

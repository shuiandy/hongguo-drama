import AppLogic
import XCTest

final class DislikeStoreTests: XCTestCase {
    func testAddDeduplicatesAndMovesToFront() {
        let step1 = DislikeStore.add("100", to: [])
        let step2 = DislikeStore.add("200", to: step1)
        let step3 = DislikeStore.add("100", to: step2)
        XCTAssertEqual(step3, ["100", "200"])
    }

    func testRespectsLimit() {
        var list: [String] = []
        for i in 1...5 {
            list = DislikeStore.add("\(i)", to: list, limit: 3)
        }
        XCTAssertEqual(list, ["5", "4", "3"])
    }

    func testRemoveAndRoundTripEncodeDecode() {
        let list = ["7703788255090592792", "7675312158082616345"]
        let encoded = DislikeStore.encode(list)
        XCTAssertEqual(DislikeStore.decode(encoded), list)
        XCTAssertEqual(DislikeStore.remove("7703788255090592792", from: list), ["7675312158082616345"])
    }
}

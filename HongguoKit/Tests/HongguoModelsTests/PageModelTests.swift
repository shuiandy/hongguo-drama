import AppLogic
import XCTest
@testable import HongguoCore
@testable import HongguoModels

// Page models over the offline FixtureBackend: no network.

@MainActor
final class TheaterModelTests: XCTestCase {
    func testLoadPagesAndFilterChange() async {
        let model = TheaterModel(backend: FixtureBackend())
        await model.load(forceRefresh: false)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.items.count, 18)
        XCTAssertEqual(model.genres.count, 3)
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 36)
        XCTAssertEqual(Set(model.items.map(\.seriesId)).count, 36)
        XCTAssertFalse(model.hasMore)
        await model.loadMore() // nothing more to load
        XCTAssertEqual(model.items.count, 36)

        model.genre = model.genres.first
        XCTAssertNotEqual(model.filterKey, "real-drama|")
        model.kind = .comicDrama
        XCTAssertNil(model.genre, "a new category clears the genre")
        XCTAssertTrue(model.genres.isEmpty)
        await model.load(forceRefresh: false)
        XCTAssertEqual(model.items.first?.seriesId, "fixture-comic-drama-1")
    }
}

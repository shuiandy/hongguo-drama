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

@MainActor
final class RankingModelTests: XCTestCase {
    func testOfflineCategoriesListsAndChoices() async {
        let model = RankingModel(backend: FixtureBackend())
        let first = model.key(for: model.selectedCategoryId)
        XCTAssertTrue(model.rankPages.needsLoad(first))
        await model.load(first)
        XCTAssertEqual(model.categories.map(\.id), ["all", "comic_series_rank", "human", "ai_playlet"])
        XCTAssertEqual(model.rankPages.page(first).items.count, 18)
        XCTAssertFalse(model.rankPages.needsLoad(first))

        model.selectBoard("ranklist_hot_play_sc")
        XCTAssertEqual(model.selectedPanelId, "")
        model.selectedPanelId = "gender_female"
        XCTAssertEqual(model.activeFilterTitle, "女频")
        model.selectCategory(model.categories[2])
        XCTAssertEqual(model.selectedCategoryId, "human")
        XCTAssertEqual(model.selectedBoardId, "ranklist_hot_sc", "a new category opens on its first 榜单")
        XCTAssertEqual(model.selectedPanelId, "")
        // The first list is still kept for going back.
        XCTAssertEqual(model.rankPages.page(first).items.count, 18)
    }
}

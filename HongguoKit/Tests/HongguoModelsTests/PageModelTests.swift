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

@MainActor
final class NewReleasesModelTests: XCTestCase {
    func testNewDramaOffline() async {
        let model = NewDramaModel(backend: FixtureBackend())
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.items.count, 10)
        XCTAssertFalse(model.hasMore)
        await model.loadMore() // offline: nothing more
        XCTAssertEqual(model.items.count, 10)
    }

    func testCalendarOfflineAndFilter() async {
        let model = CalendarModel(backend: FixtureBackend())
        XCTAssertFalse(model.days.isEmpty)
        XCTAssertFalse(model.selectedDate.isEmpty, "today is chosen")
        await model.load()
        XCTAssertEqual(model.items.count, 10)
        XCTAssertEqual(model.items.filter(\.isOnline).count, 5)
        XCTAssertEqual(model.filtered.count, 10)
        model.filter = .comic
        XCTAssertTrue(model.filtered.isEmpty, "sample rows carry no category")
    }
}

@MainActor
final class SeriesDetailModelTests: XCTestCase {
    func testOfflineSeriesPage() async {
        let item = FixtureBackend.summary(2)
        let model = SeriesDetailModel(item: item)
        XCTAssertEqual(model.release, .unknown)
        await model.load(using: FixtureBackend())
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.release, .released)
        XCTAssertEqual(model.total, item.episodeCount)
        XCTAssertEqual(model.social?.commentTotal, 422)
        await model.loadExtras(using: FixtureBackend())
        XCTAssertEqual(model.reviews?.rating, 8.6)
        XCTAssertFalse(model.related.contains { $0.seriesId == item.seriesId })
    }

    func testUpcomingAndBaseTitle() {
        var item = FixtureBackend.summary(3)
        item.episodeLabel = SeriesDetailModel.upcomingLabel
        XCTAssertEqual(SeriesDetailModel(item: item).release, .upcoming)
        XCTAssertEqual(SeriesDetailModel.baseTitle("龙王殿第二季：归来"), "龙王殿")
    }
}

@MainActor
final class CelebrityModelTests: XCTestCase {
    /// Offline there is no actor home page: nothing is requested and nothing is shown as failed.
    func testOfflineReadsNothing() async {
        let member = EpisodeSocial.CastMember(id: "a1", name: "示例演员", role: "主演", avatar: "", profileUserId: "123")
        let model = CelebrityModel(member: member)
        await model.loadHome(using: FixtureBackend())
        XCTAssertNil(model.home)
        XCTAssertNil(model.homeError)
        XCTAssertFalse(model.homeLoading)
        XCTAssertNil(model.listKey)
    }
}

@MainActor
final class CommentListModelTests: XCTestCase {
    func testOfflineCommentsAndReplies() async throws {
        let model = CommentListModel()
        let total = await model.load(seriesId: "fixture-1", vid: "fixture-1-ep1", using: FixtureBackend())
        XCTAssertEqual(total, 422)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.comments.count, 8)
        XCTAssertFalse(model.hasMore, "offline: no further pages")
        let first = try XCTUnwrap(model.comments.first)
        await model.loadReplies(for: first)
        XCTAssertEqual(model.replyThreads[first.id]?.replies.count, 3)
        model.collapseReplies(of: first.id)
        // Another episode drops the threads.
        _ = await model.load(seriesId: "fixture-1", vid: "fixture-1-ep2", using: FixtureBackend())
        XCTAssertTrue(model.replyThreads.isEmpty)
    }
}

@MainActor
final class EpisodePanelModelTests: XCTestCase {
    func testRangeFollowsTheEpisodeAndMoreSeasons() async {
        let model = EpisodePanelModel(episode: 45, total: 80)
        XCTAssertEqual(model.range(total: 80), 31...60)
        model.rangeIndex = 0
        XCTAssertEqual(model.range(total: 80), 1...30)
        model.follow(episode: 70, total: 80)
        XCTAssertEqual(model.range(total: 80), 61...80)
        model.rangeIndex = 9
        XCTAssertEqual(model.range(total: 80), 61...80, "clamped")
        await model.loadTags(seriesId: "fixture-1", vid: "fixture-1-ep1", using: FixtureBackend())
        XCTAssertEqual(model.tags, ["都市", "逆袭"])
        await model.loadMore(seriesId: "fixture-search-1", title: "重生之我在豪门当保姆", using: FixtureBackend())
        XCTAssertEqual(model.more.count, 5)
    }
}

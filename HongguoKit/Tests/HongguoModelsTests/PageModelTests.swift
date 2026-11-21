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

@MainActor
final class SearchAndMeModelTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "SearchModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testSearchHistoryBoardsAndResults() async {
        let defaults = suite()
        let model = SearchModel(backend: FixtureBackend(), defaults: defaults)
        await model.loadBoard(.hotSearch)
        XCTAssertEqual(model.rankLists[.hotSearch]?.count, 18)
        await model.loadBoard(.subscribe)
        XCTAssertEqual(model.rankLists[.subscribe]?.count, 0, "offline: only 热搜榜 has sample rows")
        await model.loadBoard(.hotTopic)
        XCTAssertEqual(model.hotTopics?.count, 0)
        await model.loadSearchLanding()
        XCTAssertEqual(model.suggestions.count, 3)

        model.submitSearch("  龙王殿 ")
        XCTAssertEqual(model.submittedQuery, "龙王殿")
        XCTAssertEqual(model.history.first, "龙王殿")
        XCTAssertEqual(SearchModel(backend: FixtureBackend(), defaults: defaults).history.first, "龙王殿", "kept in defaults")
        for _ in 0..<50 where model.phase != .loaded { await Task.yield() }
        XCTAssertEqual(model.results.count, 6)
        model.queryChanged("")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.phase, .idle)
        model.removeHistory("龙王殿")
        XCTAssertTrue(model.history.isEmpty)
    }

    func testMeListsSignedOut() {
        let library = LibraryModel(offline: true, account: AccountModel(mode: .offline), backend: FixtureBackend(), defaults: suite())
        let me = MeModel(library: library, account: library.account)
        XCTAssertEqual(me.history.count, 4)
        me.filter = .finished
        XCTAssertEqual(me.history.count, 2, "two sample series are watched to the end")
        XCTAssertEqual(me.localFavorites.count, 3)
        XCTAssertTrue(me.accountShelf.isEmpty)
        XCTAssertTrue(me.onlineReservations.isEmpty)
        // 删除记录 signed out: the device's row only, no account write.
        me.filter = .all
        let first = me.history[0]
        me.deleteHistory(first)
        XCTAssertFalse(me.history.contains { $0.seriesId == first.seriesId })
    }

    func testMeListsPreviewAccount() {
        let account = AccountModel(mode: .preview)
        let library = LibraryModel(offline: true, account: account, backend: FixtureBackend(), defaults: suite())
        let me = MeModel(library: library, account: account)
        XCTAssertTrue(me.localFavorites.isEmpty, "signed in: the account's lists")
        XCTAssertEqual(me.accountShelf.count, 1)
        XCTAssertEqual(me.likes.account.count, 1)
        XCTAssertEqual(me.upcomingReservations.count, 1)
        XCTAssertTrue(me.history.contains { $0.fromAccount })
    }
}

@MainActor
final class AccountRosterTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "AccountRosterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func login(_ id: String, _ name: String) -> AccountCredentials {
        AccountCredentials(cookie: "sessionid=\(id)", profile: AccountProfile(id: id, nickname: name))
    }

    /// An earlier single login becomes the first entry; a sign-in adds the next and makes it current.
    func testMigrateAndRememberAndPersist() {
        let defaults = suite()
        let vault = MemoryVault()
        let current = MemoryVault.Current(login("111", "甲"))
        let roster = AccountRoster(defaults: defaults, vault: vault, current: current)
        roster.migrateIfNeeded()
        XCTAssertEqual(roster.entries.map(\.id), ["111"])
        XCTAssertEqual(roster.currentId, "111")
        XCTAssertEqual(try vault.load("111")?.cookie, "sessionid=111")

        try? current.save(login("222", "乙"))
        roster.rememberCurrent(avatar: "https://example.invalid/b.png")
        XCTAssertEqual(roster.mostRecent?.id, "222", "the newest login is chosen by default")
        XCTAssertEqual(roster.currentId, "222")
        roster.migrateIfNeeded() // not empty: nothing happens
        XCTAssertEqual(roster.entries.count, 2)

        let reopened = AccountRoster(defaults: defaults, vault: vault, current: current)
        XCTAssertEqual(reopened.entries.map(\.id), ["222", "111"])
        XCTAssertEqual(reopened.currentId, "222")
        XCTAssertEqual(reopened.entries.first?.avatar, "https://example.invalid/b.png")
    }

    /// Switching goes through the sign-in steps: a new session, so anything holding the old token
    /// (queued writes, in-flight reads) is no longer accepted.
    func testSwitchChangesTheSessionAndRemoveSignsOutLocally() async {
        let vault = MemoryVault()
        let current = MemoryVault.Current()
        let roster = AccountRoster(defaults: suite(), vault: vault, current: current)
        let account = AccountModel(mode: .preview)
        try? current.save(login("111", "甲")); roster.rememberCurrent()
        try? current.save(login("222", "乙")); roster.rememberCurrent()
        let before = account.session.current
        let ok = await roster.switchTo(roster.entries.first { $0.id == "111" }!, account: account)
        XCTAssertTrue(ok)
        XCTAssertEqual(account.profile?.id, "111")
        XCTAssertEqual(roster.currentId, "111")
        XCTAssertEqual(roster.mostRecent?.id, "111")
        let after = account.session.current
        XCTAssertNotEqual(before, after)
        if let before { XCTAssertFalse(account.session.accepts(before), "the old session's writes are dropped") }

        await roster.remove(roster.entries.first { $0.id == "111" }!, account: account)
        XCTAssertEqual(roster.entries.map(\.id), ["222"])
        XCTAssertNil(try vault.load("111"))
        XCTAssertNil(roster.currentId)
        XCTAssertFalse(account.isSignedIn, "removing the current account leaves it signed out, on this device only")
    }

    func testSamplesAreInMemoryOnly() {
        let roster = AccountRoster.samples()
        XCTAssertEqual(roster.entries.count, 3)
        XCTAssertEqual(roster.mostRecent?.nickname, "小红果")
    }
}

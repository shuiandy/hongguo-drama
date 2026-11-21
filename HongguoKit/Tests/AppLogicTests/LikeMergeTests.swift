import XCTest
@testable import AppLogic

final class LikeMergeTests: XCTestCase {
    struct Local { var seriesId: String; var likedVids: [String] }
    struct Account: Equatable { var seriesId: String; var episode: Int; var category: String; var vid = "" }

    private func merge(_ local: [Local], _ account: [Account], categories: [String: String] = [:], selected: String?) -> LikeMerge.Merged<Local, Account> {
        LikeMerge.merge(local: local, account: account, localSeries: \.seriesId,
                        accountSeries: \.seriesId, accountVid: \.vid, accountEpisode: \.episode, accountCategory: \.category,
                        categories: categories, selected: selected)
    }

    func testAccountLikeOnOtherEpisodeStaysNextToLocalLike() {
        // Local like of episode 1, account like of episode 22 of the same show.
        let local = [Local(seriesId: "s", likedVids: ["v1"])]
        let account = [Account(seriesId: "s", episode: 22, category: "漫剧")]
        let all = merge(local, account, selected: nil)
        XCTAssertEqual(all.local.count, 1)
        XCTAssertEqual(all.account, account)
        let comic = merge(local, account, selected: "漫剧")
        XCTAssertEqual(comic.account, account)
        // The local entry is found on the category page too, through the account's category.
        XCTAssertEqual(comic.local.map(\.category), ["漫剧"])
    }

    func testLocalEntryWithUnknownCategoryOnlyUnderAll() {
        let local = [Local(seriesId: "x", likedVids: ["v"])]
        XCTAssertEqual(merge(local, [], selected: nil).local.map(\.category), [""])
        XCTAssertTrue(merge(local, [], selected: "真人剧").local.isEmpty)
    }

    func testCategoryFromOtherAccountLists() {
        let local = [Local(seriesId: "x", likedVids: ["v"])]
        let real = merge(local, [], categories: ["x": "真人剧"], selected: "真人剧")
        XCTAssertEqual(real.local.map(\.category), ["真人剧"])
    }

    func testRepeatedAccountRowForOneEpisodeShowsOnce() {
        let row = Account(seriesId: "s", episode: 3, category: "")
        XCTAssertEqual(merge([], [row, row, Account(seriesId: "s", episode: 4, category: "")], selected: nil).account.count, 2)
    }

    func testMissingEpisodeNumbersDoNotMergeDifferentVids() {
        let a = Account(seriesId: "s", episode: 0, category: "", vid: "22")
        let b = Account(seriesId: "s", episode: 0, category: "", vid: "63")
        XCTAssertEqual(merge([], [a, b, a], selected: nil).account, [a, b])
    }

    func testCategoryPageFiltersAccountRows() {
        let account = [Account(seriesId: "a", episode: 1, category: "漫剧"), Account(seriesId: "b", episode: 1, category: "真人剧")]
        XCTAssertEqual(merge([], account, selected: "真人剧").account.map(\.seriesId), ["b"])
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Opt-in live check that catalogue, episodes, details, comments and search answer from the App:
/// `HONGGUO_LIVE=1 swift test --filter AppDataLiveTests`. Read-only, about ten requests.
/// Prints counts and milliseconds only.
final class AppDataLiveTests: XCTestCase {
    private func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    func testAppPathsAnswer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var report: [String] = []
        var t = Date()
        let ranking = try await DiscoveryAccess.catalog(kind: .hotDrama, forceRefresh: true)
        report.append("App ranking: \(ranking.items.count) items, \(ms(t)) ms")
        XCTAssertFalse(ranking.items.isEmpty)
        t = Date()
        let catalog = CatalogService()
        let page1 = try await catalog.browse(kind: .hotDrama, page: 1, forceRefresh: true)
        t = Date()
        let page2 = try await catalog.browse(kind: .hotDrama, page: 2, forceRefresh: true)
        let overlap = Set(page1.results.map(\.seriesId)).intersection(page2.results.map(\.seriesId)).count
        report.append("CatalogService ranking: page 1 \(page1.results.count) (of \(page1.totalPages) pages), page 2 \(page2.results.count), overlap \(overlap), ranks \(page2.results.first?.rank ?? 0)..., \(ms(t)) ms")
        XCTAssertEqual(overlap, 0)
        t = Date()
        let category = try await DiscoveryAccess.catalog(kind: .realDrama, forceRefresh: true)
        report.append("App category 真人剧: \(category.items.count) items, \(category.genres.count) themes, \(ms(t)) ms")
        XCTAssertFalse(category.items.isEmpty)
        if let theme = category.genres.first {
            t = Date()
            let themed = try await CatalogService().browse(kind: .realDrama, genre: theme.slug, forceRefresh: true)
            report.append("CatalogService theme \(theme.label): \(themed.results.count) items, \(ms(t)) ms")
        }

        let series = try XCTUnwrap(ranking.items.first(where: { $0.episodeCount >= 10 }) ?? ranking.items.first)
        t = Date()
        let app = try await SeriesService().episodes(seriesId: series.seriesId, force: true)
        report.append("SeriesService episodes (App detail): \(app.episodes.count) of \(series.episodeCount), \(ms(t)) ms")
        XCTAssertFalse(app.episodes.isEmpty)

        t = Date()
        let details = try await SeriesService().publicDetails(seriesId: series.seriesId)
        report.append("details: intro \(details.description.count) chars, favorites \(details.favoriteCount.map(String.init) ?? "-"), reviews \(details.reviews.count), published \(details.publishedAt != nil), \(ms(t)) ms")
        XCTAssertFalse(details.description.isEmpty)

        let vid = try XCTUnwrap(app.episodes.first?.vid)
        t = Date()
        let social = try await EpisodeSocialService.load(seriesId: series.seriesId, vid: vid)
        report.append("episode panel: likes \(social.episodeLikes.map(String.init) ?? "-"), favorites \(social.favoriteCount.map(String.init) ?? "-"), tags \(social.tags.count), cast \(social.cast.count), comments \(social.comments.count), \(ms(t)) ms")
        XCTAssertNotNil(social.episodeLikes)
        XCTAssertNotNil(social.favoriteCount)
        t = Date()
        let page = try await EpisodeSocialService.commentsPage(seriesId: series.seriesId, vid: vid, count: 20)
        report.append("App comments: \(page.comments.count) of \(page.total.map(String.init) ?? "?"), more \(page.hasMore), \(ms(t)) ms")
        t = Date()
        let comments = try await EpisodeCommentService().comments(seriesId: series.seriesId, vid: vid)
        report.append("EpisodeCommentService: \(comments.items.count) items, \(ms(t)) ms")

        let keyword = String(series.title.prefix(4))
        t = Date()
        let found = try await AppSearchService().search(keyword)
        report.append("search: \(found.results.count) results, \(ms(t)) ms")
        XCTAssertFalse(found.results.isEmpty)
        print("APP-DATA-LIVE\n" + report.joined(separator: "\n"))
    }
}

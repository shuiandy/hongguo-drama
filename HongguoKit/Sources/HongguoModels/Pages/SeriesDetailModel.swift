import Foundation
import HongguoCore
import HongguoPlayback
import Observation

/// A series page's data: the episode list, the public figures (episode 1's social page), the
/// reviews with their further pages, related series and whether the series is out. Moved
/// unchanged from the iOS SeriesDetailView. The loaders take the backend, so the page can make the
/// model before it has one.
@MainActor
@Observable
public final class SeriesDetailModel {
    public enum Release: Sendable { case unknown, released, upcoming }

    /// Set as `episodeLabel` by a 待上线 card (上新日历) that opens this page: the episode list of a
    /// series that is not out yet cannot be read, so the failure alone does not tell.
    public static let upcomingLabel = "待上线"

    public let item: SeriesSummary
    public let isUpcoming: Bool
    public private(set) var social: EpisodeSocial?
    public private(set) var reviews: SeriesReviews?
    public private(set) var extraReviews: [EpisodeSocial.Comment] = []
    public private(set) var reviewCursor = ""
    public private(set) var hasMoreReviews = false
    public private(set) var loadingMoreReviews = false
    public private(set) var related: [SeriesSummary] = []
    public private(set) var total = 0
    public private(set) var phase: LoadPhase = .loading
    /// Whether the series is out: known once its episode list has loaded. 预约 is for a series
    /// that is not out yet; a series that can be played offers 收藏 only.
    public private(set) var release: Release
    /// The episode list, once loaded.
    public private(set) var episodes: [DramaEpisode] = []

    public init(item: SeriesSummary, isUpcoming: Bool = false) {
        self.item = item
        self.isUpcoming = isUpcoming
        release = (isUpcoming || item.episodeLabel == Self.upcomingLabel) ? .upcoming : .unknown
    }

    /// The part of a title that other seasons share: up to the first colon, without "第N季".
    public static func baseTitle(_ title: String) -> String {
        var text = title
        if let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }), text.distance(from: text.startIndex, to: colon) >= 2 {
            text = String(text[..<colon])
        }
        if let season = text.range(of: "第[一二三四五六七八九十0-9]+[季部]", options: .regularExpression) {
            text.removeSubrange(season)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func loadExtras(using backend: any DramaBackend) async {
        extraReviews = []
        reviewCursor = ""
        hasMoreReviews = false
        async let fetchedReviews = try? backend.reviews(seriesId: item.seriesId)
        let keyword = Self.baseTitle(item.title)
        async let found = keyword.count >= 2 ? (try? backend.search(keyword)) : nil
        let loadedReviews = await fetchedReviews
        guard !Task.isCancelled else { return }
        reviews = loadedReviews
        reviewCursor = loadedReviews?.nextCursor ?? ""
        hasMoreReviews = (loadedReviews?.hasMoreReviews ?? false) && !reviewCursor.isEmpty
        related = Array((await found ?? []).filter { $0.seriesId != item.seriesId }.prefix(10))
        CoverPrefetch.prefetch(related.map(\.cover))
    }

    public func loadMoreReviews(using backend: any DramaBackend) async {
        guard hasMoreReviews, !loadingMoreReviews, !reviewCursor.isEmpty, !backend.isOffline else { return }
        let requestedCursor = reviewCursor
        loadingMoreReviews = true
        defer { loadingMoreReviews = false }
        guard let page = try? await EpisodeSocialService.moreReviews(seriesId: item.seriesId, cursor: requestedCursor),
              !Task.isCancelled, reviewCursor == requestedCursor else { return }
        let seen = Set((reviews?.reviews ?? []).map(\.id) + extraReviews.map(\.id))
        let added = page.comments.filter { !seen.contains($0.id) }
        extraReviews.append(contentsOf: added)
        reviewCursor = page.cursor
        hasMoreReviews = page.hasMore && !page.cursor.isEmpty && page.cursor != requestedCursor && !added.isEmpty
    }

    public func load(using backend: any DramaBackend) async {
        social = nil
        episodes = []
        total = 0
        release = (isUpcoming || item.episodeLabel == Self.upcomingLabel) ? .upcoming : .unknown
        phase = .loading
        do {
            let series = try await backend.series(seriesId: item.seriesId)
            guard !Task.isCancelled else { return }
            total = series.total
            release = series.episodes.isEmpty ? .upcoming : .released
            episodes = series.episodes
            guard let vid = series.episodes.first?.vid else { phase = .loaded; return }
            social = try await backend.social(seriesId: item.seriesId, vid: vid)
            guard !Task.isCancelled else { return }
            phase = .loaded
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            // No episode list: a series opened from an upcoming card is not out yet. Any other series
            // keeps only 收藏 (a failed request does not make it upcoming).
            if isUpcoming || item.episodeLabel == Self.upcomingLabel {
                release = .upcoming
                phase = .loaded
            } else {
                phase = .failed(describeError(error))
            }
        }
    }
}

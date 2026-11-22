import Foundation
import HongguoCore
import Observation

/// 选集: which range of episodes is shown (it follows the episode playing and the series' length),
/// the series' tags from the episode's public page, and other seasons to offer ("更多"). Moved
/// unchanged from the iOS EpisodeLowerPanel; picking episodes to download stays in the app.
@MainActor
@Observable
public final class EpisodePanelModel {
    public var rangeIndex: Int
    public private(set) var tags: [String] = []
    public private(set) var more: [SeriesSummary] = []

    public init(episode: Int, total: Int) {
        rangeIndex = EpisodeRanges.index(of: episode, total: total)
    }

    public func ranges(total: Int) -> [ClosedRange<Int>] { EpisodeRanges.ranges(total: total) }

    /// The range shown, clamped to the ranges there are.
    public func range(total: Int) -> ClosedRange<Int>? {
        let all = ranges(total: total)
        guard !all.isEmpty else { return nil }
        return all[min(rangeIndex, all.count - 1)]
    }

    /// Back to the range holding the episode playing (after another episode or a new total).
    public func follow(episode: Int, total: Int) {
        rangeIndex = EpisodeRanges.index(of: episode, total: total)
    }

    public func loadTags(seriesId: String, vid: String?, using backend: any DramaBackend) async {
        guard let vid,
              let social = try? await backend.social(seriesId: seriesId, vid: vid),
              !Task.isCancelled else { return }
        tags = social.tags
    }

    public func loadMore(seriesId: String, title: String, using backend: any DramaBackend) async {
        more = []
        let keyword = SeriesDetailModel.baseTitle(title)
        guard keyword.count >= 2, let found = try? await backend.search(keyword), !Task.isCancelled else { return }
        more = Array(found.filter { $0.seriesId != seriesId }.prefix(9))
    }
}

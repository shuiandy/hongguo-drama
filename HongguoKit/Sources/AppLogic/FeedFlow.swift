import Foundation

/// What the home feed plays next. The feed shows one clip per series (episode 1); tapping
/// 观看完整剧集 switches to series mode, which walks through that series episode by episode.
/// The views send events and carry out the returned command; no playback code lives here.
public struct FeedFlow: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case feed
        /// 1-based episode number and the series length.
        case series(episode: Int, total: Int)
    }

    public enum Command: Equatable, Sendable {
        case none
        /// Scroll to and play this feed item (0-based).
        case showFeedItem(Int)
        /// Play this episode (1-based) of the series being watched.
        case playEpisode(Int)
        /// Nothing follows: play the current clip again from the start.
        case replay
        /// The last episode of the series ended.
        case seriesFinished
    }

    public private(set) var mode: Mode = .feed
    public private(set) var feedIndex = 0
    public private(set) var feedCount: Int

    /// Ask for more feed items when this few remain after the current one.
    public static let refillThreshold = 4

    public init(feedCount: Int = 0) {
        self.feedCount = max(0, feedCount)
    }

    public var isSeriesMode: Bool { mode != .feed }
    public var needsMoreItems: Bool { feedCount - feedIndex - 1 < Self.refillThreshold }

    public mutating func setFeedCount(_ count: Int) {
        feedCount = max(0, count)
        feedIndex = min(feedIndex, max(0, feedCount - 1))
    }

    /// The user swiped to another feed item. Ignored while a series is playing.
    public mutating func userPaged(to index: Int) -> Command {
        guard mode == .feed, feedCount > 0 else { return .none }
        let target = min(max(0, index), feedCount - 1)
        guard target != feedIndex else { return .none }
        feedIndex = target
        return .showFeedItem(target)
    }

    public mutating func enterSeries(total: Int, startEpisode: Int = 1) -> Command {
        guard total > 0 else { return .none }
        let start = min(max(1, startEpisode), total)
        mode = .series(episode: start, total: total)
        return .playEpisode(start)
    }

    public mutating func selectEpisode(_ episode: Int) -> Command {
        guard case .series(_, let total) = mode, (1...total).contains(episode) else { return .none }
        mode = .series(episode: episode, total: total)
        return .playEpisode(episode)
    }

    /// Back to the feed, on the item the series was opened from.
    public mutating func exitSeries() -> Command {
        guard isSeriesMode else { return .none }
        mode = .feed
        return feedCount > 0 ? .showFeedItem(feedIndex) : .none
    }

    /// The clip or episode played to its end.
    public mutating func clipEnded() -> Command {
        advance(replayAtEnd: true)
    }

    /// The clip or episode cannot be played (for example ByteVC2 only): move on without replaying.
    public mutating func skipUnplayable() -> Command {
        advance(replayAtEnd: false)
    }

    /// A feed card found unplayable a moment ago is skipped only if the viewer is still on it:
    /// a delayed skip that lands after they swiped on must not skip the card they moved to.
    public mutating func skipUnplayable(fromFeedItem index: Int) -> Command {
        guard mode == .feed, feedIndex == index else { return .none }
        return skipUnplayable()
    }

    private mutating func advance(replayAtEnd: Bool) -> Command {
        switch mode {
        case .feed:
            guard feedIndex + 1 < feedCount else { return replayAtEnd && feedCount > 0 ? .replay : .none }
            feedIndex += 1
            return .showFeedItem(feedIndex)
        case .series(let episode, let total):
            guard episode < total else { return .seriesFinished }
            mode = .series(episode: episode + 1, total: total)
            return .playEpisode(episode + 1)
        }
    }
}

/// Builds one feed tab from several lists (ranking, new releases, catalogue): duplicates are
/// dropped and the order is shuffled with a seed, so a test can pin the result.
public enum FeedMixer {
    public static func mix<ID: Hashable>(_ lists: [[ID]], seed: UInt64) -> [ID] {
        var seen = Set<ID>()
        var merged: [ID] = []
        for id in lists.joined() where seen.insert(id).inserted { merged.append(id) }
        var generator = SplitMix64(seed: seed)
        merged.shuffle(using: &generator)
        return merged
    }
}

/// Small deterministic generator (SplitMix64) for repeatable shuffles.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

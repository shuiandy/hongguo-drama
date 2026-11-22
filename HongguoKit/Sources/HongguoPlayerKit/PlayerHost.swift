#if canImport(UIKit)
import Foundation
import HongguoCore
import HongguoModels

/// A request to open the player page.
public struct PlayerTarget: Identifiable, Equatable {
    public var instanceID = UUID()
    public var seriesId: String
    public var title: String
    public var cover: String
    /// nil: resume from history, else episode 1.
    public var startEpisode: Int?
    public var startAt: Double = 0
    /// Set when `startEpisode` comes from a history row: when that row was written. A newer record
    /// on this device or in the account (read again on opening) wins over it.
    public var resumeHintAt: Date?
    /// Opened from the clip that is already playing: keep playing it, do not load again.
    public var continuesCurrentClip = false
    /// Opened from feed "观看完整剧集": keep current clip unless watch history is ahead on a later episode.
    public var resumeIfAheadOfCurrentClip = false
    public var id: UUID { instanceID }

    public init(seriesId: String, title: String, cover: String, startEpisode: Int? = nil, startAt: Double = 0,
                resumeHintAt: Date? = nil, continuesCurrentClip: Bool = false, resumeIfAheadOfCurrentClip: Bool = false) {
        self.seriesId = seriesId
        self.title = title
        self.cover = cover
        self.startEpisode = startEpisode
        self.startAt = startAt
        self.resumeHintAt = resumeHintAt
        self.continuesCurrentClip = continuesCurrentClip
        self.resumeIfAheadOfCurrentClip = resumeIfAheadOfCurrentClip
    }
}

/// What the player page was on when it closed, for the feed to carry on with: the same episode in
/// the same player, not episode 1 again.
public struct PlayerHandoff: Equatable {
    public var seriesId: String
    public var episode: Int
    public var vid: String

    public init(seriesId: String, episode: Int, vid: String) {
        self.seriesId = seriesId
        self.episode = episode
        self.vid = vid
    }
}

/// What `PlaybackSession` and `FeedModel` need from the app that holds them: the shared models,
/// the one foreground player, the handoff between the player page and the feed, and opening the
/// player. The iOS `AppModel` and the tvOS app model both are one.
@MainActor
public protocol PlayerHost: AnyObject {
    var backend: any DramaBackend { get }
    var account: AccountModel { get }
    var library: LibraryModel { get }
    /// The foreground player; the feed swaps in another engine (with the same hooks) when it parks a clip.
    var player: PlayerEngine { get set }
    var playerHandoff: PlayerHandoff? { get set }
    func openPlayer(_ summary: SeriesSummary, startEpisode: Int?, startAt: Double,
                    continuesCurrentClip: Bool, resumeIfAheadOfCurrentClip: Bool)
}
#endif

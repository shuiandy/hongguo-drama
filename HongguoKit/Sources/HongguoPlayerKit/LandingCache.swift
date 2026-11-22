#if canImport(UIKit)
import AppLogic
import Foundation
import HongguoCore
import HongguoPlayback

/// What the next launch starts with: the clips that were still ahead in the feed when the app
/// was last used, and the resolved source of the first of them. With it a cold start shows a
/// clip at once and only has to open its header before playing.
///
/// One entry per feed channel (`LandingSlots`), so the channel the app opens on keeps its own
/// clip whichever channel was used last. Kept in the app's Caches folder (the system may clear it). The source holds a signed address
/// and a content key, so nothing from here is ever logged.
public struct LandingCache: Codable {
    public struct Row: Codable {
        public var series: SeriesSummary
        public var firstVid: String?
        public var commentCount: Int?
    }

    public var savedAt: Date
    public var tab: String
    public var rows: [Row]
    /// Schema/feed generation tag so clips cached before a feed-channel fix are discarded on upgrade.
    public var cacheVersion: Int? = LandingCache.currentVersion
    /// Signed-in account ID this clip was fetched under (`nil` for anonymous).
    public var accountId: String?
    /// `PlayInfoArchive` bytes for the first row's episode, with the quality it was resolved for.
    public var source: Data?
    public var sourceVid: String?
    public var sourceShortSide: Int?
    public var sourceSavedAt: Date?
    /// True server-derived expiration timestamp for `source` (Codex #7).
    public var sourceExpiresAt: Date?

    public static let currentVersion = 3
    /// Keep the saved landing clip metadata across overnight/multi-day gaps so cold starts open
    /// directly onto a clip (and reuse its disk media prefix) instead of waiting 3-4s on the feed
    /// API. Signed playback URLs are still checked independently via `freshSource()` (`sourceExpiresAt`).
    public static let rowsLifetime: TimeInterval = 7 * 24 * 3600
    public static let legacySourceLifetime: TimeInterval = EpisodeResolver.lifetime

    private static var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("feed-landing.json")
    }

    /// Removes all cached landing clips (called on account login, logout, or account switch).
    public static func clear() {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// The entry saved for `tab` matching `accountId`; nil when absent or from another account.
    public static func load(tab: String, accountId: String? = nil, now: Date = Date()) -> LandingCache? {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = LandingSlots.decode(data, as: LandingCache.self, legacyTab: \.tab)[tab],
              saved.cacheVersion == currentVersion,
              saved.accountId == accountId,
              saved.tab == tab, !saved.rows.isEmpty, now.timeIntervalSince(saved.savedAt) < rowsLifetime else { return nil }
        return saved
    }

    /// Replaces this channel's entry and keeps the other channels' (an old single-entry file
    /// is carried over under its own channel).
    public func save() {
        guard let file = Self.file else { return }
        let existing = try? Data(contentsOf: file)
        guard let data = LandingSlots.storing(self, tab: tab, in: existing, legacyTab: \.tab) else { return }
        try? data.write(to: file, options: [.atomic])
    }

    /// The saved source and its true expiration timestamp while it is still unexpired.
    /// Expired URLs return nil so the resolver re-fetches a fresh signed URL (while still
    /// reusing any version-matched unified disk media prefix).
    public func freshSource(now: Date = Date()) -> (info: PlayInfo, expiresAt: Date)? {
        guard let source, let info = PlayInfoArchive.decode(source) else { return nil }
        let expiresAt: Date
        if let explicit = sourceExpiresAt {
            expiresAt = explicit
        } else if let sourceSavedAt {
            expiresAt = sourceSavedAt.addingTimeInterval(Self.legacySourceLifetime)
        } else {
            return nil
        }
        guard now < expiresAt else { return nil }
        return (info, expiresAt)
    }
}
#endif

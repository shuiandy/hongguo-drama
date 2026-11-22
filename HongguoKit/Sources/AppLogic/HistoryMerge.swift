import Foundation

/// One row of the 历史 wall, from this device or from the signed-in account.
public struct HistoryEntry: Equatable, Identifiable, Sendable {
    public var id: String { seriesId }
    public var seriesId: String
    public var title: String
    public var cover: String
    /// 1-based episode last played, 0 when unknown.
    public var episodeIndex: Int
    public var total: Int
    /// Highest episode played to the end.
    public var completedEpisode: Int
    public var position: Double
    public var updatedAt: Date
    public var fromAccount: Bool
    /// Content category label such as "真人剧", "漫剧", "AI剧", "高光", or "" when unknown.
    public var category: String

    public init(seriesId: String, title: String, cover: String, episodeIndex: Int, total: Int, completedEpisode: Int,
                position: Double, updatedAt: Date, fromAccount: Bool, category: String = "") {
        self.seriesId = seriesId; self.title = title; self.cover = cover; self.episodeIndex = episodeIndex
        self.total = total; self.completedEpisode = completedEpisode; self.position = position
        self.updatedAt = updatedAt; self.fromAccount = fromAccount; self.category = category
    }
}

public enum HistoryMerge {
    /// The account's history and this device's in one list, newest first. For a series in both,
    /// the row updated later wins (the account's on a tie, since the device's store also holds a
    /// copy of each account row); it keeps the other row's title, cover or total where its own
    /// is missing.
    public static func merge(local: [HistoryEntry], account: [HistoryEntry]) -> [HistoryEntry] {
        var rows: [String: HistoryEntry] = [:]
        for entry in local + account {
            guard let other = rows[entry.seriesId] else { rows[entry.seriesId] = entry; continue }
            let entryWins = entry.updatedAt > other.updatedAt || (entry.updatedAt == other.updatedAt && entry.fromAccount && !other.fromAccount)
            var winner = entryWins ? entry : other
            let loser = entryWins ? other : entry
            if winner.title.isEmpty { winner.title = loser.title }
            if winner.cover.isEmpty { winner.cover = loser.cover }
            if winner.total <= 0 { winner.total = loser.total }
            if winner.category.isEmpty { winner.category = loser.category }
            winner.completedEpisode = max(winner.completedEpisode, loser.completedEpisode)
            rows[entry.seriesId] = winner
        }
        return rows.values.sorted { ($0.updatedAt, $0.seriesId) > ($1.updatedAt, $1.seriesId) }
    }

    /// What an account row says about finished episodes: everything before the one being
    /// watched, and that one too when it reached the final episode (matching the official app's
    /// 已看完 tab where all `N/N` rows are counted as finished) or reached 95% of a single
    /// episode's duration.
    public static func completedEpisode(episodeIndex: Int, total: Int = 0, position: Double, duration: Double) -> Int {
        guard episodeIndex > 0 else { return 0 }
        if total > 0, episodeIndex >= total { return episodeIndex }
        return duration > 0 && position >= duration * 0.95 ? episodeIndex : episodeIndex - 1
    }
}

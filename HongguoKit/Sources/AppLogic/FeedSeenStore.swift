import Foundation

/// Pure rules for tracking recently exposed feed series IDs (mirroring the official app's
/// `SSBizStoreSessionRecordManager` + `video_feed_client_session_dedupe` in-place filter with
/// empty-result rollback).
public enum FeedSeenStore {
    public static let defaultLimit = 120
    public static let defaultQueryLimit = 30

    public static func decode(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in raw.split(separator: ",") {
            let id = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    public static func encode(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    /// Records `seriesId` as most recently seen (front of list), deduplicating and capping at `limit`.
    public static func record(_ seriesId: String, in existing: [String], limit: Int = defaultLimit) -> [String] {
        let trimmed = seriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        var next = existing.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        if next.count > limit {
            next = Array(next.prefix(limit))
        }
        return next
    }

    /// Formats the most recent `limit` IDs as a comma-separated query value for `recent_impr_gid`
    /// or `force_filter_ids`.
    public static func queryParam(_ ids: [String], limit: Int = defaultQueryLimit) -> String {
        Array(ids.prefix(max(0, limit))).joined(separator: ",")
    }

    /// Filters candidate IDs by removing disliked and recently seen items.
    /// Mirrors the official `shouldRollbackForEmptyFilterResult:` safeguard: if removing `seen`
    /// empties the list while non-disliked candidates exist, falls back to the non-disliked items
    /// (preserving order) so the feed never turns blank.
    public static func filter<T>(
        _ candidates: [T],
        id: (T) -> String,
        seen: Set<String>,
        disliked: Set<String>,
        allowRollback: Bool = true
    ) -> [T] {
        let allowed = candidates.filter { !disliked.contains(id($0)) }
        let fresh = allowed.filter { !seen.contains(id($0)) }
        if !fresh.isEmpty || !allowRollback { return fresh }
        return allowed
    }
}

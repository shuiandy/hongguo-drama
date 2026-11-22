import Foundation

/// Pure persistence/deduplication rules for series the viewer marked as "不感兴趣".
public enum DislikeStore {
    public static let defaultLimit = 500

    public static func add(_ seriesId: String, to list: [String], limit: Int = defaultLimit) -> [String] {
        let cleaned = seriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return list }
        var out = list.filter { $0 != cleaned }
        out.insert(cleaned, at: 0)
        if out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    public static func remove(_ seriesId: String, from list: [String]) -> [String] {
        let cleaned = seriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        return list.filter { $0 != cleaned }
    }

    public static func encode(_ list: [String]) -> String {
        list.joined(separator: ",")
    }

    public static func decode(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        var seen = Set<String>()
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

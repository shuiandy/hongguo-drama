import Foundation

/// Pure rules for managing local search history: normalisation, deduplication,
/// size bounds, matching while typing, and storage encoding.
public enum SearchHistoryRule {
    public static let defaultLimit = 20

    private static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes newline-separated storage text into non-empty unique keywords.
    public static func decode(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in raw.components(separatedBy: .newlines) {
            let trimmed = normalize(part)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Encodes keywords back into newline-separated storage text.
    public static func encode(_ items: [String]) -> String {
        items.compactMap {
            let cleaned = normalize($0)
            return cleaned.isEmpty ? nil : cleaned
        }.joined(separator: "\n")
    }

    /// Inserts `keyword` at the front, removes any older duplicate, and trims to `limit`.
    public static func record(_ keyword: String, in existing: [String], limit: Int = defaultLimit) -> [String] {
        let trimmed = normalize(keyword)
        guard !trimmed.isEmpty, limit > 0 else { return existing }
        var next = existing.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        if next.count > limit { next = Array(next.prefix(limit)) }
        return next
    }

    /// Removes a single keyword from history.
    public static func remove(_ keyword: String, from existing: [String]) -> [String] {
        let target = normalize(keyword)
        return existing.filter { $0 != keyword && $0 != target }
    }

    /// History entries matching what the user is currently typing (prefix matches first, then contains).
    public static func matching(_ query: String, in existing: [String], limit: Int = 6) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let lower = needle.lowercased()
        let prefix = existing.filter { $0.lowercased().hasPrefix(lower) }
        let contains = existing.filter { !$0.lowercased().hasPrefix(lower) && $0.lowercased().contains(lower) }
        return Array((prefix + contains).prefix(limit))
    }
}

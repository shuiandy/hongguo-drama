import Foundation

/// Reference to another series (a sequel or a similarly titled series).
public struct SeriesRef: Codable, Hashable, Sendable {
    public var seriesId: String
    public var title: String
    public init(seriesId: String, title: String) { self.seriesId = seriesId; self.title = title }
}

/// Where to continue a series. Port of the player's resume rule: a saved position is used only
/// when it is not within the last 3 seconds; a finished episode continues with the next one.
public struct ResumePoint: Equatable, Sendable {
    public var episodeIndex: Int
    public var position: Double

    public static let endSlack: Double = 3

    public static func from(_ record: WatchRecord?, episodeCount: Int) -> ResumePoint {
        guard let record, record.episodeIndex >= 1 else { return ResumePoint(episodeIndex: 1, position: 0) }
        let total = max(episodeCount, record.total)
        let nearEnd = record.duration > 0 && record.position >= record.duration - endSlack
        if nearEnd {
            if total == 0 || record.episodeIndex < total { return ResumePoint(episodeIndex: record.episodeIndex + 1, position: 0) }
            return ResumePoint(episodeIndex: record.episodeIndex, position: 0)
        }
        return ResumePoint(episodeIndex: total > 0 ? min(record.episodeIndex, total) : record.episodeIndex,
                           position: record.position > 0 ? record.position : 0)
    }

    /// Whether a start position should be applied for a media item of `duration` seconds.
    public static func shouldSeek(to position: Double, duration: Double?) -> Bool {
        guard position > 0, position.isFinite else { return false }
        guard let duration, duration.isFinite, duration > 0 else { return true }
        return position < duration - endSlack
    }
}

/// Whether an opened episode has really been watched, so saving its position may claim
/// "watched last" over other devices. Opening and closing without watching must not.
public struct WatchProgress: Equatable, Sendable {
    /// Playback needed before an opened episode counts as watched.
    public static let minimumSeconds: Double = 3
    /// Seconds played forward since the episode was opened.
    public private(set) var watched: Double = 0
    /// The user moved the playhead (seek, skip).
    public private(set) var moved = false
    private var last: Double?

    public init() {}

    /// A playhead sample. Counts smooth forward playback only: seeks, the resume seek included,
    /// jump further than 2 s, and samples while paused or buffering do not count.
    public mutating func sample(_ position: Double, playing: Bool) {
        guard position.isFinite else { return }
        if playing, let last, position > last, position - last < 2 { watched += position - last }
        last = position
    }

    public mutating func userMoved() { moved = true }

    public var shouldSave: Bool { moved || watched >= Self.minimumSeconds }
}

/// Season and sequel detection for the watch history. Port of src/native/watch-history.js.
public enum WatchHistory {
    public struct ParsedTitle: Equatable, Sendable {
        public var base: String
        public var season: Int
        public var explicit: Bool
        public var invalid: Bool = false
    }

    static let seasonPattern = try! NSRegularExpression(
        pattern: "^(.*?)(?:(?:第)?([一二三四五六七八九十百零两0-9]+)[季部]|[（(](?:第)?([一二三四五六七八九十百零两0-9]+)(?:[季部])?[）)]|season([0-9]+))$",
        options: [.caseInsensitive])

    static func normalizeTitle(_ title: String) -> String {
        let folded = title.precomposedStringWithCompatibilityMapping
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !$0.properties.isWhitespace })).lowercased()
    }

    /// Parses "剧名第二季", "剧名（2）", "剧名 Season 3" into a base title and season number.
    public static func seasonTitle(_ title: String) -> ParsedTitle {
        let text = normalizeTitle(title)
        let ns = text as NSString
        guard let match = seasonPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return ParsedTitle(base: text, season: 1, explicit: false)
        }
        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let base = group(1) ?? ""
        let fromBracket = group(3) != nil
        guard let value = group(2) ?? group(3) ?? group(4) else { return ParsedTitle(base: text, season: 1, explicit: false) }
        guard let season = parseNumeral(value) else { return ParsedTitle(base: text, season: 1, explicit: false, invalid: true) }
        // Bare bracket numbers can be years or other metadata; accept only modest seasons there.
        if fromBracket, season > 99 { return ParsedTitle(base: text, season: 1, explicit: false) }
        if season < 1 { return ParsedTitle(base: text, season: 1, explicit: false, invalid: true) }
        return ParsedTitle(base: base, season: season, explicit: true)
    }

    static func parseNumeral(_ value: String) -> Int? {
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) { return value.count <= 15 ? Int(value) : nil }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if value.contains("十") || value.contains("百") {
            var n = 0, digit = 0
            for char in value {
                if char == "十" || char == "百" {
                    n += (digit == 0 ? 1 : digit) * (char == "十" ? 10 : 100)
                    digit = 0
                } else {
                    digit = digits[char] ?? 0
                }
            }
            return n + digit
        }
        var text = ""
        for char in value {
            guard let d = digits[char] else { return nil }
            text += String(d)
        }
        return text.count <= 15 ? Int(text) : nil
    }

    public enum Source: String, Sendable { case hongguo, xifan, hema }

    public static func source(of id: String) -> Source? {
        if id.matchesDigits(min: 6, max: 30) { return .hongguo }
        if id.range(of: "^xifan:[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$", options: .regularExpression) != nil { return .xifan }
        if id.range(of: "^hema:[0-9]+$", options: .regularExpression) != nil { return .hema }
        return nil
    }

    /// Source plus base title; empty when the series cannot be grouped.
    public static func familyKey(seriesId: String, title: String) -> String {
        let parsed = seasonTitle(title)
        guard let source = source(of: seriesId), !parsed.base.isEmpty, !parsed.invalid else { return "" }
        return "\(source.rawValue)\u{0}\(parsed.base)"
    }

    public static func season(of title: String) -> Int {
        let parsed = seasonTitle(title)
        return parsed.invalid ? 0 : parsed.season
    }

    /// The search keyword for finding sequels.
    public static func sequelKeyword(_ title: String) -> String { seasonTitle(title).base }

    /// Later seasons among `candidates`: same source, same base title, explicit season number
    /// higher than both the current one and `afterSeason`. At most 10, by season.
    public static func findSequels(of series: SeriesRef, in candidates: [SeriesRef], afterSeason: Int = 0) -> [SeriesRef] {
        let current = seasonTitle(series.title)
        guard let source = source(of: series.seriesId), !current.base.isEmpty, !current.invalid else { return [] }
        var seen: Set<String> = [series.seriesId]
        var out: [(SeriesRef, Int)] = []
        for candidate in candidates {
            let next = seasonTitle(candidate.title)
            guard !seen.contains(candidate.seriesId), Self.source(of: candidate.seriesId) == source, next.explicit, !next.invalid,
                  next.base == current.base, next.season > max(current.season, afterSeason) else { continue }
            seen.insert(candidate.seriesId)
            out.append((candidate, next.season))
        }
        return out.sorted { $0.1 < $1.1 }.prefix(10).map(\.0)
    }

    /// Edit distance of at most 2 and at most 20% of the longer title, both at least 4 long.
    static func similarTitles(_ left: String, _ right: String) -> Bool {
        let a = Array(left), b = Array(right)
        let length = max(a.count, b.count)
        let limit = min(2, length / 5)
        guard min(a.count, b.count) >= 4, length <= 200, abs(a.count - b.count) <= limit else { return false }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if current.min()! > limit { return false }
            previous = current
        }
        return previous[b.count] <= limit
    }

    static func normalizeForSimilarity(_ title: String) -> String {
        let stripped = String(String.UnicodeScalarView(title.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return false
            default: return true
            }
        }))
        return stripped.replacingOccurrences(of: "[零〇一二三四五六七八九十百两0-9]+", with: "#", options: .regularExpression)
    }

    /// Up to 5 other series from the same source whose base titles differ by a small edit
    /// (renamed sequels without a season marker), excluding the same family.
    public static func findSimilar(to series: SeriesRef, in candidates: [SeriesRef]) -> [SeriesRef] {
        let current = seasonTitle(series.title)
        let family = familyKey(seriesId: series.seriesId, title: series.title)
        guard !family.isEmpty else { return [] }
        let title = normalizeForSimilarity(current.base)
        let source = source(of: series.seriesId)
        var seen: Set<String> = [series.seriesId]
        var latest: [String: SeriesRef] = [:]
        var order: [String] = []
        for candidate in candidates {
            if latest[candidate.seriesId] == nil { order.append(candidate.seriesId) }
            latest[candidate.seriesId] = candidate
        }
        var results: [SeriesRef] = []
        for id in order {
            let candidate = latest[id]!
            let next = seasonTitle(candidate.title)
            guard !seen.contains(id), Self.source(of: id) == source, !next.invalid,
                  familyKey(seriesId: id, title: candidate.title) != family,
                  similarTitles(title, normalizeForSimilarity(next.base)) else { continue }
            seen.insert(id)
            results.append(candidate)
            if results.count == 5 { break }
        }
        return results
    }
}

// MARK: - Update tracking on watch records

extension WatchRecord {
    /// Episodes published since the user last acknowledged this series.
    public var unreadEpisodes: Int { max(0, (knownTotal ?? total) - (acknowledgedTotal ?? knownTotal ?? total)) }
    public var unreadSequelIds: [String] {
        let seen = Set(seenSequelIds ?? [])
        return (sequels ?? []).map(\.seriesId).filter { !seen.contains($0) }
    }
    public var hasUpdates: Bool { unreadEpisodes > 0 || !unreadSequelIds.isEmpty }

    /// Applies a fresh episode count. Never rolls back to a smaller list from a slower refresh.
    public func applyingEpisodeUpdate(freshTotal: Int, now: Date = Date()) -> WatchRecord {
        var copy = self
        let baseline = max(knownTotal ?? 0, total)
        copy.knownTotal = max(baseline, freshTotal)
        copy.acknowledgedTotal = acknowledgedTotal ?? baseline
        copy.total = max(total, freshTotal)
        copy.lastCheckedAt = now
        copy.lastCheckError = nil
        return copy
    }

    public func applyingSequels(_ found: [SeriesRef], now: Date = Date()) -> WatchRecord {
        var copy = self
        var merged = sequels ?? []
        for item in found where !merged.contains(where: { $0.seriesId == item.seriesId }) { merged.append(item) }
        copy.sequels = Array(merged.prefix(10))
        copy.lastCheckedAt = now
        return copy
    }

    /// Marks what the user has now seen: episodes up to `visibleTotal` (default all known) and
    /// the listed sequels (default all known).
    public func acknowledging(visibleTotal: Int? = nil, sequelIds: [String]? = nil) -> WatchRecord {
        var copy = self
        let known = knownTotal ?? total
        let visible = visibleTotal ?? known
        copy.acknowledgedTotal = max(acknowledgedTotal ?? 0, min(known, visible))
        let knownIds = Set((sequels ?? []).map(\.seriesId))
        let visibleIds = sequelIds ?? Array(knownIds)
        var seen = seenSequelIds ?? []
        for id in visibleIds where knownIds.contains(id) && !seen.contains(id) { seen.append(id) }
        copy.seenSequelIds = seen
        return copy
    }
}

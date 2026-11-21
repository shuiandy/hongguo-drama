import Foundation

/// Episode pickers show ranges of 30 ("1-30", "31-60", ...).
public enum EpisodeRanges {
    public static let size = 30

    public static func ranges(total: Int, size: Int = EpisodeRanges.size) -> [ClosedRange<Int>] {
        guard total > 0, size > 0 else { return [] }
        return stride(from: 1, through: total, by: size).map { $0...min(total, $0 + size - 1) }
    }

    public static func label(_ range: ClosedRange<Int>) -> String { "\(range.lowerBound)-\(range.upperBound)" }

    /// Index of the range holding `episode`, or 0.
    public static func index(of episode: Int, total: Int, size: Int = EpisodeRanges.size) -> Int {
        guard size > 0, total > 0 else { return 0 }
        return (min(max(1, episode), total) - 1) / size
    }
}

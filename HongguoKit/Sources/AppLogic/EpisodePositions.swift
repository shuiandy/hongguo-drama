import Foundation

/// Where each episode of each series was left, so any half-watched episode carries on from
/// there on a later visit. Kept by the app itself, next to the core's history (which holds
/// one row per series). The least recently touched series go first when the book is full.
public struct EpisodePositionBook: Codable, Equatable, Sendable {
    public struct Series: Codable, Equatable, Sendable {
        public var updatedAt: Date
        /// Seconds into each episode, by 1-based episode number.
        public var positions: [Int: Double]
    }

    public static let seriesLimit = 200

    public private(set) var series: [String: Series] = [:]

    public init() {}

    public func position(seriesId: String, episode: Int) -> Double? {
        series[seriesId]?.positions[episode]
    }

    public func positions(seriesId: String) -> [Int: Double] {
        series[seriesId]?.positions ?? [:]
    }

    /// Records where an episode was left; nil forgets it (played to the end: start over).
    public mutating func set(seriesId: String, episode: Int, position: Double?, now: Date = Date(), limit: Int = seriesLimit) {
        var entry = series[seriesId] ?? Series(updatedAt: now, positions: [:])
        entry.updatedAt = now
        if let position, position > 1 { entry.positions[episode] = position } else { entry.positions[episode] = nil }
        series[seriesId] = entry.positions.isEmpty ? nil : entry
        guard series.count > limit else { return }
        for id in series.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(series.count - limit).map(\.key) {
            series[id] = nil
        }
    }
}

import Foundation

/// 定时关闭: stop after a number of minutes, or when the current episode ends.
public struct SleepTimer: Equatable, Sendable {
    public enum Setting: Hashable, Sendable, CaseIterable {
        case off, endOfEpisode, minutes15, minutes30, minutes60

        public var minutes: Int? {
            switch self {
            case .minutes15: return 15
            case .minutes30: return 30
            case .minutes60: return 60
            case .off, .endOfEpisode: return nil
            }
        }

        public var label: String {
            switch self {
            case .off: return "不开启"
            case .endOfEpisode: return "播完本集"
            case .minutes15: return "15 分钟"
            case .minutes30: return "30 分钟"
            case .minutes60: return "60 分钟"
            }
        }
    }

    public private(set) var setting: Setting = .off
    public private(set) var deadline: Date?

    public init() {}

    public mutating func set(_ value: Setting, now: Date = Date()) {
        setting = value
        deadline = value.minutes.map { now.addingTimeInterval(Double($0) * 60) }
    }

    /// True once a minute timer has run out. The caller pauses and calls `set(.off)`.
    public func isDue(now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    /// True when playback should stop instead of moving to the next episode.
    public func stopsAtEpisodeEnd(now: Date = Date()) -> Bool {
        setting == .endOfEpisode || isDue(now: now)
    }

    public func remaining(now: Date = Date()) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// "剩余 14:59", "播完本集后关闭", or nil when off.
    public func statusLabel(now: Date = Date()) -> String? {
        switch setting {
        case .off: return nil
        case .endOfEpisode: return "播完本集后关闭"
        default: return remaining(now: now).map { "剩余 " + PlayerGestures.clock($0) }
        }
    }
}

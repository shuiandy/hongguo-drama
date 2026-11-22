import Foundation

/// When the background account sync (lists and history) may start. A forced run (cold start
/// after the saved login is restored) always starts unless one is already running; otherwise a
/// run starts at most once per `interval`, counted from the last run that started.
public struct AccountSyncThrottle: Sendable {
    public let interval: TimeInterval
    public private(set) var isRunning = false
    public private(set) var lastStart: Date?

    public init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    /// Whether a run may start now; when it may, the run is marked as started.
    public mutating func begin(now: Date, force: Bool) -> Bool {
        guard !isRunning else { return false }
        if !force, let lastStart, now.timeIntervalSince(lastStart) < interval { return false }
        isRunning = true
        lastStart = now
        return true
    }

    public mutating func end() {
        isRunning = false
    }
}

/// A write to the account failed: the device's own copy (favourite, liked episode, reservation)
/// goes back only while it still says what the failed request asked for. A later tap that
/// already changed it again wins, and is left as it is.
public enum LocalRollback {
    public static func shouldRevert(local: Bool, failedTarget: Bool) -> Bool {
        local == failedTarget
    }
}

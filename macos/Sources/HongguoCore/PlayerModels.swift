import Foundation

/// Picture mode, remembered per series. `fit` shows the whole frame and scales with the window;
/// `width` fills the width and may crop top and bottom (Electron's 适应窗口 / 保持宽度).
/// AVKit mapping: fit = `.resizeAspect`, width = `.resizeAspectFill`.
public enum PictureMode: String, Codable, CaseIterable, Sendable {
    case fit, width

    public var label: String { self == .fit ? "适应窗口" : "保持宽度" }
    public var hint: String { self == .fit ? "完整显示，随窗口缩放。按剧单独记忆。" : "按宽度显示，上下可能裁剪。按剧单独记忆。" }
    public var toggled: PictureMode { self == .fit ? .width : .fit }
}

/// Playback speed rules shared by the menu, the rate button and the S / D shortcuts.
public enum PlaybackRate {
    public static let minimum: Float = 0.25
    public static let maximum: Float = 4
    /// Menu choices: 0.25× to 4× in 0.25 steps (16 entries), as in the Electron player.
    public static let menuRates: [Float] = (1...16).map { Float($0) / 4 }
    /// Allowed shortcut step sizes.
    public static let speedSteps: [Float] = [0.25, 0.5, 0.75, 1]
    /// Held Space plays at this rate.
    public static let holdRate: Float = 2

    public static func clamp(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return min(maximum, max(minimum, (rate * 100).rounded() / 100))
    }

    /// The rate button: +0.25 each click, back to 1× after 4×.
    public static func cycled(_ rate: Float) -> Float {
        rate >= maximum ? 1 : clamp(rate + 0.25)
    }

    /// Shortcut stepping by `step` (S slower, D faster).
    public static func stepped(_ rate: Float, by step: Float, faster: Bool) -> Float {
        clamp(rate + (faster ? step : -step))
    }

    /// "1×", "1.25×", "0.5×".
    public static func label(_ rate: Float) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }
}

/// Volume and mute. Muting keeps the level so unmuting restores it; dragging to 0 mutes.
public struct VolumeState: Equatable, Codable, Sendable {
    public var level: Float
    public var muted: Bool

    public static let step: Float = 0.05

    public init(level: Float = 1, muted: Bool = false) {
        self.level = Self.clamp(level)
        self.muted = muted
    }

    public static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }

    /// What the player should actually output.
    public var effective: Float { muted ? 0 : level }
    public var percent: Int { Int((effective * 100).rounded()) }

    public var symbolName: String {
        if muted || level == 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// Slider input.
    public mutating func set(_ value: Float) {
        level = Self.clamp(value)
        muted = level == 0
    }

    /// Arrow keys / scroll: ±5%. Raising from mute unmutes.
    public mutating func adjust(by delta: Float) {
        let base = muted ? 0 : level
        set(((base + delta) / Self.step).rounded() * Self.step)
    }

    public mutating func toggleMute() {
        if muted {
            muted = false
            if level == 0 { level = 0.5 }
        } else {
            muted = true
        }
    }
}

/// Time line maths for the scrubber, labels and seeking.
public struct PlaybackTimeline: Equatable, Sendable {
    public var position: Double
    public var duration: Double
    /// Loaded ranges in seconds, for the buffer bar.
    public var buffered: [ClosedRange<Double>]

    public init(position: Double = 0, duration: Double = 0, buffered: [ClosedRange<Double>] = []) {
        self.position = position.isFinite ? max(0, position) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.buffered = buffered
    }

    public var hasDuration: Bool { duration > 0 }

    /// 0...1 for the scrubber.
    public var fraction: Double { hasDuration ? min(1, max(0, position / duration)) : 0 }

    /// How far the loaded data reaches past the playhead, as 0...1.
    public var bufferedFraction: Double {
        guard hasDuration else { return 0 }
        let reach = buffered.filter { $0.contains(position) || $0.lowerBound >= position }.map(\.upperBound).max() ?? position
        return min(1, max(0, reach / duration))
    }

    public var remaining: Double { hasDuration ? max(0, duration - position) : 0 }

    /// Time for a scrubber fraction.
    public func time(atFraction value: Double) -> Double {
        guard hasDuration, value.isFinite else { return 0 }
        return min(duration, max(0, value * duration))
    }

    /// Target of a relative seek (arrow keys), kept inside the media. Seeking to the very end
    /// stops 0.1 s short so the end-of-item notification still fires once.
    public func seekTarget(by delta: Double) -> Double {
        var target = position + delta
        if hasDuration { target = min(duration - 0.1, target) }
        return max(0, target)
    }

    /// Whether the position counts as watched to the end (for "completed" and auto-delete).
    public var isAtEnd: Bool { hasDuration && position >= duration - min(1, duration * 0.01) }

    /// "m:ss" or "h:mm:ss".
    public static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public var positionLabel: String { Self.format(position) }
    public var durationLabel: String { Self.format(duration) }
    public var remainingLabel: String { "-" + Self.format(remaining) }
}

/// Episode navigation for the player and the episode drawer.
public struct EpisodeCursor: Equatable, Sendable {
    public var index: Int
    public var count: Int

    public init(index: Int, count: Int) {
        self.count = max(0, count)
        self.index = count > 0 ? min(max(1, index), count) : max(1, index)
    }

    public var hasNext: Bool { index < count }
    public var hasPrevious: Bool { index > 1 }
    public var next: Int? { hasNext ? index + 1 : nil }
    public var previous: Int? { hasPrevious ? index - 1 : nil }

    /// Episodes grouped in ranges of `size` for the drawer tabs ("1-30", "31-60", ...).
    public func ranges(size: Int = 30) -> [ClosedRange<Int>] {
        guard count > 0, size > 0 else { return [] }
        return stride(from: 1, through: count, by: size).map { $0...min(count, $0 + size - 1) }
    }
}

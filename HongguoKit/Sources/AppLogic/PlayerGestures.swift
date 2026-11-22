import CoreGraphics
import Foundation

/// The arithmetic behind the full-screen player gestures: a horizontal drag seeks, a vertical
/// drag changes brightness on the left half and volume on the right half.
public enum PlayerGestures {
    public enum Intent: Equatable, Sendable {
        case seek, brightness, volume
    }

    /// A drag is not classified until it has moved this far, so taps and jitter do nothing.
    public static let activationDistance: CGFloat = 12
    /// A drag across the whole width seeks this many seconds (less for shorter videos).
    public static let fullWidthSeekSeconds: Double = 90

    /// Decided once per drag from its first clear movement.
    public static func intent(translation: CGSize, startX: CGFloat, width: CGFloat) -> Intent? {
        let dx = abs(translation.width), dy = abs(translation.height)
        guard max(dx, dy) >= activationDistance, width > 0 else { return nil }
        if dx >= dy { return .seek }
        return startX < width / 2 ? .brightness : .volume
    }

    /// Where a seek drag lands, clamped to the video.
    public static func seekTarget(from start: Double, translationX: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0, start.isFinite else { return max(0, start.isFinite ? start : 0) }
        let span = min(duration, fullWidthSeekSeconds)
        let target = start + Double(translationX / width) * span
        return min(duration, max(0, target))
    }

    /// New brightness or volume (0...1). Dragging up by the full height adds 1.
    public static func level(from start: Double, translationY: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return min(1, max(0, start)) }
        return min(1, max(0, start - Double(translationY / height)))
    }

    /// "+0:12" or "-1:05" for the seek HUD.
    public static func seekDeltaLabel(from start: Double, to target: Double) -> String {
        let delta = Int((target - start).rounded())
        return (delta < 0 ? "-" : "+") + clock(Double(abs(delta)))
    }

    /// m:ss, or h:mm:ss from one hour up.
    public static func clock(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

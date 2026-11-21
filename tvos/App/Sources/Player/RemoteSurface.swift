import SwiftUI
import UIKit

/// The whole-screen surface that takes the Siri Remote while the player shows no panel: a click,
/// a click on the left or right edge (±10 s), horizontal swipes (scrubbing) and a swipe down.
/// The play key is left to the page (`onPlayPauseCommand`), so one press is handled once. SwiftUI has no swipe input on tvOS, so this is a focusable UIKit view with gesture
/// recognizers for the touch surface.
struct RemoteSurface: UIViewRepresentable {
    /// Takes focus and input only while true (a panel takes over otherwise).
    var isActive: Bool
    var onSelect: () -> Void
    var onStep: (_ direction: Int) -> Void
    /// Horizontal swipe: the fraction of the surface's width moved so far, then nil when it ends.
    var onScrub: (_ fraction: Double?) -> Void
    var onSwipeDown: () -> Void
    var onMenu: () -> Void

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.handlers = self
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.handlers = self
        if view.isActive != isActive {
            view.isActive = isActive
            view.setNeedsFocusUpdate()
        }
    }

    final class SurfaceView: UIView {
        var handlers: RemoteSurface?
        var isActive = true
        private var panStart: CGPoint = .zero
        private var scrubbing = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            let select = UITapGestureRecognizer(target: self, action: #selector(selected))
            select.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
            addGestureRecognizer(select)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            addGestureRecognizer(pan)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var canBecomeFocused: Bool { isActive }

        @objc private func selected() { handlers?.onSelect() }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            let moved = pan.translation(in: self)
            switch pan.state {
            case .began:
                scrubbing = false
            case .changed:
                // A mostly horizontal swipe scrubs; a clear downward one opens the episodes.
                if !scrubbing, abs(moved.x) > 40, abs(moved.x) > abs(moved.y) { scrubbing = true }
                if scrubbing { handlers?.onScrub(Double(moved.x / max(1, bounds.width))) }
            case .ended:
                if scrubbing {
                    handlers?.onScrub(nil)
                } else if moved.y > 120, moved.y > abs(moved.x) * 1.5 {
                    handlers?.onSwipeDown()
                }
                scrubbing = false
            case .cancelled, .failed:
                if scrubbing { handlers?.onScrub(nil) }
                scrubbing = false
            default:
                break
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                switch press.type {
                case .leftArrow: handlers?.onStep(-1); handled = true
                case .rightArrow: handlers?.onStep(1); handled = true
                // The down arrow counts as a swipe down: the controls sit inside this surface, so
                // the focus engine cannot move down to them by itself.
                case .downArrow: handlers?.onSwipeDown(); handled = true
                case .menu: handlers?.onMenu(); handled = true
                default: break
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }
    }
}

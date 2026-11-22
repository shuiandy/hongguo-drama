import SwiftUI
import UIKit

/// The whole-screen surface that takes the Siri Remote while the player shows nothing but the
/// picture. It answers presses only: the centre click, a click on the ring's left or right
/// (±10 s), a click on its top or bottom (the controls) and Back. Swipes left and right do
/// nothing here, so a finger resting or sliding on the clickpad never moves the playback
/// position; a swipe up or down brings the controls in, like the click does.
///
/// As soon as the controls or a panel show, the surface stops being focusable and the focus
/// engine alone moves between what is on screen: nothing here listens while a button has the focus.
/// The play key is left to the page (`onPlayPauseCommand`), so one press is handled once.
struct RemoteSurface: UIViewRepresentable {
    /// Takes focus and input only while true (the controls or a panel take over otherwise).
    var isActive: Bool
    /// Changing it asks the focus system to move the focus here (what had it went away).
    var focusRequest: Int = 0
    var onSelect: () -> Void
    var onStep: (_ direction: Int) -> Void
    /// Up or down, clicked or swiped: bring the controls in.
    var onReveal: () -> Void
    var onMenu: () -> Void

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.handlers = self
        view.isActive = isActive
        view.focusRequest = focusRequest
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.handlers = self
        if view.isActive != isActive {
            view.isActive = isActive
            view.setNeedsFocusUpdate()
        }
        if view.focusRequest != focusRequest {
            view.focusRequest = focusRequest
            view.takeFocus()
        }
    }

    final class SurfaceView: UIView {
        var handlers: RemoteSurface?
        var isActive = true
        var focusRequest = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            let select = UITapGestureRecognizer(target: self, action: #selector(selected))
            select.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
            addGestureRecognizer(select)
            for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(revealed))
                swipe.direction = direction
                addGestureRecognizer(swipe)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var canBecomeFocused: Bool { isActive }

        /// Asks for the focus now, and once more shortly after if by then nothing has it at all
        /// (the view that had it may still have been fading out at the first request).
        func takeFocus() {
            for (attempt, delay) in [0.0, 0.3].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.isActive, !self.isFocused,
                          let system = UIFocusSystem.focusSystem(for: self) else { return }
                    if attempt > 0, system.focusedItem != nil { return }
                    system.requestFocusUpdate(to: self)
                    system.updateFocusIfNeeded()
                }
            }
        }

        @objc private func selected() { handlers?.onSelect() }

        @objc private func revealed() { handlers?.onReveal() }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                switch press.type {
                case .leftArrow: handlers?.onStep(-1); handled = true
                case .rightArrow: handlers?.onStep(1); handled = true
                case .upArrow, .downArrow: handlers?.onReveal(); handled = true
                case .menu: handlers?.onMenu(); handled = true
                default: break
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }
    }
}

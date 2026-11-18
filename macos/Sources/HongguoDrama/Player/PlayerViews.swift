import AppKit
import SwiftUI

/// Transparent area that drags the window; double click runs `onDoubleClick`.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: () -> Void

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?(); return }
            window?.performDrag(with: event)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.onDoubleClick = onDoubleClick }
}


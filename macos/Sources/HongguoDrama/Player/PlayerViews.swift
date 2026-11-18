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


/// Wide resize zones for a borderless window: edges and corners pick up drags well inside the
/// window (AppKit only gives a borderless window a few pixels), keeping `contentAspectRatio`.
/// The interior returns nil from hit testing so clicks and drags there reach the views below.
struct WindowResizeEdges: NSViewRepresentable {
    var thickness: CGFloat = 12
    var corner: CGFloat = 26

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4)
        static let top = Edges(rawValue: 8)
    }

    final class EdgeView: NSView {
        var thickness: CGFloat = 12
        var corner: CGFloat = 26
        private var startFrame = NSRect.zero
        private var startMouse = NSPoint.zero
        private var dragging: Edges = []

        func edges(at p: NSPoint) -> Edges {
            let w = bounds.width, h = bounds.height
            var e: Edges = []
            if p.x < thickness { e.insert(.left) } else if p.x > w - thickness { e.insert(.right) }
            if p.y < thickness { e.insert(.bottom) } else if p.y > h - thickness { e.insert(.top) }
            guard !e.isEmpty else { return e }
            // Near a corner, an edge hit becomes a corner hit.
            if p.x < corner { e.insert(.left) } else if p.x > w - corner { e.insert(.right) }
            if p.y < corner { e.insert(.bottom) } else if p.y > h - corner { e.insert(.top) }
            return e
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview else { return nil }
            return edges(at: convert(point, from: superview)).isEmpty ? nil : self
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            let w = bounds.width, h = bounds.height, t = thickness, c = corner
            let horizontal = NSCursor.resizeLeftRight, vertical = NSCursor.resizeUpDown
            addCursorRect(NSRect(x: 0, y: c, width: t, height: max(0, h - 2 * c)), cursor: horizontal)
            addCursorRect(NSRect(x: w - t, y: c, width: t, height: max(0, h - 2 * c)), cursor: horizontal)
            addCursorRect(NSRect(x: c, y: 0, width: max(0, w - 2 * c), height: t), cursor: vertical)
            addCursorRect(NSRect(x: c, y: h - t, width: max(0, w - 2 * c), height: t), cursor: vertical)
            let corners: [(NSRect, Bool)] = [
                (NSRect(x: 0, y: 0, width: c, height: c), false),          // bottom left
                (NSRect(x: w - c, y: h - c, width: c, height: c), false),  // top right
                (NSRect(x: 0, y: h - c, width: c, height: c), true),       // top left
                (NSRect(x: w - c, y: 0, width: c, height: c), true),       // bottom right
            ]
            for (rect, isTopLeftDiagonal) in corners {
                for strip in [NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: t),
                              NSRect(x: rect.minX, y: rect.maxY - t, width: rect.width, height: t),
                              NSRect(x: rect.minX, y: rect.minY, width: t, height: rect.height),
                              NSRect(x: rect.maxX - t, y: rect.minY, width: t, height: rect.height)] {
                    addCursorRect(strip.intersection(rect), cursor: diagonalCursor(topLeft: isTopLeftDiagonal))
                }
            }
        }

        private func diagonalCursor(topLeft: Bool) -> NSCursor {
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: topLeft ? .topLeft : .topRight, directions: .all)
            }
            return .crosshair
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragging = edges(at: convert(event.locationInWindow, from: nil))
            startFrame = window.frame
            startMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, !dragging.isEmpty else { return }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
            var width = startFrame.width, height = startFrame.height
            if dragging.contains(.right) { width += dx }
            if dragging.contains(.left) { width -= dx }
            if dragging.contains(.top) { height += dy }
            if dragging.contains(.bottom) { height -= dy }

            let ratio = window.contentAspectRatio
            let horizontal = dragging.contains(.left) || dragging.contains(.right)
            if ratio.width > 0, ratio.height > 0 {
                let aspect = ratio.width / ratio.height
                let minWidth = max(window.minSize.width, window.minSize.height * aspect)
                let maxWidth = (window.screen?.visibleFrame.height ?? 2000) * aspect
                if !horizontal { width = height * aspect }
                width = min(max(width, minWidth), max(minWidth, maxWidth))
                height = width / aspect
            } else {
                width = max(width, window.minSize.width)
                height = max(height, window.minSize.height)
            }

            // Keep the edges opposite the drag where they were.
            let x = dragging.contains(.left) ? startFrame.maxX - width : startFrame.minX
            let y = dragging.contains(.bottom) ? startFrame.minY + startFrame.height - height
                : (dragging.contains(.top) ? startFrame.minY : startFrame.maxY - height)
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }

        override func mouseUp(with event: NSEvent) { dragging = [] }
    }

    func makeNSView(context: Context) -> EdgeView {
        let view = EdgeView()
        view.thickness = thickness
        view.corner = corner
        return view
    }

    func updateNSView(_ view: EdgeView, context: Context) {
        view.thickness = thickness
        view.corner = corner
    }
}

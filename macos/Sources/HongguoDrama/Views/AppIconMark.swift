import AppKit
import SwiftUI

/// The app icon as an in-app brand mark (sidebar header, About pane).
/// Reads the bundle's AppIcon.icns through NSApp, so it always matches the Dock icon.
/// The icon art leaves about 5% transparent margin on each side, so `size` is the canvas,
/// not the visible tile.
struct AppIconMark: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

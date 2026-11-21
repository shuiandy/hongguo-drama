import SwiftUI

/// The app's own red (the iOS AccentColor, FF5C6C). On tvOS `Color.accentColor` resolves to the
/// system's white unless a tint is set, and a global tint makes focused button labels unreadable,
/// so the red is named here and used where a mark needs it.
enum Theme {
    static let accent = Color(red: 1, green: 0x5C / 255, blue: 0x6C / 255)
}

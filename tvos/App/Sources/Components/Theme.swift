import SwiftUI

/// The app's own red (the iOS AccentColor, FF5C6C). On tvOS `Color.accentColor` resolves to the
/// system's white unless a tint is set, and a global tint makes focused button labels unreadable,
/// so the red is named here and used where a mark needs it.
enum Theme {
    static let accent = Color(red: 1, green: 0x5C / 255, blue: 0x6C / 255)

    // The iOS search page's warm colours (its `SearchPalette`): the first three of a board and
    // the coloured icons of the shortcuts and category chips.
    static let red = Color(red: 1.0, green: 0.36, blue: 0.42)
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.24)
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.27)

    /// A board's rank number: red, orange and gold for the first three, then quiet.
    static func rank(_ rank: Int) -> Color {
        switch rank {
        case 1: return red
        case 2: return orange
        case 3: return gold
        default: return .secondary
        }
    }

    /// The chosen item's warm fill, red running into orange.
    static var warmFill: LinearGradient {
        LinearGradient(colors: [red.opacity(0.55), orange.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
    }
}

/// A chip in a row of choices or shortcuts, the tvOS form of the iOS glass chips: a coloured icon
/// and a title; `active` gives the chosen one the warm fill. The system's focus effect does the
/// rest (it grows and lights the focused one).
struct ChipButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .primary
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(tint)
                }
                Text(title).fontWeight(active ? .semibold : .regular)
            }
            .font(.callout)
            .padding(.horizontal, 8)
        }
        .background { if active { Capsule().fill(Theme.warmFill).padding(-6) } }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A section's title with a coloured icon, as the iOS search page's headers.
struct SectionTitle: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).font(.title3.weight(.semibold))
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

import SwiftUI

/// A dark, blurred wash of one colour (the cover's main colour) behind a page or the player's
/// side bars. Changes cross-fade.
struct AmbientBackground: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [tint.opacity(0.85), tint.opacity(0.25), .clear],
                           center: .topLeading, startRadius: 40, endRadius: 1400)
            RadialGradient(colors: [tint.opacity(0.45), .clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 1000)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        }
        .blur(radius: 60)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: tint)
    }
}

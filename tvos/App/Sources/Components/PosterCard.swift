import HongguoCore
import SwiftUI

/// Poster size on a 1920×1080-point screen: seven to a row with the system's shelf spacing.
enum PosterMetrics {
    static let width: CGFloat = 220
    /// Hongguo covers are about 0.7 wide to tall.
    static let height: CGFloat = 314
    static let spacing: CGFloat = 40
}

/// A vertical poster. The system card style gives the lift, shadow and parallax when focused;
/// the title sits under the card, as on the system's own shelves.
struct PosterCard: View {
    let series: SeriesSummary
    /// A rank badge for 排行 shelves.
    var rank: Int? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                PosterImage(series: series)
                    .frame(width: PosterMetrics.width, height: PosterMetrics.height)
                    .overlay(alignment: .topLeading) {
                        if let rank { RankBadge(rank: rank) }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !series.heat.isEmpty {
                            Label(series.heat, systemImage: "flame.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(10)
                        }
                    }
            }
            .buttonStyle(.card)
            VStack(alignment: .leading, spacing: 4) {
                Text(series.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: PosterMetrics.width, alignment: .leading)
        }
    }

    private var subtitle: String {
        ([series.episodeLabel.isEmpty ? (series.episodeCount > 0 ? "全\(series.episodeCount)集" : "") : series.episodeLabel]
            + series.tags.prefix(2)).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The cover, or a tinted placeholder while it loads or when there is none (offline samples).
struct PosterImage: View {
    let series: SeriesSummary

    var body: some View {
        ZStack {
            Rectangle().fill(PlaceholderTint.color(for: series.seriesId).gradient)
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.35))
            if let url = URL(string: series.cover), !series.cover.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .clipped()
    }
}

struct RankBadge: View {
    let rank: Int

    var body: some View {
        Text("\(rank)")
            .font(.title3.weight(.heavy).monospacedDigit())
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(rank <= 3 ? Color.accentColor : Color.black.opacity(0.6),
                        in: UnevenRoundedRectangle(bottomTrailingRadius: 14))
    }
}

/// A steady colour per series for placeholders and the ambient background until the cover's own
/// colour is read.
enum PlaceholderTint {
    static func color(for id: String) -> Color {
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.45)
    }
}

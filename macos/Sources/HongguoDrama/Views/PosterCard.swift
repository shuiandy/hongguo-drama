import SwiftUI
import HongguoCore

struct CoverImage: View {
    let url: String
    var cornerRadius: CGFloat = 8

    var body: some View {
        // The image fills whatever size it is given; it never sizes its container
        // (a portrait cover with .fill used to make full-window backdrops taller than the window).
        Color.clear
            .overlay {
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder.overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    default:
                        placeholder
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.quaternary)
    }
}

struct PosterCard: View {
    let summary: SeriesSummary
    var hovering = false
    /// The heat sits on the cover's bottom left and the line under the title is only the label,
    /// as on the official app's work cards.
    var heatOnCover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(CoverImage(url: summary.cover, cornerRadius: 16))
                .overlay(alignment: .topLeading) {
                    if let rank = summary.rank { RankBadge(rank: rank).padding(8) }
                }
                .overlay(alignment: .bottomLeading) {
                    if heatOnCover, !summary.heat.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill").font(.system(size: 9, weight: .bold))
                            Text(summary.heat).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.top, 18)
                        .padding(.bottom, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Keeps the bottom of bright covers from fighting the hover button.
                    LinearGradient(colors: [.clear, .black.opacity(hovering ? 0.35 : 0)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.7 : 0.08), lineWidth: hovering ? 2 : 1)
                }
                .shadow(color: .black.opacity(hovering ? 0.4 : 0.22), radius: hovering ? 18 : 8, y: hovering ? 10 : 4)
                .scaleEffect(hovering ? 1.03 : 1)
                .offset(y: hovering ? -3 : 0)

            Text(summary.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.top, 9)
            HStack(spacing: 4) {
                if !summary.episodeLabel.isEmpty {
                    Text(summary.episodeLabel)
                } else if summary.episodeCount > 0 {
                    Text("\(summary.episodeCount) 集")
                }
                if !heatOnCover, !summary.heat.isEmpty { Text("· \(summary.heat)") }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
    }
}

/// Glass rank number; the top three are tinted brand red.
struct RankBadge: View {
    let rank: Int

    var body: some View {
        Text("\(rank)")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 24)
            .glassSurface(.clear, in: Capsule(), tint: rank <= 3 ? .hongguoRed : .black.opacity(0.25))
    }
}

struct PosterGrid: View {
    let items: [SeriesSummary]
    /// Click plays the series instead of opening its detail page (the actor page, as in the official app).
    var clickPlays = false
    var heatOnCover = false
    var onAppearLast: (() -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 18)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(items) { item in
                PosterCell(item: item, clickPlays: clickPlays, heatOnCover: heatOnCover)
                    .onAppear { if item.id == items.last?.id { onAppearLast?() } }
            }
        }
    }
}

/// One grid cell: click opens the detail page (or plays, with `clickPlays`), the glass play button
/// on hover starts episode 1.
struct PosterCell: View {
    let item: SeriesSummary
    var clickPlays = false
    var heatOnCover = false
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button { if clickPlays { playFirst() } else { model.open(item) } } label: { PosterCard(summary: item, hovering: hovering, heatOnCover: heatOnCover) }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                if hovering {
                    GeometryReader { proxy in
                        Button { playFirst() } label: { Image(systemName: "play.fill").offset(x: 1) }
                            .buttonStyle(GlassIconButtonStyle(diameter: 48))
                            .environment(\.colorScheme, .dark)
                            .help("立即播放第 1 集")
                            .position(x: proxy.size.width / 2, y: proxy.size.width * 4 / 3 / 2)
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
            .contextMenu {
                Button("立即播放第 1 集") { playFirst() }
                if clickPlays { Button("查看详情") { model.open(item) } }
                Button(model.isFavorite(item.seriesId) ? "取消收藏" : "收藏") {
                    model.toggleFavorite(seriesId: item.seriesId, title: item.title, cover: item.cover)
                }
                Button("复制剧集编号") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.seriesId, forType: .string)
                }
            }
    }

    private func playFirst() {
        Task { await PlayerController.shared.open(seriesId: item.seriesId, title: item.title, cover: item.cover) }
    }
}

struct LoadStateView: View {
    let error: String?
    let isLoading: Bool
    let retry: () -> Void

    var body: some View {
        if let error {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试", action: retry)
            }
        } else if isLoading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

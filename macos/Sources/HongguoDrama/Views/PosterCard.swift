import SwiftUI
import HongguoCore

struct CoverImage: View {
    let url: String
    var cornerRadius: CGFloat = 8

    var body: some View {
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.quaternary)
    }
}

struct PosterCard: View {
    let summary: SeriesSummary
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(CoverImage(url: summary.cover))
                    .clipped()
                if let rank = summary.rank {
                    Text("\(rank)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(rank <= 3 ? Color.red : Color.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.1), radius: hovering ? 8 : 3, y: 2)
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)

            Text(summary.title)
                .font(.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 4) {
                if !summary.episodeLabel.isEmpty {
                    Text(summary.episodeLabel)
                } else if summary.episodeCount > 0 {
                    Text("\(summary.episodeCount) 集")
                }
                if !summary.heat.isEmpty { Text("· \(summary.heat)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct PosterGrid: View {
    let items: [SeriesSummary]
    var onAppearLast: (() -> Void)?
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(items) { item in
                Button { model.open(item) } label: { PosterCard(summary: item) }
                    .buttonStyle(.plain)
                    .onAppear { if item.id == items.last?.id { onAppearLast?() } }
                    .contextMenu {
                        Button("立即播放第 1 集") { Task { await PlayerController.shared.open(seriesId: item.seriesId, title: item.title, cover: item.cover) } }
                        Button("在官网打开") { NSWorkspace.shared.open(Site.detailURL(item.seriesId)) }
                        Button("复制剧集编号") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.seriesId, forType: .string)
                        }
                    }
            }
        }
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

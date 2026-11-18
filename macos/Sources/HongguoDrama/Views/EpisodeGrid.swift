import AppKit
import SwiftUI
import HongguoCore

/// Episode picker shared by the detail page and the player drawer.
/// Long series are split into ranges of 30 with a glass segmented selector.
struct EpisodeGrid: View {
    let episodes: [Episode]
    var current: Int?
    var completed: Int = 0
    var minimumCellWidth: CGFloat = 52
    let onSelect: (Episode) -> Void

    static let rangeSize = 30
    @State private var range = 0

    private var ranges: [GlassOption<Int>] {
        guard episodes.count > Self.rangeSize else { return [] }
        return stride(from: 0, to: episodes.count, by: Self.rangeSize).map { start in
            let end = min(start + Self.rangeSize, episodes.count)
            return GlassOption(label: "\(start + 1)–\(end)", value: start / Self.rangeSize)
        }
    }

    private var visible: ArraySlice<Episode> {
        guard !ranges.isEmpty else { return episodes[...] }
        let start = min(range * Self.rangeSize, max(0, episodes.count - 1))
        return episodes[start..<min(start + Self.rangeSize, episodes.count)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ranges.isEmpty {
                GlassSegments(options: ranges, selection: $range, compact: true)
            }
            GlassGroup(spacing: 6) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumCellWidth), spacing: 8)], spacing: 8) {
                    ForEach(visible) { episode in
                        EpisodeCell(episode: episode,
                                    state: state(for: episode.index)) { onSelect(episode) }
                            .id(episode.index)
                    }
                }
            }
        }
        .onAppear { jumpToCurrent() }
        .onChange(of: current) { _, _ in jumpToCurrent() }
    }

    private func state(for index: Int) -> EpisodeCell.State {
        if index == current { return .current }
        if index <= completed { return .watched }
        return .unwatched
    }

    private func jumpToCurrent() {
        guard let current, current >= 1, !ranges.isEmpty else { return }
        range = (current - 1) / Self.rangeSize
    }
}

struct EpisodeCell: View {
    enum State { case watched, current, unwatched }

    let episode: Episode
    let state: State
    let action: () -> Void

    private var isDownloaded: Bool { AppModel.shared.localFiles[episode.vid] != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if state == .current {
                    Image(systemName: "waveform").font(.system(size: 10, weight: .bold))
                }
                Text("\(episode.index)")
                    .font(.system(size: 14, weight: state == .current ? .bold : .medium).monospacedDigit())
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .modifier(EpisodeCellBackground(state: state))
            .overlay(alignment: .topTrailing) {
                if episode.webAvailable == false {
                    Circle().fill(Color.hongguoGold).frame(width: 6, height: 6).padding(7)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isDownloaded {
                Button("下载这一集") {
                    let model = AppModel.shared
                    let player = PlayerController.shared
                    let list = player.episodes?.seriesId == episode.seriesId ? player.episodes : nil
                    Task {
                        await model.download([episode], seriesId: episode.seriesId,
                                             title: list?.title ?? model.library.series(episode.seriesId)?.title ?? "",
                                             cover: list?.cover ?? model.library.series(episode.seriesId)?.cover ?? "")
                    }
                }
            } else {
                Button("在访达中显示") {
                    if let url = AppModel.shared.localFiles[episode.vid] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }
        .help(episode.webAvailable == false ? "第 \(episode.index) 集 · 官网未公开，走 App 片源" : "第 \(episode.index) 集")
    }

    private var foreground: AnyShapeStyle {
        switch state {
        case .current: return AnyShapeStyle(Color.white)
        case .watched: return AnyShapeStyle(.tertiary)
        case .unwatched: return AnyShapeStyle(.primary)
        }
    }
}

private struct EpisodeCellBackground: ViewModifier {
    let state: EpisodeCell.State
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    func body(content: Content) -> some View {
        switch state {
        case .watched:
            content.background(.primary.opacity(0.06), in: shape)
        case .current:
            content.glassSurface(in: shape, tint: .hongguoRed, interactive: true)
        case .unwatched:
            content.glassSurface(.clear, in: shape, interactive: true)
        }
    }
}

/// Legend under the episode grid.
struct EpisodeLegend: View {
    var showsAppSource = true

    var body: some View {
        HStack(spacing: 16) {
            item(color: .primary.opacity(0.12), label: "已看完")
            item(color: .hongguoRed, label: "正在看")
            if showsAppSource {
                HStack(spacing: 6) {
                    Circle().fill(Color.hongguoGold).frame(width: 6, height: 6)
                    Text("官网未公开，走 App 片源")
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func item(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
}

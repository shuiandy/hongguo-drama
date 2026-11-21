import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// The series page: the cover on the left, the information and the episodes on the right. The
/// episodes come in the shared ranges (`EpisodeRanges`, 30 a range), twelve to a row. Back (the
/// Menu button) closes it.
struct DetailPage: View {
    @Environment(TVAppModel.self) private var app
    let series: SeriesSummary

    @State private var loaded: DramaSeries?
    @State private var synopsis = ""
    @State private var state: LoadState? = .loading
    @State private var rangeIndex = 0
    @State private var tint = Color.gray
    @State private var attempt = 0
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case play, range(Int), episode(Int) }

    private static let columns = Array(repeating: GridItem(.fixed(96), spacing: 18), count: 12)

    var body: some View {
        ZStack {
            AmbientBackground(tint: tint)
            HStack(alignment: .top, spacing: 64) {
                PosterImage(series: SeriesSummary(seriesId: series.seriesId, title: title, cover: cover))
                    .frame(width: 400, height: 571)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(radius: 24)
                info
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .background(Color.black)
        .onExitCommand { app.detailTarget = nil }
        // Over the tabs, nothing hands focus over by itself: start (and come back from the player) on 播放.
        .onAppear { DispatchQueue.main.async { focus = .play } }
        .onChange(of: app.playerTarget == nil) { _, closed in if closed { DispatchQueue.main.async { focus = .play } } }
        .task(id: attempt) { await load() }
        .task { if let color = await CoverTint.color(for: cover) { tint = color } else { tint = PlaceholderTint.color(for: series.seriesId) } }
    }

    private var title: String { loaded?.title.isEmpty == false ? loaded!.title : series.title }
    private var cover: String { loaded?.cover.isEmpty == false ? loaded!.cover : series.cover }
    private var record: WatchRecord? {
        _ = app.library.libraryRevision
        return app.library.store.record(for: series.seriesId)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title).font(.title.weight(.bold)).lineLimit(2)
            Text(meta).font(.callout).foregroundStyle(.secondary)
            if !synopsis.isEmpty {
                Text(synopsis).font(.callout).lineLimit(3).foregroundStyle(.secondary)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
            actions
            if let state {
                LoadStateView(state: state) { attempt += 1 }
                    .frame(height: 300)
            } else if let loaded {
                episodes(loaded)
            }
            Spacer(minLength: 0)
        }
    }

    private var meta: String {
        let count = loaded?.total ?? series.episodeCount
        return ([count > 0 ? "全\(count)集" : "", series.heat] + series.tags.prefix(3))
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 28) {
            Button {
                if let record, record.episodeIndex > 0 {
                    app.openPlayer(summary, startEpisode: nil)
                } else {
                    app.openPlayer(summary, startEpisode: 1)
                }
            } label: {
                if let record, record.episodeIndex > 0 {
                    Label("继续看第\(record.episodeIndex)集", systemImage: "play.fill")
                } else {
                    Label("播放第1集", systemImage: "play.fill")
                }
            }
            .focused($focus, equals: .play)
            let favorite = app.library.isFavorite(series.seriesId)
            Button {
                app.library.toggleFavorite(seriesId: series.seriesId, title: title, cover: cover)
            } label: {
                Label(favorite ? "已收藏" : "收藏", systemImage: favorite ? "heart.fill" : "heart")
            }
        }
        .focusSection()
    }

    private var summary: SeriesSummary {
        SeriesSummary(seriesId: series.seriesId, title: title, cover: cover, episodeCount: loaded?.total ?? series.episodeCount)
    }

    private func episodes(_ loaded: DramaSeries) -> some View {
        let ranges = EpisodeRanges.ranges(total: loaded.total)
        let range = ranges.isEmpty ? 1...max(1, loaded.total) : ranges[min(rangeIndex, ranges.count - 1)]
        return VStack(alignment: .leading, spacing: 20) {
            if ranges.count > 1 {
                HStack(spacing: 16) {
                    ForEach(Array(ranges.enumerated()), id: \.offset) { index, item in
                        Button(EpisodeRanges.label(item)) { rangeIndex = index }
                            .font(.callout.weight(index == rangeIndex ? .bold : .regular))
                            .focused($focus, equals: .range(index))
                    }
                }
                .focusSection()
            }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
                ForEach(loaded.episodes.filter { range.contains($0.index) }) { episode in
                    EpisodeCell(number: episode.index, isCurrent: record?.episodeIndex == episode.index,
                                isDisabled: episode.disabled) {
                        app.openPlayer(summary, startEpisode: episode.index)
                    }
                    .focused($focus, equals: .episode(episode.index))
                }
            }
            .focusSection()
        }
    }

    private func load() async {
        state = .loading
        do {
            let result = try await app.backend.series(seriesId: series.seriesId)
            loaded = result
            if let current = record?.episodeIndex, current > 0 {
                rangeIndex = EpisodeRanges.index(of: current, total: result.total)
            }
            state = result.episodes.isEmpty ? .empty("还没有分集") : nil
        } catch {
            state = .failed((error as? HongguoError)?.message ?? "分集暂时取不到")
        }
        synopsis = (try? await app.backend.synopsis(seriesId: series.seriesId)) ?? ""
    }
}

/// One episode in the grid: its number; the one last watched is marked.
struct EpisodeCell: View {
    let number: Int
    var isCurrent = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 96, height: 64)
                .foregroundStyle(isCurrent ? Theme.accent : .primary)
        }
        .buttonStyle(.card)
        .disabled(isDisabled)
        .overlay(alignment: .topTrailing) {
            if isCurrent {
                Image(systemName: "play.fill").font(.caption2).foregroundStyle(Theme.accent).padding(6)
            }
        }
    }
}

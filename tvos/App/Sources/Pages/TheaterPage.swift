import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 剧场: a large 继续观看 card for the series watched last, then one shelf per category (真人剧,
/// 漫剧, AI 剧), each the shared TheaterModel (the same paging rules as the iOS 剧场 grid). The
/// page's colour follows the focused cover.
struct TheaterPage: View {
    @Environment(TVAppModel.self) private var app
    @State private var shelves: [TheaterModel] = []
    @State private var tint = Color.gray
    @State private var releases: NewReleasesPage.Tab?

    var body: some View {
        ZStack {
            AmbientBackground(tint: tint)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 36) {
                    // 新剧 and 追剧日历, as the iOS 剧场's chips.
                    HStack(spacing: 30) {
                        Button("新剧", systemImage: "sparkles") { releases = .recommended }
                        Button("追剧日历", systemImage: "calendar") { releases = .calendar }
                    }
                    .focusSection()
                    if let record = app.library.history().first {
                        ContinueCard(record: record) { follow(SeriesSummary(seriesId: record.seriesId, title: record.title, cover: record.cover)) }
                    }
                    ForEach(shelves, id: \.kind) { model in
                        TheaterShelf(model: model, onFocus: follow)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            if let releases {
                NewReleasesPage(tab: releases) { self.releases = nil }
                    .transition(.opacity)
            }
        }
        .onAppear {
            switch app.launch.route {
            case .newReleases where releases == nil && shelves.isEmpty: releases = .recommended
            case .calendar where releases == nil && shelves.isEmpty: releases = .calendar
            default: break
            }
            if shelves.isEmpty {
                shelves = CatalogKind.categories.map { kind in
                    let model = TheaterModel(backend: app.backend)
                    model.kind = kind
                    return model
                }
            }
        }
    }

    private func follow(_ series: SeriesSummary) {
        Task {
            if let color = await CoverTint.color(for: series.cover) { tint = color }
            else { tint = PlaceholderTint.color(for: series.seriesId) }
        }
    }
}

/// One category's shelf: loads its first page when shown, more as the focus nears the end.
private struct TheaterShelf: View {
    let model: TheaterModel
    let onFocus: (SeriesSummary) -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .failed(let message) where model.items.isEmpty:
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.kind.label).font(.title3.weight(.semibold))
                    Text(message).foregroundStyle(.secondary)
                    Button("重试") { Task { await model.load(forceRefresh: true) } }
                }
            case .loading where model.items.isEmpty, .idle:
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.kind.label).font(.title3.weight(.semibold))
                    ProgressView().frame(height: PosterMetrics.height)
                }
            default:
                Shelf(title: model.kind.label, items: model.items, onFocus: onFocus,
                      onNearEnd: { if model.hasMore { Task { await model.loadMore() } } })
            }
        }
        .task(id: model.filterKey) { if model.items.isEmpty { await model.load(forceRefresh: false) } }
    }
}

/// 继续观看: the series watched last, wide, with where it was left and a progress bar.
struct ContinueCard: View {
    @Environment(TVAppModel.self) private var app
    let record: WatchRecord
    let onFocus: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("继续观看").font(.title3.weight(.semibold))
            Button {
                app.openPlayer(SeriesSummary(seriesId: record.seriesId, title: record.title, cover: record.cover,
                                             episodeCount: record.total))
            } label: {
                HStack(spacing: 36) {
                    PosterImage(series: SeriesSummary(seriesId: record.seriesId, title: record.title, cover: record.cover))
                        .frame(width: 180, height: 257)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 14) {
                        Text(record.title).font(.title2.weight(.bold)).lineLimit(1)
                        Text(record.total > 0 ? "看到第\(record.episodeIndex)集 · 共\(record.total)集" : "看到第\(record.episodeIndex)集")
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(record.episodeIndex), total: Double(max(record.total, record.episodeIndex, 1)))
                            .frame(width: 520)
                        Label("继续播放", systemImage: "play.fill").font(.callout.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                }
                .padding(28)
                .frame(width: 1100, alignment: .leading)
            }
            .buttonStyle(.card)
            .focused($focused)
            .onChange(of: focused) { _, now in if now { onFocus() } }
        }
        .focusSection()
    }
}

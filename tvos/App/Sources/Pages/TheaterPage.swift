import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 剧场, in the iOS 剧场's order: one row of chips (the categories 真人剧 / 漫剧 / AI 剧, the 题材
/// filter, then 追剧日历 and 新剧), and under it the chosen category's grid, the shared
/// TheaterModel (the same paging rules as the iOS grid). The page's colour follows the focused
/// cover. 排行 has its own top tab, so there is no second way into it from here.
struct TheaterPage: View {
    @Environment(TVAppModel.self) private var app
    @State private var model: TheaterModel?
    @State private var tint = Color.gray
    @State private var releases: NewReleasesPage.Tab?

    var body: some View {
        ZStack {
            AmbientBackground(tint: tint)
            if let model {
                TheaterContent(model: model, releases: $releases, onFocus: follow)
                    // Under 新剧 or 追剧日历 the page takes no focus.
                    .disabled(releases != nil)
            }
            if let releases {
                NewReleasesPage(tab: releases) { self.releases = nil }
                    .transition(.opacity)
            }
        }
        .onAppear {
            switch app.launch.route {
            case .newReleases where releases == nil && model == nil: releases = .recommended
            case .calendar where releases == nil && model == nil: releases = .calendar
            default: break
            }
            if model == nil { model = TheaterModel(backend: app.backend) }
        }
    }

    private func follow(_ series: SeriesSummary) {
        Task {
            if let color = await CoverTint.color(for: series.cover) { tint = color }
            else { tint = PlaceholderTint.color(for: series.seriesId) }
        }
    }
}

private struct TheaterContent: View {
    @Environment(TVAppModel.self) private var app
    @Bindable var model: TheaterModel
    @Binding var releases: NewReleasesPage.Tab?
    let onFocus: (SeriesSummary) -> Void

    private static let columns = Array(repeating: GridItem(.fixed(PosterMetrics.width), spacing: PosterMetrics.spacing, alignment: .top), count: 6)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                chips
                grid
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .task(id: model.filterKey) { await model.load(forceRefresh: false) }
    }

    private var chips: some View {
        HStack(spacing: 28) {
            ForEach(CatalogKind.categories) { kind in
                // Choosing another category clears the genre and its list (in the model).
                ChipButton(title: kind.label, active: model.kind == kind) { model.kind = kind }
            }
            Menu {
                Picker("题材", selection: $model.genre) {
                    Text("全部题材").tag(GenreChoice?.none)
                    ForEach(model.genres) { Text($0.label).tag(Optional($0)) }
                }
            } label: {
                Label(model.genre?.label ?? "筛选", systemImage: "line.3.horizontal.decrease")
                    .font(.callout)
            }
            .disabled(model.genres.isEmpty)
            Spacer(minLength: 20)
            ChipButton(title: "追剧日历", systemImage: "calendar", tint: Theme.orange) { releases = .calendar }
            ChipButton(title: "新剧", systemImage: "sparkles", tint: Theme.gold) { releases = .recommended }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    @ViewBuilder private var grid: some View {
        switch model.phase {
        case .failed(let message) where model.items.isEmpty:
            LoadStateView(state: .failed(message)) { Task { await model.load(forceRefresh: true) } }
                .frame(height: 500)
        case .loading where model.items.isEmpty, .idle:
            LoadStateView(state: .loading).frame(height: 500)
        case .loaded where model.items.isEmpty:
            LoadStateView(state: .empty("这里还没有剧")).frame(height: 500)
        default:
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 50) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, series in
                    PosterCard(series: series, onFocus: {
                        onFocus(series)
                        if index >= model.items.count - 6, model.hasMore { Task { await model.loadMore() } }
                    }) { app.openDetail(series) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            if model.hasMore {
                Button("加载更多") { Task { await model.loadMore() } }
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 排行: the shared RankingModel (the official ranking plan, the same as the iOS 排行榜). On the
/// left the categories with their 榜单, on the right the chosen list as a grid of posters with
/// their rank; more rows load as the focus nears the end.
struct RankingPage: View {
    @Environment(TVAppModel.self) private var app
    @State private var model: RankingModel?
    @State private var tint = Color.gray

    private static let columns = Array(repeating: GridItem(.fixed(PosterMetrics.width), spacing: 40, alignment: .top), count: 5)

    var body: some View {
        ZStack {
            AmbientBackground(tint: tint)
            if let model {
                HStack(alignment: .top, spacing: 60) {
                    boards(model)
                        .frame(width: 360)
                    list(model)
                }
                .padding(.horizontal, 80)
                .padding(.top, 30)
            }
        }
        .onAppear { if model == nil { model = RankingModel(backend: app.backend) } }
    }

    private func boards(_ model: RankingModel) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                // Before the categories arrive, the first list is already loading.
                ForEach(model.categories) { category in
                    let chosen = category.id == model.selectedCategoryId
                    Button { model.selectCategory(category) } label: {
                        Text(category.title).font(.headline.weight(chosen ? .bold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if chosen {
                        ForEach(category.boards) { board in
                            let on = board.id == (model.activeBoard?.id ?? model.selectedBoardId)
                            Button { model.selectBoard(board.id) } label: {
                                Label(board.title, systemImage: on ? "chart.bar.fill" : "chart.bar")
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.leading, 24)
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func list(_ model: RankingModel) -> some View {
        let key = model.key(for: model.selectedCategoryId)
        let page = model.rankPages.page(key)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                Text(model.activeBoard.map { "红果\($0.title)" } ?? "排行榜").font(.title2.weight(.bold))
                switch LoadPhase(page.phase) {
                case .failed(let message) where page.items.isEmpty:
                    LoadStateView(state: .failed(message)) { Task { await model.load(key, refresh: true) } }
                        .frame(height: 500)
                case .loading where page.items.isEmpty, .idle where page.items.isEmpty:
                    LoadStateView(state: .loading).frame(height: 500)
                default:
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 40) {
                        ForEach(Array(page.items.enumerated()), id: \.element.id) { index, item in
                            let series = SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover,
                                                       episodeCount: item.episodeCount, tags: [item.metaLine].filter { !$0.isEmpty },
                                                       heat: item.recommendText)
                            PosterCard(series: series, rank: index + 1, onFocus: {
                                follow(series)
                                if index >= page.items.count - 5, page.cursor != nil, !app.backend.isOffline {
                                    Task { await model.loadMore(key) }
                                }
                            }) {
                                if item.playable { app.openPlayer(series) } else { app.openDetail(series) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .focusSection()
        .task(id: key) { if model.rankPages.needsLoad(key) { await model.load(key) } }
    }

    private func follow(_ series: SeriesSummary) {
        Task {
            if let color = await CoverTint.color(for: series.cover) { tint = color }
            else { tint = PlaceholderTint.color(for: series.seriesId) }
        }
    }
}

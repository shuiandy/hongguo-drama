import AppLogic
import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 搜索: the system search field and keyboard (`.searchable`) over the shared SearchModel (the
/// same history, suggestions, boards and paged results as the iOS search page). Before a search:
/// the history, 猜你想搜 and the 热搜榜 / 预约榜 / 热点话题榜 boards; after one: the results grid.
struct SearchPage: View {
    @Environment(TVAppModel.self) private var app
    @State private var model: SearchModel?

    var body: some View {
        NavigationStack {
            if let model {
                SearchContent(model: model)
            } else {
                Color.clear
            }
        }
        .onAppear { if model == nil { model = SearchModel(backend: app.backend) } }
    }
}

private struct SearchContent: View {
    @Environment(TVAppModel.self) private var app
    @Bindable var model: SearchModel

    private static let columns = Array(repeating: GridItem(.fixed(PosterMetrics.width), spacing: 40, alignment: .top), count: 6)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                if model.submittedQuery != nil {
                    results
                } else {
                    landing
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .searchable(text: $model.query, prompt: "搜索短剧")
        .searchSuggestions {
            ForEach(model.liveSuggestions, id: \.self) { word in
                Text(word).searchCompletion(word)
            }
        }
        .onSubmit(of: .search) { model.submitSearch(model.trimmedQuery) }
        .onChange(of: model.query) { _, text in model.queryChanged(text) }
        .task { await model.loadSearchLanding() }
        .task { for board in SearchRankBoard.allCases { await model.loadBoard(board) } }
    }

    // MARK: Before a search

    @ViewBuilder private var landing: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("搜索历史").font(.title3.weight(.semibold))
                    Spacer()
                    Button("清空") { model.clearHistory() }.font(.callout)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(model.history.prefix(12), id: \.self) { word in
                            Button(word) { search(word) }
                                .contextMenu { Button("删除", systemImage: "trash", role: .destructive) { model.removeHistory(word) } }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
        if !model.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("猜你想搜").font(.title3.weight(.semibold))
                    Spacer()
                    Button("换一换", systemImage: "arrow.clockwise") { Task { await model.loadSuggestions(shuffle: true) } }
                        .font(.callout)
                }
                Shelf(title: "", items: model.suggestions.map(summary), onSelect: open(_:))
            }
        }
        board(.hotSearch)
        board(.subscribe)
        topics
    }

    @ViewBuilder private func board(_ board: SearchRankBoard) -> some View {
        let items = model.rankLists[board] ?? []
        if !items.isEmpty {
            Shelf(title: board.label, items: items.map(summary), showsRank: true, onSelect: open(_:),
                  onNearEnd: { if model.rankCursors[board] != nil { Task { await model.loadMoreBoard(board) } } })
        } else if let failed = model.rankFailed[board] {
            VStack(alignment: .leading, spacing: 12) {
                Text(board.label).font(.title3.weight(.semibold))
                Text(failed).foregroundStyle(.secondary)
                Button("重试") { Task { await model.loadBoard(board, force: true) } }
            }
        }
    }

    @ViewBuilder private var topics: some View {
        if let topics = model.hotTopics, !topics.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(SearchRankBoard.hotTopic.label).font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 520), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 18) {
                    ForEach(Array(topics.prefix(12).enumerated()), id: \.offset) { index, topic in
                        Button { search(topic.title) } label: {
                            HStack(spacing: 14) {
                                Text("\(index + 1)").font(.headline.monospacedDigit())
                                    .foregroundStyle(index < 3 ? Theme.accent : .secondary)
                                Text(topic.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .focusSection()
        }
    }

    // MARK: After a search

    @ViewBuilder private var results: some View {
        Text("“\(model.submittedQuery ?? "")”的结果").font(.title2.weight(.bold))
        switch model.phase {
        case .loading:
            LoadStateView(state: .loading).frame(height: 500)
        case .failed(let message):
            LoadStateView(state: .failed(message)) { search(model.submittedQuery ?? "") }.frame(height: 500)
        case .loaded where model.results.isEmpty:
            LoadStateView(state: .empty("没有找到相关短剧")).frame(height: 500)
        default:
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 40) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, series in
                    PosterCard(series: series, onFocus: {
                        if index >= model.results.count - 6, model.searchHasMore { Task { await model.loadMoreResults() } }
                    }) { app.openDetail(series) }
                }
            }
        }
    }

    private func search(_ word: String) { model.submitSearch(word) }

    private func open(_ series: SeriesSummary) { app.openDetail(series) }

    private func summary(_ item: DiscoveryAccess.RankItem) -> SeriesSummary {
        SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover, episodeCount: item.episodeCount,
                      heat: item.recommendText)
    }
}

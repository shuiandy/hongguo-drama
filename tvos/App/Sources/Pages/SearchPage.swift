import AppLogic
import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 搜索: the system search field and keyboard (`.searchable`) over the shared SearchModel (the
/// same history, suggestions, boards and paged results as the iOS search page), laid out in the
/// iOS page's order. Before a search: the history, 猜你想搜 and one card with 热搜榜 / 热点话题榜 /
/// 预约榜; after one: the results grid. The field's hint takes turns through 热搜榜
/// (`SearchHintRule`) and an empty field searches the hint shown. The iOS page's shortcuts
/// (排行, 追剧日历, 上新) are left out: 排行 is a top tab and the other two open from 剧场, one way
/// in each.
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
    @State private var board: SearchRankBoard = .hotSearch
    @State private var hintTurn = 0

    private static let columns = Array(repeating: GridItem(.fixed(PosterMetrics.width), spacing: 40, alignment: .top), count: 6)

    private var hint: String? { SearchHintRule.hint(model.hints, turn: hintTurn) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 44) {
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
        .searchable(text: $model.query, prompt: hint ?? "搜索短剧")
        .searchSuggestions {
            ForEach(model.liveSuggestions, id: \.self) { word in
                Text(word).searchCompletion(word)
            }
        }
        .onSubmit(of: .search) { model.submitSearch(SearchHintRule.submission(typed: model.query, hint: hint)) }
        .onChange(of: model.query) { _, text in model.queryChanged(text) }
        // As on iOS: the landing data and the two lists in parallel, 热点话题榜 when its tab is chosen.
        .task {
            async let landing: Void = model.loadSearchLanding()
            async let hot: Void = model.loadBoard(.hotSearch)
            async let subscribe: Void = model.loadBoard(.subscribe)
            _ = await (landing, hot, subscribe)
        }
        .task(id: board) { await model.loadBoard(board) }
        .task(id: model.hints.count) {
            guard model.hints.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: SearchHintRule.interval)
                guard !Task.isCancelled else { return }
                if model.trimmedQuery.isEmpty { hintTurn += 1 }
            }
        }
    }

    // MARK: Before a search

    @ViewBuilder private var landing: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionTitle(title: "搜索历史", systemImage: "clock.arrow.circlepath", tint: .secondary)
                    Spacer()
                    Button("清空") { model.clearHistory() }.font(.callout)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(model.history.prefix(12), id: \.self) { word in
                            Button(word) { model.submitSearch(word) }
                                .contextMenu { Button("删除", systemImage: "trash", role: .destructive) { model.removeHistory(word) } }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        if !model.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionTitle(title: "猜你想搜", systemImage: "sparkles", tint: Theme.gold)
                    Spacer()
                    Button("换一换", systemImage: "arrow.triangle.2.circlepath") { Task { await model.loadSuggestions(shuffle: true) } }
                        .font(.callout)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 24) {
                        ForEach(model.suggestions, id: \.seriesId) { item in
                            Button { open(item) } label: {
                                HStack(spacing: 14) {
                                    PosterImage(series: SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover))
                                        .frame(width: 42, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(item.title).font(.callout).lineLimit(1).frame(maxWidth: 320, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        rankCard
    }

    /// The three boards in one card: their titles as tabs, the chosen one's list under them.
    private var rankCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 28) {
                ForEach(SearchRankBoard.allCases, id: \.self) { item in
                    ChipButton(title: item.label, active: board == item) { board = item }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            switch board {
            case .hotTopic: topics
            default: boardList(board)
            }
        }
        .padding(36)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28))
    }

    @ViewBuilder private func boardList(_ board: SearchRankBoard) -> some View {
        let items = model.rankLists[board] ?? []
        if !items.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 40, alignment: .leading), GridItem(.flexible(), spacing: 40, alignment: .leading)],
                      alignment: .leading, spacing: 24) {
                ForEach(Array(items.enumerated()), id: \.element.seriesId) { index, item in
                    RankRow(item: item, rank: index + 1, board: board) { open(item) }
                }
            }
            .focusSection()
            // Asked for, not on reaching the end: a failed page keeps its cursor and is tried again here.
            if model.rankCursors[board] != nil {
                Button(model.rankLoading.contains(board) ? "加载中…" : "查看更多") { Task { await model.loadMoreBoard(board) } }
                    .disabled(model.rankLoading.contains(board))
                    .frame(maxWidth: .infinity)
            }
        } else if let failed = model.rankFailed[board] {
            VStack(alignment: .leading, spacing: 12) {
                Text(failed).foregroundStyle(.secondary)
                Button("重试") { Task { await model.loadBoard(board, force: true) } }
            }
        } else if model.rankLoading.contains(board) {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else {
            Text("暂时没有内容").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    @ViewBuilder private var topics: some View {
        if let topics = model.hotTopics, !topics.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 40, alignment: .leading), GridItem(.flexible(), spacing: 40, alignment: .leading)],
                      alignment: .leading, spacing: 18) {
                ForEach(Array(topics.prefix(20).enumerated()), id: \.offset) { index, topic in
                    Button { model.submitSearch(topic.title) } label: {
                        HStack(spacing: 18) {
                            Text("\(index + 1)").font(.headline.monospacedDigit().italic())
                                .foregroundStyle(Theme.rank(index + 1))
                                .frame(width: 44)
                            Text(topic.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .focusSection()
        } else if let failed = model.hotTopicsFailed {
            VStack(alignment: .leading, spacing: 12) {
                Text(failed).foregroundStyle(.secondary)
                Button("重试") { Task { await model.loadHotTopics(force: true) } }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    // MARK: After a search

    @ViewBuilder private var results: some View {
        Text("“\(model.submittedQuery ?? "")”的结果").font(.title2.weight(.bold))
        switch model.phase {
        case .loading:
            LoadStateView(state: .loading).frame(height: 500)
        case .failed(let message):
            LoadStateView(state: .failed(message)) { model.submitSearch(model.submittedQuery ?? "") }.frame(height: 500)
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

    /// A pick from a board or 猜你想搜, where the shared rule sends it: the player when it is out,
    /// its series page as 待上线 when it is still to come.
    private func open(_ item: DiscoveryAccess.RankItem) {
        switch RankItemDestination(item) {
        case .player(let summary):
            app.openPlayer(summary)
        case .upcoming(var summary, _):
            summary.episodeLabel = SeriesDetailModel.upcomingLabel
            app.openDetail(summary)
        }
    }
}

/// One line of a board: the rank (warm for the first three), a small cover, the title, the
/// board's figure (热度, or 预约 on 预约榜) and the shared subtitle.
private struct RankRow: View {
    let item: DiscoveryAccess.RankItem
    let rank: Int
    let board: SearchRankBoard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 22) {
                Text("\(rank)")
                    .font(.system(size: rank <= 3 ? 40 : 32, weight: .heavy, design: .rounded).italic())
                    .foregroundStyle(Theme.rank(rank))
                    .frame(width: 56)
                PosterImage(series: SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover))
                    .frame(width: 84, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.headline).lineLimit(1)
                    if !item.recommendText.isEmpty {
                        Label(item.recommendText, systemImage: board == .subscribe ? "bell.fill" : "flame.fill")
                            .font(.caption)
                            .foregroundStyle(rank <= 3 ? Theme.rank(rank) : .secondary)
                    }
                    Text(item.boardSubtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.card)
    }
}

import AppLogic
import Foundation
import HongguoCore
import HongguoPlayback
import Observation

/// The boards under the search field before anything is typed.
public enum SearchRankBoard: CaseIterable, Hashable, Sendable {
    case hotSearch, hotTopic, subscribe

    public var label: String {
        switch self {
        case .hotSearch: return "热搜榜"
        case .hotTopic: return "热点话题榜"
        case .subscribe: return "预约榜"
        }
    }

    /// The official ranking board behind the list (`/reading/bookapi/plan/v/`, 全部 category).
    /// 热点话题榜 comes from the search landing plan (`from=search_input_page`, `show_type=619`).
    public var boardId: String? {
        switch self {
        case .hotSearch: return "ranklist_hot_search_sc"
        case .hotTopic: return nil
        case .subscribe: return "ranklist_subscribe"
        }
    }
}

/// The search field's hint and what submitting an empty field searches for, as on the iOS search
/// page: 热搜榜's first eight titles take turns as the hint, and an empty field searches the hint
/// shown.
public enum SearchHintRule {
    /// The hints: the first eight titles of 热搜榜.
    public static func hints(from hotSearch: [DiscoveryAccess.RankItem]) -> [String] {
        hotSearch.prefix(8).map(\.title)
    }

    /// The hint shown at a turn (the turn counts up every time the hint changes); nil with no hints.
    public static func hint(_ hints: [String], turn: Int) -> String? {
        hints.isEmpty ? nil : hints[turn % hints.count]
    }

    /// What submitting the field searches for: what was typed, or the hint shown when nothing was.
    public static func submission(typed: String, hint: String?) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (hint ?? "") : trimmed
    }
}

/// Where a board item opens, as on the iOS search page: a playable series goes to the player, one
/// not out yet to its series page as 待上线 (with its reservation id).
public enum RankItemDestination: Equatable, Sendable {
    case player(SeriesSummary)
    case upcoming(SeriesSummary, subscribeItemId: String)

    public init(_ item: DiscoveryAccess.RankItem) {
        let summary = SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover,
                                    episodeCount: item.episodeCount, description: item.intro)
        self = item.playable ? .player(summary) : .upcoming(summary, subscribeItemId: item.subscribeItemId)
    }
}

/// 搜索: local history (newest first, same key as the iOS app, `searchHistory`), typing
/// suggestions from history and the official suggest endpoint, 猜你想搜 with 换一换, 热搜榜 /
/// 热点话题榜 / 预约榜 with more pages, and the paged results of a submitted search. Moved
/// unchanged from the iOS SearchView (from its committed code; the iOS view does not use this yet:
/// another thread is changing it). A new search or new text drops the previous search's replies.
@MainActor
@Observable
public final class SearchModel {
    public var query: String
    public private(set) var results: [SeriesSummary] = []
    public private(set) var phase: LoadPhase = .idle
    public private(set) var searchPage = 1
    public private(set) var searchHasMore = false
    public private(set) var searchCursor: AppSearchCursor?
    public private(set) var loadingMore = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    public private(set) var submittedQuery: String?
    public private(set) var rankLists: [SearchRankBoard: [DiscoveryAccess.RankItem]] = [:]
    public private(set) var rankCursors: [SearchRankBoard: DiscoveryAccess.RankCursor] = [:]
    public private(set) var rankFailed: [SearchRankBoard: String] = [:]
    public private(set) var rankLoading: Set<SearchRankBoard> = []
    public private(set) var hotTopics: [DiscoveryAccess.HotTopicItem]?
    public private(set) var hotTopicsFailed: String?
    public private(set) var hotTopicsLoading = false
    public private(set) var suggestions: [DiscoveryAccess.RankItem] = []
    @ObservationIgnored private var suggestionPool: [DiscoveryAccess.RankItem] = []
    public private(set) var liveSuggestions: [String] = []
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    public var editingHistory = false
    public private(set) var historyText: String {
        didSet { defaults.set(historyText, forKey: Self.historyKey) }
    }
    @ObservationIgnored private let backend: any DramaBackend
    @ObservationIgnored private let defaults: UserDefaults
    static let historyKey = "searchHistory"

    public init(backend: any DramaBackend, query: String = "", defaults: UserDefaults = .standard) {
        self.backend = backend
        self.query = query
        self.defaults = defaults
        historyText = defaults.string(forKey: Self.historyKey) ?? ""
    }

    public var history: [String] { SearchHistoryRule.decode(historyText) }
    /// The search field's hints (`SearchHintRule`), from 热搜榜 once it is loaded.
    public var hints: [String] { SearchHintRule.hints(from: rankLists[.hotSearch] ?? []) }

    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func clearHistory() {
        historyText = ""
        editingHistory = false
    }

    /// The text in the field changed (typed, or filled from a chip): drops a stale search and
    /// asks for suggestions.
    public func queryChanged(_ text: String) {
            suggestTask?.cancel()
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Programmatic fill from tapping a history/suggestion chip: do not cancel the
            // search that `submitSearch` just started for this exact keyword.
            if let submittedQuery, cleaned == submittedQuery { return }
            submittedQuery = nil
            searchTask?.cancel()
            searchTask = nil
            searchGeneration += 1
            searchHasMore = false
            loadingMore = false
            if cleaned.isEmpty {
                results = []
                liveSuggestions = []
                phase = .idle
            } else if phase != .idle {
                results = []
                phase = .idle
                scheduleSuggestions(for: cleaned)
            } else {
                scheduleSuggestions(for: cleaned)
            }
    }

    public func removeHistory(_ word: String) {
        let next = SearchHistoryRule.remove(word, from: history)
        historyText = SearchHistoryRule.encode(next)
        if next.isEmpty { editingHistory = false }
    }

    private func scheduleSuggestions(for keyword: String) {
        guard !backend.isOffline else { liveSuggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let words = await DiscoveryAccess.searchSuggestions(query: keyword)
            guard !Task.isCancelled else { return }
            liveSuggestions = words
        }
    }

    /// Loads official 猜你想搜 (`show_type=483`) and 热点话题榜 (`show_type=619`) together from
    /// `/reading/bookapi/plan/v/?scene=10&from=search_input_page&new_search_middle_page=1&search_middle_page_version=5`.
    public func loadSearchLanding() async {
        if backend.isOffline {
            hotTopics = []
            await loadSuggestions(shuffle: false)
            return
        }
        hotTopicsLoading = true
        hotTopicsFailed = nil
        defer { hotTopicsLoading = false }
        do {
            let landing = try await DiscoveryAccess.searchLanding()
            guard !Task.isCancelled else { return }
            hotTopics = landing.hotTopics
            if !landing.guessItems.isEmpty {
                suggestions = Array(landing.guessItems.prefix(3))
                var seen = Set(suggestionPool.map(\.seriesId))
                for item in landing.guessItems where seen.insert(item.seriesId).inserted {
                    suggestionPool.append(item)
                }
                CoverPrefetch.prefetch(suggestions.map(\.cover))
            } else {
                await loadSuggestions(shuffle: false)
            }
        } catch is CancellationError {
        } catch {
            if hotTopics == nil { hotTopicsFailed = describeError(error) }
            if suggestions.isEmpty { await loadSuggestions(shuffle: false) }
        }
    }

    public func loadHotTopics(force: Bool = false) async {
        guard force || hotTopics == nil, !hotTopicsLoading else { return }
        if backend.isOffline {
            hotTopics = []
            return
        }
        hotTopicsLoading = true
        hotTopicsFailed = nil
        defer { hotTopicsLoading = false }
        do {
            let landing = try await DiscoveryAccess.searchLanding()
            guard !Task.isCancelled else { return }
            hotTopics = landing.hotTopics
            if suggestions.isEmpty, !landing.guessItems.isEmpty {
                suggestions = Array(landing.guessItems.prefix(3))
                CoverPrefetch.prefetch(suggestions.map(\.cover))
            }
        } catch is CancellationError {
        } catch {
            if hotTopics?.isEmpty ?? true { hotTopicsFailed = describeError(error) }
        }
    }

    /// 猜你想搜: uses official searchLanding guesses when online; 换一换 fetches fresh guesses
    /// or rotates through the hot drama pool if the server returns the same set.
    public func loadSuggestions(shuffle: Bool) async {
        if shuffle, !backend.isOffline {
            if let landing = try? await DiscoveryAccess.searchLanding(), !landing.guessItems.isEmpty {
                let next = Array(landing.guessItems.prefix(3))
                if !landing.hotTopics.isEmpty { hotTopics = landing.hotTopics }
                if next.map(\.seriesId) != suggestions.map(\.seriesId) {
                    suggestions = next
                    CoverPrefetch.prefetch(suggestions.map(\.cover))
                    return
                }
            }
        }
        if suggestionPool.count <= 3 {
            async let real = try? await backend.catalog(kind: .hotDrama, genre: nil, page: 1).items
            async let comic = try? await backend.catalog(kind: .hotComicDrama, genre: nil, page: 1).items
            let merged = ((await comic) ?? []) + ((await real) ?? [])
            var seen = Set(suggestionPool.map(\.seriesId))
            let added = merged.filter { seen.insert($0.seriesId).inserted }.map {
                DiscoveryAccess.RankItem(seriesId: $0.seriesId, title: $0.title, cover: $0.cover, episodeCount: $0.episodeCount,
                                         recommendText: $0.heat, metaLine: "", intro: $0.description, metricTags: [],
                                         badgeText: "", playable: $0.episodeLabel != SeriesDetailModel.upcomingLabel)
            }
            suggestionPool.append(contentsOf: added)
        }
        guard !suggestionPool.isEmpty else { return }
        if shuffle, let first = suggestions.first, let at = suggestionPool.firstIndex(where: { $0.seriesId == first.seriesId }) {
            let start = (at + 3) % suggestionPool.count
            suggestions = (0..<min(3, suggestionPool.count)).map { suggestionPool[(start + $0) % suggestionPool.count] }
        } else {
            suggestions = Array(suggestionPool.prefix(3))
        }
        CoverPrefetch.prefetch(suggestions.map(\.cover))
    }

    public func loadBoard(_ board: SearchRankBoard, force: Bool = false) async {
        if board == .hotTopic {
            await loadHotTopics(force: force)
            return
        }
        guard let boardId = board.boardId, force || rankLists[board] == nil, !rankLoading.contains(board) else { return }
        rankLoading.insert(board)
        defer { rankLoading.remove(board) }
        rankFailed[board] = nil
        do {
            if backend.isOffline {
                // Offline sample data has no boards: the hot catalogue stands in for 热搜榜 only.
                let items = board == .hotSearch ? ((try? await backend.catalog(kind: .hotDrama, genre: nil, page: 1).items) ?? []) : []
                rankLists[board] = items.map {
                    DiscoveryAccess.RankItem(seriesId: $0.seriesId, title: $0.title, cover: $0.cover, episodeCount: $0.episodeCount,
                                             recommendText: $0.heat, metaLine: "", intro: $0.description, metricTags: [],
                                             badgeText: "", playable: true)
                }
                rankCursors[board] = nil
                return
            }
            let page = try await DiscoveryAccess.ranking(selectedItem: "all", subSelectedItem: boardId)
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            let unique = page.items.filter { seen.insert($0.seriesId).inserted }
            rankLists[board] = unique
            rankCursors[board] = page.hasMore ? page.cursor : nil
            CoverPrefetch.prefetch(unique.map(\.cover))
        } catch is CancellationError {
        } catch {
            if rankLists[board]?.isEmpty ?? true { rankFailed[board] = describeError(error) }
        }
    }

    public func loadMoreBoard(_ board: SearchRankBoard) async {
        guard let boardId = board.boardId, let cursor = rankCursors[board], !rankLoading.contains(board) else { return }
        rankLoading.insert(board)
        defer { rankLoading.remove(board) }
        do {
            let page = try await DiscoveryAccess.rankingMore(cursor: cursor, selectedItem: "all", subSelectedItem: boardId)
            guard !Task.isCancelled else { return }
            let existing = Set((rankLists[board] ?? []).map(\.seriesId))
            let added = page.items.filter { !existing.contains($0.seriesId) }
            rankLists[board, default: []].append(contentsOf: added)
            rankCursors[board] = page.hasMore && !added.isEmpty ? page.cursor : nil
            CoverPrefetch.prefetch(added.map(\.cover))
        } catch {
            // Keep the cursor intact so a transient network failure can be retried by tapping 查看更多 again.
        }
    }

    public func submitSearch(_ raw: String) {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        submittedQuery = keyword
        if query != keyword { query = keyword }
        suggestTask?.cancel()
        searchTask?.cancel()
        liveSuggestions = []
        editingHistory = false
        historyText = SearchHistoryRule.encode(SearchHistoryRule.record(keyword, in: history))
        searchGeneration += 1
        let gen = searchGeneration
        results = []
        searchPage = 1
        searchHasMore = false
        searchCursor = nil
        loadingMore = false
        phase = .loading
        searchTask = Task {
            do {
                let page = try await backend.searchPage(keyword, page: 1, cursor: nil)
                guard !Task.isCancelled, searchGeneration == gen else { return }
                results = page.items
                searchPage = 1
                searchHasMore = page.hasMore
                searchCursor = page.cursor
                phase = .loaded
                CoverPrefetch.prefetch(page.items.map(\.cover))
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, searchGeneration == gen else { return }
                phase = .failed(describeError(error))
            }
        }
    }

    public func loadMoreResults() async {
        guard let keyword = submittedQuery, !keyword.isEmpty, searchHasMore, !loadingMore else { return }
        let gen = searchGeneration
        let nextPage = searchPage + 1
        let cursor = searchCursor
        loadingMore = true
        defer { if searchGeneration == gen { loadingMore = false } }
        do {
            let page = try await backend.searchPage(keyword, page: nextPage, cursor: cursor)
            guard !Task.isCancelled, searchGeneration == gen, searchPage == nextPage - 1 else { return }
            let existing = Set(results.map(\.seriesId))
            let added = page.items.filter { !existing.contains($0.seriesId) }
            results.append(contentsOf: added)
            searchPage = nextPage
            searchCursor = page.cursor
            searchHasMore = page.hasMore && !added.isEmpty
            CoverPrefetch.prefetch(added.map(\.cover))
        } catch {
        }
    }
}

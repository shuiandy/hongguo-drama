import AppLogic
import Foundation
import HongguoCore
import HongguoPlayback
import Observation

/// A 排行榜 list: the category page it belongs to and the 榜单 and 分类 chosen on it.
public struct RankKey: Hashable, Sendable {
    public var category: String
    public var board: String
    public var panel: String

    public init(category: String, board: String, panel: String) {
        self.category = category
        self.board = board
        self.panel = panel
    }
}

/// 排行榜: category pages (全部, 漫剧, 真人剧, AI剧), the 榜单 and 分类 chosen on each, and one paged
/// list per choice kept while the page is open. Moved unchanged from the iOS RankingView: replies
/// land under the list they were asked for (TabPages' tickets), never on another; a refresh keeps
/// the rows; offline the sample rows stand in with sample categories.
@MainActor
@Observable
public final class RankingModel {
    public private(set) var categories: [DiscoveryAccess.RankCategoryTab] = []
    public var selectedCategoryId = "all"
    public var selectedBoardId = "ranklist_hot_sc"
    public var selectedPanelId = ""
    /// One list per category page, and per 榜单 and 分类 chosen on it, kept while 排行榜 is open:
    /// going back to a page shows what it had; a page with nothing yet shows its own spinner.
    public private(set) var rankPages = TabPages<RankKey, DiscoveryAccess.RankItem, DiscoveryAccess.RankCursor>()
    @ObservationIgnored private let backend: any DramaBackend

    public init(backend: any DramaBackend) {
        self.backend = backend
    }

    /// Chooses another 榜单 on the page in view; its 分类 starts over.
    public func selectBoard(_ id: String) {
        guard id != selectedBoardId else { return }
        selectedBoardId = id
        selectedPanelId = ""
    }

    public var activeCategory: DiscoveryAccess.RankCategoryTab? {
        categories.first(where: { $0.id == selectedCategoryId }) ?? categories.first
    }

    public var activeBoards: [DiscoveryAccess.RankBoardTab] {
        activeCategory?.boards ?? []
    }

    /// The pages, one per category (just the chosen one until the categories have loaded).
    public var pageTabs: [String] {
        categories.isEmpty ? [selectedCategoryId] : categories.map(\.id)
    }

    /// The list a category page shows: the chosen 榜单 and 分类 on the page in view; a neighbour
    /// shows its first 榜单, which is what it opens on when swiped or tapped to.
    public func key(for categoryId: String) -> RankKey {
        if categoryId == selectedCategoryId {
            return RankKey(category: categoryId, board: selectedBoardId, panel: selectedPanelId)
        }
        let firstBoard = categories.first(where: { $0.id == categoryId })?.boards.first?.id ?? ""
        return RankKey(category: categoryId, board: firstBoard, panel: "")
    }

    public func selectCategory(_ cat: DiscoveryAccess.RankCategoryTab) {
        guard cat.id != selectedCategoryId else { return }
        selectedCategoryId = cat.id
        selectedBoardId = cat.boards.first?.id ?? ""
        selectedPanelId = ""
    }

    public var activeBoard: DiscoveryAccess.RankBoardTab? {
        activeBoards.first(where: { $0.id == selectedBoardId }) ?? activeBoards.first
    }

    public var activeFilterGroups: [DiscoveryAccess.RankFilterGroup] {
        activeBoard?.filterGroups ?? []
    }

    public var activeFilterTitle: String? {
        guard !selectedPanelId.isEmpty else { return nil }
        for group in activeFilterGroups {
            if let hit = group.options.first(where: { $0.id == selectedPanelId }) {
                return hit.title
            }
        }
        return nil
    }

    public func load(_ key: RankKey, refresh: Bool = false) async {
        let ticket = rankPages.beginLoad(key, keepingItems: refresh)
        if backend.isOffline {
            let items = await offlineRankItems(for: key)
            rankPages.finishLoad(ticket, items: items, cursor: nil)
            return
        }
        do {
            let page = try await DiscoveryAccess.ranking(
                selectedItem: key.category,
                subSelectedItem: key.board,
                panelSelectedItem: key.panel
            )
            if !page.categories.isEmpty, key.category == selectedCategoryId || categories.isEmpty {
                categories = page.categories
            }
            rankPages.finishLoad(ticket, items: page.items, cursor: page.cursor)
            CoverPrefetch.prefetch(page.items.map(\.cover))
        } catch {
            rankPages.failLoad(ticket, message: describeError(error))
        }
    }

    public func loadMore(_ key: RankKey) async {
        guard !backend.isOffline, let cursor = rankPages.page(key).cursor, let ticket = rankPages.beginMore(key) else { return }
        do {
            let page = try await DiscoveryAccess.rankingMore(
                cursor: cursor,
                selectedItem: key.category,
                subSelectedItem: key.board,
                panelSelectedItem: key.panel
            )
            let shown = Set(rankPages.page(key).items.map(\.id))
            if rankPages.finishMore(ticket, items: page.items, cursor: page.cursor) {
                CoverPrefetch.prefetch(page.items.filter { !shown.contains($0.id) }.map(\.cover))
            }
        } catch {
            // The rows stay; the next scroll to the end tries again.
            rankPages.failMore(ticket)
        }
    }

    private func offlineRankItems(for key: RankKey) async -> [DiscoveryAccess.RankItem] {
        if categories.isEmpty {
            let sampleGroups = [
                DiscoveryAccess.RankFilterGroup(title: "综合", options: [
                    .init(id: "", title: "总榜", isSelected: true),
                    .init(id: "gender_female", title: "女频", isSelected: false),
                    .init(id: "gender_male", title: "男频", isSelected: false),
                ]),
                DiscoveryAccess.RankFilterGroup(title: "主题情节", options: [
                    .init(id: "cate_739", title: "逆袭", isSelected: false),
                    .init(id: "cate_36", title: "重生", isSelected: false),
                    .init(id: "cate_261", title: "都市日常", isSelected: false),
                ]),
            ]
            let boards = [
                DiscoveryAccess.RankBoardTab(id: "ranklist_hot_sc", title: "推荐榜", isSelected: true, filterGroups: sampleGroups),
                DiscoveryAccess.RankBoardTab(id: "ranklist_hot_play_sc", title: "热播榜", isSelected: false, filterGroups: sampleGroups),
            ]
            categories = [
                DiscoveryAccess.RankCategoryTab(id: "all", title: "全部", isSelected: true, boards: boards),
                DiscoveryAccess.RankCategoryTab(id: "comic_series_rank", title: "漫剧", isSelected: false, boards: boards),
                DiscoveryAccess.RankCategoryTab(id: "human", title: "真人剧", isSelected: false, boards: boards),
                DiscoveryAccess.RankCategoryTab(id: "ai_playlet", title: "AI剧", isSelected: false, boards: boards),
            ]
        }
        await FixtureDebug.wait()
        let cat = categories.first(where: { $0.id == key.category })
        let tag = [cat?.title, cat?.boards.first(where: { $0.id == key.board })?.title].compactMap { $0 }.joined(separator: "·")
        let sample = (try? await backend.catalog(kind: .hotDrama, genre: nil, page: 1).items) ?? []
        return sample.map {
            DiscoveryAccess.RankItem(
                seriesId: $0.seriesId, title: FixtureDebug.title($0.title, tab: tag), cover: $0.cover, episodeCount: $0.episodeCount,
                recommendText: $0.heat, metaLine: $0.tags.joined(separator: "·"),
                intro: $0.description, metricTags: [$0.heat].filter { !$0.isEmpty }, badgeText: "", playable: true
            )
        }
    }
}

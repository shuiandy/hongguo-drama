// SPDX-License-Identifier: GPL-3.0-only
// Read-only discovery endpoints using the core's anonymous metadata signing profile:
// 1. Official ranking boards & multi-level filters (`/reading/bookapi/plan/v/` + `bookmall/cell/change/v`)
// 2. Release calendar (`/reading/user/subscribe/list/v1/` with `tab_type=5`, `target_date=YYYYMMDD`)
// 3. New drama recommendations by gender (`/reading/distribution/category/landpage/v/`)
// 4. Search keyword suggestions (`/reading/bookapi/search/suggest/v/`)
import Foundation

public enum DiscoveryAccess {
    public static let defaultHost = "https://reading.snssdk.com"

    // MARK: - Ranking Models

    public struct RankFilterOption: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var isSelected: Bool
        public init(id: String, title: String, isSelected: Bool) {
            self.id = id; self.title = title; self.isSelected = isSelected
        }
    }

    public struct RankFilterGroup: Identifiable, Hashable, Sendable {
        public var id: String { title }
        public var title: String
        public var options: [RankFilterOption]
        public init(title: String, options: [RankFilterOption]) {
            self.title = title; self.options = options
        }
    }

    public struct RankBoardTab: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var isSelected: Bool
        public var filterGroups: [RankFilterGroup]
        public init(id: String, title: String, isSelected: Bool, filterGroups: [RankFilterGroup]) {
            self.id = id; self.title = title; self.isSelected = isSelected; self.filterGroups = filterGroups
        }
    }

    public struct RankCategoryTab: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var isSelected: Bool
        public var boards: [RankBoardTab]
        public init(id: String, title: String, isSelected: Bool, boards: [RankBoardTab]) {
            self.id = id; self.title = title; self.isSelected = isSelected; self.boards = boards
        }
    }

    public struct RankItem: Identifiable, Equatable, Sendable {
        public var seriesId: String
        public var title: String
        public var cover: String
        public var episodeCount: Int
        public var recommendText: String
        public var metaLine: String
        public var intro: String
        public var metricTags: [String]
        public var badgeText: String
        public var playable: Bool
        public var subscribeItemId: String
        public var id: String { seriesId }
        public init(seriesId: String, title: String, cover: String, episodeCount: Int, recommendText: String,
                    metaLine: String, intro: String, metricTags: [String], badgeText: String, playable: Bool,
                    subscribeItemId: String = "") {
            self.seriesId = seriesId; self.title = title; self.cover = cover; self.episodeCount = episodeCount
            self.recommendText = recommendText; self.metaLine = metaLine; self.intro = intro
            self.metricTags = metricTags; self.badgeText = badgeText; self.playable = playable
            self.subscribeItemId = subscribeItemId
        }
    }

    public struct RankCursor: Equatable, Sendable {
        public var cellId: String
        public var offset: Int
        public var sessionId: String
        public init(cellId: String, offset: Int, sessionId: String) {
            self.cellId = cellId; self.offset = offset; self.sessionId = sessionId
        }
    }

    public struct RankPage: Equatable, Sendable {
        public var categories: [RankCategoryTab]
        public var items: [RankItem]
        public var hasMore: Bool
        public var cursor: RankCursor?
        public init(categories: [RankCategoryTab], items: [RankItem], hasMore: Bool, cursor: RankCursor?) {
            self.categories = categories; self.items = items; self.hasMore = hasMore; self.cursor = cursor
        }
    }

    // MARK: - Calendar & New Releases Models

    public struct CalendarDay: Identifiable, Hashable, Sendable {
        /// `YYYYMMDD` in Asia/Shanghai time, matching `target_date`.
        public var targetDate: String
        /// Short date label, e.g. `11-20`.
        public var monthDay: String
        /// Weekday or relative label, e.g. `今天`, `周四`, `周六`.
        public var subtitle: String
        public var isToday: Bool
        public var id: String { targetDate }
        public init(targetDate: String, monthDay: String, subtitle: String, isToday: Bool) {
            self.targetDate = targetDate; self.monthDay = monthDay; self.subtitle = subtitle; self.isToday = isToday
        }
    }

    public struct CalendarItem: Identifiable, Equatable, Sendable {
        public var seriesId: String
        public var title: String
        public var cover: String
        public var isOnline: Bool
        public var heatText: String
        public var categoriesLine: String
        public var categoryLabel: String
        public var episodeCount: Int
        public var description: String
        public var id: String { "\(seriesId):\(isOnline ? 1 : 0)" }
        public init(seriesId: String, title: String, cover: String, isOnline: Bool, heatText: String,
                    categoriesLine: String, categoryLabel: String, episodeCount: Int, description: String) {
            self.seriesId = seriesId; self.title = title; self.cover = cover; self.isOnline = isOnline
            self.heatText = heatText; self.categoriesLine = categoriesLine; self.categoryLabel = categoryLabel
            self.episodeCount = episodeCount; self.description = description
        }
    }

    public struct CalendarPage: Equatable, Sendable {
        public var items: [CalendarItem]
        public var hasMore: Bool
        public var nextOffset: Int
        public var sessionId: String
        public init(items: [CalendarItem], hasMore: Bool, nextOffset: Int, sessionId: String) {
            self.items = items; self.hasMore = hasMore; self.nextOffset = nextOffset; self.sessionId = sessionId
        }
    }

    public enum NewDramaGender: String, CaseIterable, Identifiable, Sendable {
        case all = ""
        case male = "1"
        case female = "0"

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .all: return "全部性别"
            case .male: return "男生"
            case .female: return "女生"
            }
        }
    }

    public struct NewDramaItem: Identifiable, Equatable, Sendable {
        public var seriesId: String
        public var title: String
        public var cover: String
        public var episodeCount: Int
        public var heatText: String
        public var badgeText: String
        public var categoryLabel: String
        public var subtitle: String
        public var description: String
        public var id: String { seriesId }
        public init(seriesId: String, title: String, cover: String, episodeCount: Int, heatText: String,
                    badgeText: String, categoryLabel: String, subtitle: String, description: String) {
            self.seriesId = seriesId; self.title = title; self.cover = cover; self.episodeCount = episodeCount
            self.heatText = heatText; self.badgeText = badgeText; self.categoryLabel = categoryLabel
            self.subtitle = subtitle; self.description = description
        }
    }

    public struct NewDramaPage: Equatable, Sendable {
        public var items: [NewDramaItem]
        public var hasMore: Bool
        public var nextOffset: Int
        public var sessionId: String
        public init(items: [NewDramaItem], hasMore: Bool, nextOffset: Int, sessionId: String) {
            self.items = items; self.hasMore = hasMore; self.nextOffset = nextOffset; self.sessionId = sessionId
        }
    }

    // MARK: - Same-IP Multi-Season Series (系列剧)

    public struct RelatedSeriesItem: Identifiable, Equatable, Sendable {
        public var seriesId: String
        public var title: String
        public var cover: String
        public var seasonIndex: Int
        public var episodeCount: Int
        public var heatText: String
        public var subtitle: String
        public var disablePlay: Bool
        public var categoryLabel: String
        public var description: String
        public var subscribeItemId: String
        public var badgeText: String
        public var id: String { seriesId }
        public init(seriesId: String, title: String, cover: String, seasonIndex: Int, episodeCount: Int,
                    heatText: String, subtitle: String, disablePlay: Bool, categoryLabel: String, description: String,
                    subscribeItemId: String = "", badgeText: String = "") {
            self.seriesId = seriesId; self.title = title; self.cover = cover; self.seasonIndex = seasonIndex
            self.episodeCount = episodeCount; self.heatText = heatText; self.subtitle = subtitle
            self.disablePlay = disablePlay; self.categoryLabel = categoryLabel; self.description = description
            self.subscribeItemId = subscribeItemId; self.badgeText = badgeText
        }
    }

    public struct RelatedNovelInfo: Equatable, Sendable {
        public var bookId: String
        public var bookName: String
        public var author: String
        public init(bookId: String, bookName: String, author: String) {
            self.bookId = bookId; self.bookName = bookName; self.author = author
        }
    }

    public struct SameIPSeriesResult: Equatable, Sendable {
        public var tabTitle: String
        public var items: [RelatedSeriesItem]
        public var novel: RelatedNovelInfo?
        public var currentSeasonIndex: Int
        public init(tabTitle: String, items: [RelatedSeriesItem], novel: RelatedNovelInfo?, currentSeasonIndex: Int) {
            self.tabTitle = tabTitle; self.items = items; self.novel = novel; self.currentSeasonIndex = currentSeasonIndex
        }
    }

    // MARK: - Category Catalog Browse (剧场分类)

    public struct CatalogBrowseResult: Equatable, Sendable {
        public var items: [SeriesSummary]
        public var genres: [Genre]
        public var hasMore: Bool
        public var totalPages: Int
        public init(items: [SeriesSummary], genres: [Genre], hasMore: Bool, totalPages: Int) {
            self.items = items; self.genres = genres; self.hasMore = hasMore; self.totalPages = totalPages
        }
    }

    private static let catalogCache = TTLCache<CatalogBrowseResult>(limit: 32)

    // MARK: - Ranking Requests

    public static func ranking(
        selectedItem: String = "all",
        subSelectedItem: String = "ranklist_hot_sc",
        panelSelectedItem: String = "",
        timeout: TimeInterval = 10
    ) async throws -> RankPage {
        var values: [(String, String)] = [
            ("scene", "10"),
            ("bookstore_tab_type", "26"),
            ("from", "video_ranklist"),
        ]
        if !selectedItem.isEmpty { values.append(("selected_items", selectedItem)) }
        if !subSelectedItem.isEmpty { values.append(("sub_selected_items", subSelectedItem)) }
        if !panelSelectedItem.isEmpty { values.append(("panel_selected_items", panelSelectedItem)) }

        let payload = try await AppBookMallAccess.tab(
            values: values,
            host: defaultHost,
            path: "/reading/bookapi/plan/v/",
            timeout: timeout
        )
        return try parseRankPlan(payload)
    }

    public static func rankingMore(
        cursor: RankCursor,
        selectedItem: String,
        subSelectedItem: String,
        panelSelectedItem: String = "",
        timeout: TimeInterval = 10
    ) async throws -> RankPage {
        var values: [(String, String)] = [
            ("cell_id", cursor.cellId),
            ("offset", String(cursor.offset)),
            ("tab_type", "26"),
            ("change_type", "1"),
            ("session_id", cursor.sessionId),
        ]
        if !selectedItem.isEmpty { values.append(("selected_items", selectedItem)) }
        if !subSelectedItem.isEmpty { values.append(("sub_selected_items", subSelectedItem)) }
        if !panelSelectedItem.isEmpty { values.append(("panel_selected_items", panelSelectedItem)) }

        let payload = try await AppBookMallAccess.tab(
            values: values,
            host: defaultHost,
            path: "/reading/bookapi/bookmall/cell/change/v",
            timeout: timeout
        )
        return try parseRankCellChange(payload, after: cursor)
    }

    // MARK: - Calendar & New Releases Requests

    /// Builds a 10-day calendar window around "today" in Beijing time (past 3 days + today + next 6 days).
    public static func calendarDays(around now: Date = Date()) -> [CalendarDay] {
        var cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
        cal.timeZone = tz
        let startOfToday = cal.startOfDay(for: now)
        let weekdays = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return (-3...6).compactMap { delta -> CalendarDay? in
            guard let date = cal.date(byAdding: .day, value: delta, to: startOfToday) else { return nil }
            let comps = cal.dateComponents([.year, .month, .day, .weekday], from: date)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
            let wd = comps.weekday ?? 1
            let target = String(format: "%04d%02d%02d", y, m, d)
            let md = String(format: "%02d-%02d", m, d)
            let subtitle = delta == 0 ? "今天" : weekdays[max(1, min(7, wd))]
            return CalendarDay(targetDate: target, monthDay: md, subtitle: subtitle, isToday: delta == 0)
        }
    }

    public static func calendar(
        targetDate: String,
        offset: Int = 0,
        sessionId: String = "",
        timeout: TimeInterval = 10
    ) async throws -> CalendarPage {
        var values: [(String, String)] = [
            ("tab_type", "5"),
            ("gender_type", "2"),
            ("offset", String(offset)),
            ("session_id", sessionId),
        ]
        if !targetDate.isEmpty { values.append(("target_date", targetDate)) }
        let payload = try await AppBookMallAccess.tab(
            values: values,
            host: defaultHost,
            path: "/reading/user/subscribe/list/v1/",
            timeout: timeout
        )
        return try parseCalendar(payload)
    }

    public static func newDramaRecommendations(
        gender: NewDramaGender = .all,
        offset: Int = 0,
        sessionId: String = "",
        limit: Int = 30,
        timeout: TimeInterval = 10
    ) async throws -> NewDramaPage {
        let genderArray = gender == .all ? [String]() : [gender.rawValue]
        let bodyObj: [String: Any] = [
            "filter_ids": "",
            "req_scene": "default",
            "offset": offset,
            "need_selector_panel": false,
            "limit": limit,
            "select_items": [
                "genre": [String](),
                "sort": ["hot_score"],
                "category_dim_theme": [String](),
                "category_dim_role": [String](),
                "category_dim_epoch": [String](),
                "gender": genderArray,
                "online_time": ["days_7"],
                "creation_status": [String](),
            ],
            "session_id": sessionId,
            "req_type": offset > 0 ? "only_content" : "default",
            "client_req_type": 3,
        ]
        let data = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])
        let payload = try await AppCatalogueAccess.landpage(body: data, timeout: timeout)
        return try parseNewDramaPage(payload)
    }

    /// Official App category browsing (`/reading/distribution/category/landpage/v/`) for
    /// 真人剧 / 漫剧 / AI剧 (with server-driven `category_dim_theme` filter chips), and
    /// official ranking boards for ranking `CatalogKind` cases.
    public static func catalog(
        kind: CatalogKind,
        genre: String? = nil,
        page: Int = 1,
        limit: Int = 30,
        forceRefresh: Bool = false,
        timeout: TimeInterval = 10
    ) async throws -> CatalogBrowseResult {
        let pg = max(1, page)
        let themeFilter = (genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = "\(kind.rawValue):\(themeFilter):\(pg):\(limit)"
        if !forceRefresh, let cached = await catalogCache.get(cacheKey) { return cached }

        let result: CatalogBrowseResult
        if kind.isRanking {
            let selectedItem: String
            switch kind {
            case .hotDrama: selectedItem = "all"
            case .hotRealDrama: selectedItem = "human"
            case .hotComicDrama: selectedItem = "comic_series_rank"
            case .hotAIDrama: selectedItem = "ai_playlet"
            default: selectedItem = "all"
            }
            let subItem = kind == .hotDrama ? "ranklist_hot_sc" : ""
            let rankPage = try await ranking(selectedItem: selectedItem, subSelectedItem: subItem, timeout: timeout)
            let mapped = rankPage.items.enumerated().map { idx, item in
                SeriesSummary(
                    seriesId: item.seriesId,
                    title: item.title,
                    cover: item.cover,
                    episodeCount: item.episodeCount,
                    tags: item.metaLine.split(separator: "·").map(String.init).filter { !$0.isEmpty },
                    description: item.intro,
                    rank: idx + 1,
                    heat: item.metricTags.first ?? item.recommendText,
                    episodeLabel: item.episodeCount > 0 ? "全\(item.episodeCount)集" : "",
                    completionStatus: .unknown
                )
            }
            result = CatalogBrowseResult(
                items: mapped,
                genres: [],
                hasMore: rankPage.hasMore,
                totalPages: rankPage.hasMore ? max(pg + 1, 2) : pg
            )
        } else {
            let genreKey: String
            let reqScene: String
            switch kind {
            case .realDrama: (genreKey, reqScene) = ("short_play", "default")
            case .comicDrama: (genreKey, reqScene) = ("comic_series", "comic_series")
            case .aiDrama: (genreKey, reqScene) = ("ai_series", "ai_series")
            default: (genreKey, reqScene) = ("short_play", "default")
            }
            let offset = (pg - 1) * limit
            let bodyObj: [String: Any] = [
                "filter_ids": "",
                "req_scene": reqScene,
                "offset": offset,
                "need_selector_panel": pg == 1,
                "limit": limit,
                "select_items": [
                    "genre": [genreKey],
                    "sort": ["hot_score"],
                    "category_dim_theme": themeFilter.isEmpty ? [String]() : [themeFilter],
                    "category_dim_role": [String](),
                    "category_dim_epoch": [String](),
                    "gender": [String](),
                    "online_time": [String](),
                    "creation_status": [String](),
                ],
                "session_id": "",
                "req_type": offset > 0 ? "only_content" : "default",
                "client_req_type": 3,
            ]
            let data = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])
            let payload = try await AppCatalogueAccess.landpage(body: data, timeout: timeout)
            result = try parseCatalogBrowsePage(payload, page: pg)
        }
        await catalogCache.set(cacheKey, result, ttl: 60)
        return result
    }

    // MARK: - Same-IP Series (系列剧)

    /// Fetches the multi-season / same-IP series list (`/reading/bookapi/plan/v/?scene=10&from=single_col_same_ip_series`)
    /// shown under the "系列剧" tab in the player's episode sheet. Returns an empty list for standalone dramas.
    public static func sameIPSeries(seriesId: String, timeout: TimeInterval = 8) async throws -> SameIPSeriesResult {
        guard seriesId.matchesDigits(min: 1, max: 30) else {
            return SameIPSeriesResult(tabTitle: "系列剧", items: [], novel: nil, currentSeasonIndex: 0)
        }
        let payload = try await AppBookMallAccess.tab(
            values: [
                ("scene", "10"),
                ("from", "single_col_same_ip_series"),
                ("book_id", seriesId),
                ("filter_ids", seriesId),
            ],
            host: defaultHost,
            path: "/reading/bookapi/plan/v/",
            timeout: timeout
        )
        return parseSameIPSeries(payload, currentSeriesId: seriesId)
    }

    // MARK: - Search (App API, preserving HEIC/HTTPS covers for iOS)

    /// Official App search (`/reading/bookapi/search/tab/v`) preserving `.heic` cover URLs
    /// (the macOS `AppSearch` parser drops `.heic` covers for AppKit compatibility, which left
    /// iOS search results and detail "相关作品" cards with empty covers).
    public static func search(
        _ keyword: String,
        page: Int = 1,
        timeout: TimeInterval = 10
    ) async throws -> [SeriesSummary] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        let transport = AppTransport(http: .shared)
        let identity = try await AppSearchIdentity.shared.get(transport: transport)
        let signed = try AppLegacySigner.shared.search(
            keyword: kw,
            page: max(1, page),
            cursor: nil,
            identity: identity,
            nowMillis: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let payload = try await transport.requestJSON(signed.url, headers: signed.headers, deadline: deadline)
        return try parseAppSearch(payload)
    }

    static func parseAppSearch(_ payload: JSONValue) throws -> [SeriesSummary] {
        if let code = SearchText.integer(payload["code"]), code != 0 {
            throw HongguoError(.upstream, "App 搜索返回业务错误")
        }
        guard let tabs = payload["search_tabs"].array ?? payload["data"]["search_tabs"].array else {
            throw HongguoError(.format, "App 搜索数据结构异常")
        }
        guard let tab = tabs.first(where: { SearchText.integer($0["tab_type"]) == AppSearchService.searchTab }) else {
            throw HongguoError(.format, "App 搜索暂未返回短剧结果")
        }
        var seen = Set<String>()
        var results: [SeriesSummary] = []
        for cell in tab["data"].array ?? [] {
            guard let video = (cell["video_data"].array ?? []).first(where: { ($0["series_id"].idString ?? "").matchesDigits(min: 1, max: 30) }),
                  let seriesId = video["series_id"].idString else { continue }
            let title = SearchText.clean(cell["search_high_light"]["title"]["text"].string ?? video["title"].string ?? cell["cell_name"].string)
            guard !title.isEmpty, seen.insert(seriesId).inserted else { continue }
            let rawCover = video["cover"].string
                ?? video["series_cover"].string
                ?? video["video_detail"]["series_cover"].string
                ?? ""
            let cover = normalizedCover(rawCover)
            let count = SearchText.integer(video["episode_cnt"]) ?? SearchText.integer(video["episode_count"]) ?? 0
            let subs = video["sub_title_list"].array ?? []
            let rawHeat = AccountService.cleanText(
                subs.first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string
                ?? subs.first(where: { ($0["content"].string ?? "").contains("热度") })?["content"].string
            )
            let heat = (!rawHeat.isEmpty && !rawHeat.contains("热度")) ? "\(rawHeat)热度" : rawHeat
            let tags = subs
                .filter { Int($0["data_type"].number ?? 0) == 3 }
                .compactMap { AccountService.cleanText($0["content"].string) }
                .filter { !$0.isEmpty }
            let desc = SearchText.clean(video["series_intro"].string ?? video["video_desc"].string ?? cell["series_intro"].string)
            results.append(SeriesSummary(
                seriesId: seriesId,
                title: title,
                cover: cover,
                episodeCount: count,
                tags: tags,
                description: desc,
                heat: heat,
                episodeLabel: count > 0 ? "全\(count)集" : ""
            ))
        }
        return results
    }

    // MARK: - Search Suggestions

    public static func searchSuggestions(query: String, timeout: TimeInterval = 5) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let payload = try? await AppBookMallAccess.tab(
            values: [("q", trimmed), ("search_source", "4")],
            host: defaultHost,
            path: "/reading/bookapi/search/suggest/v/",
            timeout: timeout
        ) else { return [] }
        guard (payload["code"].number ?? -1) == 0 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        let rows = payload["data"]["suggest_list"].array
            ?? payload["data"]["word_list"].array
            ?? payload["data"].array
            ?? []
        for row in rows {
            let word = AccountService.cleanText(
                row["content"].string ?? row["word"].string ?? row["query"].string ?? row["text"].string ?? row.string
            )
            guard !word.isEmpty, seen.insert(word).inserted else { continue }
            out.append(word)
            if out.count >= 8 { break }
        }
        return out
    }

    // MARK: - Parsers

    static func parseRankPlan(_ payload: JSONValue) throws -> RankPage {
        guard (payload["code"].number ?? -1) == 0 else {
            throw HongguoError(.upstream, "排行榜暂时不可用")
        }
        guard let cell = payload["data"].array?.first else {
            return RankPage(categories: [], items: [], hasMore: false, cursor: nil)
        }
        let categories = parseRankSelectors(cell["cell_selector"])
        var seen = Set<String>()
        let items = parseRankRows(cell["cell_data"].array ?? [], seen: &seen)
        let hasMore = cell["has_more"].bool == true
        let nextOffset = Int(cell["next_offset"].number ?? 0)
        let cellId = cell["cell_id_str"].string ?? cell["cell_id"].idString ?? ""
        let sessionId = cell["session_id"].string ?? ""
        let cursor: RankCursor? = (hasMore && !cellId.isEmpty && nextOffset > 0)
            ? RankCursor(cellId: cellId, offset: nextOffset, sessionId: sessionId)
            : nil
        return RankPage(categories: categories, items: items, hasMore: cursor != nil, cursor: cursor)
    }

    static func parseRankCellChange(_ payload: JSONValue, after prev: RankCursor) throws -> RankPage {
        guard (payload["code"].number ?? -1) == 0 else {
            throw HongguoError(.upstream, "排行榜翻页暂时不可用")
        }
        let data = payload["data"]
        let rows = data["cell_view"]["cell_data"].array ?? data["cell_data"].array ?? []
        var seen = Set<String>()
        let items = parseRankRows(rows, seen: &seen)
        let hasMore = data["has_more"].bool == true
        let nextOffset = Int(data["next_offset"].number ?? 0)
        let sessionId = (data["session_id"].string ?? "").isEmpty ? prev.sessionId : (data["session_id"].string ?? "")
        let cursor: RankCursor? = (hasMore && nextOffset > prev.offset && !items.isEmpty)
            ? RankCursor(cellId: prev.cellId, offset: nextOffset, sessionId: sessionId)
            : nil
        return RankPage(categories: [], items: items, hasMore: cursor != nil, cursor: cursor)
    }

    private static func parseRankSelectors(_ selector: JSONValue) -> [RankCategoryTab] {
        let outerItems = selector["outer_row"]["items"].array ?? []
        var categories: [RankCategoryTab] = []
        for item in outerItems {
            let id = (item["selector_item_id"].string ?? "").trimmingCharacters(in: .whitespaces)
            let title = AccountService.cleanText(item["show_name"].string)
            // Skip character / actor rank tab (not a playable drama list).
            guard !id.isEmpty, !title.isEmpty, id != "character", !id.contains("celebrity") else { continue }
            var boards: [RankBoardTab] = []
            for sub in item["sub_cell_selector"]["outer_row"]["items"].array ?? [] {
                let subId = (sub["selector_item_id"].string ?? "").trimmingCharacters(in: .whitespaces)
                let subTitle = AccountService.cleanText(sub["show_name"].string)
                guard !subId.isEmpty, !subTitle.isEmpty, !subId.contains("celebrity"), !subId.contains("actor") else { continue }
                var groups: [RankFilterGroup] = []
                for row in sub["panel_selector"]["inner_rows"].array ?? [] {
                    let rowName = AccountService.cleanText(row["row_name"].string)
                    let opts = (row["items"].array ?? []).compactMap { opt -> RankFilterOption? in
                        let optId = (opt["selector_item_id"].string ?? "").trimmingCharacters(in: .whitespaces)
                        let optTitle = AccountService.cleanText(opt["show_name"].string)
                        guard !optTitle.isEmpty else { return nil }
                        return RankFilterOption(id: optId, title: optTitle, isSelected: opt["is_selected"].bool == true)
                    }
                    if !opts.isEmpty {
                        groups.append(RankFilterGroup(title: rowName.isEmpty ? "分类" : rowName, options: opts))
                    }
                }
                boards.append(RankBoardTab(id: subId, title: subTitle, isSelected: sub["is_selected"].bool == true, filterGroups: groups))
            }
            categories.append(RankCategoryTab(id: id, title: title, isSelected: item["is_selected"].bool == true, boards: boards))
        }
        return categories
    }

    private static func parseRankRows(_ rows: [JSONValue], seen: inout Set<String>) -> [RankItem] {
        var items: [RankItem] = []
        for row in rows {
            for video in row["video_data"].array ?? [] {
                let id = (video["series_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
                let title = AccountService.cleanText(video["title"].string ?? video["series_title"].string)
                guard id.matchesDigits(min: 1, max: 30), !title.isEmpty, seen.insert(id).inserted else { continue }
                let rawCover = video["cover"].string ?? video["video_detail"]["series_cover"].string ?? ""
                let cover = normalizedCover(rawCover)
                let epCount = max(0, Int(video["episode_cnt"].number ?? 0))
                let recText = AccountService.cleanText(
                    video["rec_text_item"]["RecommendText"].string ?? video["recommend_text"].string
                )
                let subParts = (video["sub_title_list"].array ?? [])
                    .compactMap { AccountService.cleanText($0["content"].string) }
                    .filter { !$0.isEmpty }
                let metaLine = subParts.joined(separator: "·")
                let intro = AccountService.cleanText(video["video_desc"].string ?? video["video_detail"]["series_intro"].string)
                let metrics = (video["secondary_info_list"].array ?? [])
                    .compactMap { AccountService.cleanText($0["content"].string) }
                    .filter { !$0.isEmpty }
                let badge = AccountService.cleanText(video["tag_info"]["text"].string)
                let subItem = video["subscribe_item"]
                let hasSubItem = subItem.object != nil
                let subItemId = (subItem["item_id"].idString ?? id).trimmingCharacters(in: .whitespaces)
                let playable = video["disable_play"].bool != true && !hasSubItem && epCount > 0
                items.append(RankItem(
                    seriesId: id, title: title, cover: cover, episodeCount: epCount,
                    recommendText: recText, metaLine: metaLine, intro: intro,
                    metricTags: Array(metrics.prefix(2)), badgeText: badge, playable: playable,
                    subscribeItemId: subItemId
                ))
            }
        }
        return items
    }

    static func parseCalendar(_ payload: JSONValue) throws -> CalendarPage {
        guard (payload["code"].number ?? -1) == 0 else {
            throw HongguoError(.upstream, "上新日历暂时不可用")
        }
        let data = payload["data"]
        let rows = data["subscribe_items"].array ?? []
        var seen = Set<String>()
        var items: [CalendarItem] = []
        for row in rows {
            let subData = row["subscribe_data"]
            let subDetail = subData["video_detail"]
            let isOnline = row["is_online"].bool ?? (subData.object != nil)
            let id = (subData["series_id"].idString
                ?? subDetail["series_id_str"].idString
                ?? subDetail["series_id"].idString
                ?? row["series_id"].idString
                ?? row["item_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
            guard id.matchesDigits(min: 1, max: 30), seen.insert(id).inserted else { continue }
            let title = AccountService.cleanText(
                subDetail["series_title"].string ?? subData["title"].string ?? row["name"].string
            )
            guard !title.isEmpty else { continue }
            let rawCover = [
                subDetail["series_cover"].string,
                subData["cover"].string,
                row["cover"].string,
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let cover = normalizedCover(rawCover)
            let heatText: String = {
                if let tag = (row["rec_tags"].array ?? []).first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string {
                    return AccountService.cleanText(tag)
                }
                if let info = (subDetail["secondary_infos"].array ?? []).first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string {
                    return AccountService.cleanText(info)
                }
                let expected = AccountService.cleanText(row["expected_rec_text"].string)
                if !expected.isEmpty { return expected }
                return AccountService.cleanText(row["tag_info"]["text"].string)
            }()
            let cats = (row["categories"].array ?? []).compactMap { AccountService.cleanText($0.string) }.filter { !$0.isEmpty }
            let catLine = cats.isEmpty ? AccountService.cleanText(row["category"].string) : cats.prefix(3).joined(separator: "·")
            let ct = Int(subData["content_type"].number ?? subDetail["content_type"].number ?? 0)
            let epCount = max(0, Int(subData["episode_cnt"].number ?? subDetail["episode_cnt"].number ?? 0))
            let desc = AccountService.cleanText(subDetail["series_intro"].string ?? subData["video_desc"].string ?? row["item_desc"].string)
            items.append(CalendarItem(
                seriesId: id, title: title, cover: cover, isOnline: isOnline,
                heatText: heatText, categoriesLine: catLine,
                categoryLabel: AccountDataAccess.categoryLabel(contentType: ct),
                episodeCount: epCount, description: desc
            ))
        }
        let hasMore = data["has_more"].bool == true && !items.isEmpty
        let nextOffset = Int(data["next_offset"].number ?? 0)
        let sessionId = data["session_id"].string ?? ""
        return CalendarPage(items: items, hasMore: hasMore, nextOffset: nextOffset, sessionId: sessionId)
    }

    static func parseNewDramaPage(_ payload: JSONValue) throws -> NewDramaPage {
        guard (payload["code"].number ?? -1) == 0 else {
            throw HongguoError(.upstream, "新剧推荐暂时不可用")
        }
        let data = payload["data"]
        let rows = data["video_data"].array ?? []
        var seen = Set<String>()
        var items: [NewDramaItem] = []
        for row in rows {
            let id = (row["series_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
            let title = AccountService.cleanText(row["title"].string ?? row["series_title"].string)
            guard id.matchesDigits(min: 1, max: 30), !title.isEmpty, seen.insert(id).inserted else { continue }
            let cover = normalizedCover(row["cover"].string ?? "")
            let epCount = max(0, Int(row["episode_cnt"].number ?? 0))
            let subs = row["sub_title_list"].array ?? []
            let heatText = AccountService.cleanText(
                subs.first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string
                ?? subs.first(where: { ($0["content"].string ?? "").contains("热度") })?["content"].string
            )
            let otherSubs = subs.compactMap { AccountService.cleanText($0["content"].string) }
                .filter { !$0.isEmpty && $0 != heatText && $0 != "新剧" && $0 != "今日上新" }
            let tag = AccountService.cleanText(row["tag_info"]["text"].string)
            let ct = Int(row["content_type"].number ?? 0)
            let catLabel = AccountDataAccess.categoryLabel(contentType: ct)
            let subtitle: String = {
                var parts: [String] = []
                if let firstSub = otherSubs.first { parts.append(firstSub) }
                else if epCount > 0 { parts.append("全\(epCount)集") }
                if !heatText.isEmpty { parts.append("🔥\(heatText)") }
                return parts.joined(separator: "·")
            }()
            let desc = AccountService.cleanText(row["video_desc"].string ?? row["series_intro"].string)
            items.append(NewDramaItem(
                seriesId: id, title: title, cover: cover, episodeCount: epCount,
                heatText: heatText, badgeText: tag, categoryLabel: catLabel,
                subtitle: subtitle, description: desc
            ))
        }
        let hasMore = data["has_more"].bool == true && !items.isEmpty
        let nextOffset = Int(data["next_offset"].number ?? 0)
        let sessionId = data["session_id"].string ?? ""
        return NewDramaPage(items: items, hasMore: hasMore, nextOffset: nextOffset, sessionId: sessionId)
    }

    static func parseCatalogBrowsePage(_ payload: JSONValue, page: Int) throws -> CatalogBrowseResult {
        guard (payload["code"].number ?? -1) == 0 else {
            throw HongguoError(.upstream, "剧场分类暂时不可用")
        }
        let data = payload["data"]

        var genres: [Genre] = []
        var seenGenres = Set<String>()
        for row in data["selector_rows"].array ?? [] where row["type"].string == "category_dim_theme" {
            for item in row["items"].array ?? [] {
                let slug = (item["selector_item_id"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let label = AccountService.cleanText(item["show_name"].string)
                guard !slug.isEmpty, !label.isEmpty, seenGenres.insert(slug).inserted else { continue }
                genres.append(Genre(slug: slug, label: label))
            }
        }

        var items: [SeriesSummary] = []
        var seen = Set<String>()
        for row in data["video_data"].array ?? [] {
            let id = (row["series_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
            let title = AccountService.cleanText(row["title"].string ?? row["series_title"].string)
            guard id.matchesDigits(min: 1, max: 30), !title.isEmpty, seen.insert(id).inserted else { continue }
            let cover = normalizedCover(row["cover"].string ?? "")
            let epCount = max(0, Int(row["episode_cnt"].number ?? 0))
            let subs = row["sub_title_list"].array ?? []
            let rawHeat = AccountService.cleanText(
                subs.first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string
                ?? subs.first(where: { ($0["content"].string ?? "").contains("热度") })?["content"].string
            )
            let heat = (!rawHeat.isEmpty && !rawHeat.contains("热度")) ? "\(rawHeat)热度" : rawHeat
            var tags = subs
                .filter { Int($0["data_type"].number ?? 0) == 3 }
                .compactMap { AccountService.cleanText($0["content"].string) }
                .filter { !$0.isEmpty }
            if tags.isEmpty {
                let badge = AccountService.cleanText(row["tag_info"]["text"].string)
                if !badge.isEmpty { tags = [badge] }
            }
            let desc = AccountService.cleanText(row["video_desc"].string ?? row["series_intro"].string)
            let statusVal = Int(row["series_status"].number ?? -1)
            let completion: CompletionStatus = statusVal == 1 ? .completed : .unknown
            items.append(SeriesSummary(
                seriesId: id,
                title: title,
                cover: cover,
                episodeCount: epCount,
                tags: tags,
                description: desc,
                heat: heat,
                episodeLabel: epCount > 0 ? "全\(epCount)集" : "",
                completionStatus: completion
            ))
        }
        let hasMore = data["has_more"].bool == true && !items.isEmpty
        return CatalogBrowseResult(
            items: items,
            genres: genres,
            hasMore: hasMore,
            totalPages: hasMore ? max(page + 1, 2) : max(1, page)
        )
    }

    static func parseSameIPSeries(_ payload: JSONValue, currentSeriesId: String) -> SameIPSeriesResult {
        guard (payload["code"].number ?? -1) == 0 else {
            return SameIPSeriesResult(tabTitle: "系列剧", items: [], novel: nil, currentSeasonIndex: 0)
        }
        var cells: [JSONValue] = []
        func collectCells(_ node: JSONValue) {
            if let arr = node.array {
                for item in arr { collectCells(item) }
                return
            }
            guard node.object != nil else { return }
            if node["video_data"].array != nil || node["book_data"].array != nil {
                cells.append(node)
            }
            for tab in node["tab_item"].array ?? [] { collectCells(tab) }
            for sub in node["cell_data"].array ?? [] { collectCells(sub) }
        }
        collectCells(payload["data"])

        var tabTitle = "系列剧"
        var items: [RelatedSeriesItem] = []
        var seen = Set<String>()
        var novel: RelatedNovelInfo?

        for cell in cells {
            let name = AccountService.cleanText(cell["cell_name"].string)
            if !name.isEmpty, tabTitle == "系列剧" { tabTitle = name }
            if novel == nil, let b = cell["book_data"].array?.first {
                let bName = AccountService.cleanText(b["book_name"].string)
                if !bName.isEmpty {
                    novel = RelatedNovelInfo(
                        bookId: (b["book_id"].idString ?? "").trimmingCharacters(in: .whitespaces),
                        bookName: bName,
                        author: AccountService.cleanText(b["author"].string)
                    )
                }
            }
            for row in cell["video_data"].array ?? [] {
                let id = (row["series_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
                let title = AccountService.cleanText(row["title"].string ?? row["series_title"].string)
                guard id.matchesDigits(min: 1, max: 30), !title.isEmpty, seen.insert(id).inserted else { continue }
                let cover = normalizedCover(row["cover"].string ?? row["series_cover"].string ?? "")
                let season = max(0, Int(row["season_index"].number ?? 0))
                let epCount = max(0, Int(row["episode_cnt"].number ?? 0))
                let subs = row["sub_title_list"].array ?? []
                let subItem = row["subscribe_item"]
                let hasSubItem = subItem.object != nil
                let vid = (row["vid"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let disablePlay = row["disable_play"].bool == true || hasSubItem || (epCount == 0 && vid.isEmpty)
                let subscribeItemId = (subItem["item_id"].idString ?? id).trimmingCharacters(in: .whitespaces)

                let heatText = AccountService.cleanText(
                    subs.first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string
                    ?? subs.first(where: { ($0["content"].string ?? "").contains("热度") })?["content"].string
                )
                let secList = row["secondary_info_list"].array ?? []
                let secSeason = secList
                    .compactMap { AccountService.cleanText($0["content"].string) }
                    .first { $0.hasPrefix("第") && $0.hasSuffix("季") } ?? ""
                let seasonLabel = !secSeason.isEmpty ? secSeason : (season > 0 ? "第\(season)季" : "")
                let badgeText: String = {
                    if let hi = secList.first(where: { $0["highlight"].bool == true })?["content"].string {
                        let cleaned = AccountService.cleanText(hi)
                        if !cleaned.isEmpty, cleaned != seasonLabel { return cleaned }
                    }
                    return AccountService.cleanText(row["tag_info"]["text"].string)
                }()

                var parts: [String] = []
                if !seasonLabel.isEmpty { parts.append(seasonLabel) }
                if disablePlay {
                    let subSource = subs.isEmpty ? (subItem["sub_title_list"].array ?? []) : subs
                    let reserveParts = subSource
                        .compactMap { AccountService.cleanText($0["content"].string) }
                        .filter { !$0.isEmpty }
                    if !reserveParts.isEmpty {
                        parts.append(contentsOf: reserveParts.prefix(2))
                    } else {
                        parts.append("待上线")
                    }
                } else if !heatText.isEmpty {
                    parts.append(heatText)
                } else if epCount > 0 {
                    parts.append("全\(epCount)集")
                }
                let ct = Int(row["content_type"].number ?? 0)
                let desc = AccountService.cleanText(row["video_desc"].string ?? row["series_intro"].string)
                items.append(RelatedSeriesItem(
                    seriesId: id, title: title, cover: cover, seasonIndex: season,
                    episodeCount: epCount, heatText: heatText,
                    subtitle: parts.joined(separator: " · "),
                    disablePlay: disablePlay,
                    categoryLabel: AccountDataAccess.categoryLabel(contentType: ct),
                    description: desc,
                    subscribeItemId: subscribeItemId,
                    badgeText: badgeText
                ))
            }
        }
        guard items.count > 1 else {
            return SameIPSeriesResult(tabTitle: tabTitle, items: [], novel: novel, currentSeasonIndex: 0)
        }
        let currentSeason = items.first(where: { $0.seriesId == currentSeriesId })?.seasonIndex ?? 0
        return SameIPSeriesResult(tabTitle: tabTitle, items: items, novel: novel, currentSeasonIndex: currentSeason)
    }

    private static func normalizedCover(_ raw: String) -> String {
        let cleaned = AccountService.cleanCover(raw)
        if !cleaned.isEmpty { return cleaned }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("//") { text = "https:" + text }
        else if text.lowercased().hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        guard text.lowercased().hasPrefix("https://"), URL(string: text) != nil else { return "" }
        return text
    }
}

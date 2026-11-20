import Foundation

public enum CatalogKind: String, CaseIterable, Identifiable, Sendable {
    case realDrama = "real-drama"
    case comicDrama = "comic-drama"
    case aiDrama = "ai-drama"
    case hotDrama = "hot-drama"
    case hotRealDrama = "hot-real-drama"
    case hotComicDrama = "hot-comic-drama"
    case hotAIDrama = "hot-ai-drama"

    public var id: String { rawValue }
    public var isRanking: Bool { rawValue.hasPrefix("hot-") }

    public var label: String {
        switch self {
        case .realDrama: return "真人剧"
        case .comicDrama: return "漫剧"
        case .aiDrama: return "AI 剧"
        case .hotDrama: return "热播总榜"
        case .hotRealDrama: return "真人剧榜"
        case .hotComicDrama: return "漫剧榜"
        case .hotAIDrama: return "AI 剧榜"
        }
    }

    public static var categories: [CatalogKind] { [.realDrama, .comicDrama, .aiDrama] }
    public static var rankings: [CatalogKind] { [.hotDrama, .hotRealDrama, .hotComicDrama, .hotAIDrama] }
}

/// Category and ranking lists from the App (`DiscoveryAccess`). No website pages.
public final class CatalogService: Sendable {
    private let rankPages = TTLCache<CatalogPage>(limit: 64)
    private let rankCursors = TTLCache<DiscoveryAccess.RankCursor>(limit: 64)
    private let rankOffsets = TTLCache<Int>(limit: 64)

    public init(http: HTTPClient = .shared) {}

    /// The website page of a list, for "open the source page" links only.
    public static func url(kind: CatalogKind, genre: String?, page: Int) -> URL {
        let pg = max(1, page)
        var path = "\(Site.origin)/\(kind.isRanking ? "rank" : "category")/\(kind.rawValue)"
        if let genre, !genre.isEmpty, !kind.isRanking { path += "/\(genre)" }
        if pg > 1 { path += "?page=\(pg)" }
        return URL(string: path)!
    }

    /// One page of a category (with the App's theme ids, `cate_5000`) or a ranking board.
    public func browse(kind: CatalogKind, genre: String? = nil, page: Int = 1, forceRefresh: Bool = false) async throws -> CatalogPage {
        let theme = (genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if kind.isRanking {
            if let board = try await appRanking(kind: kind, page: page, forceRefresh: forceRefresh) { return board }
            // Page 1 empty is a failure; a later page without a cursor is the end of the board.
            guard page > 1 else { throw HongguoError(.upstream, "App 榜单暂无内容，请稍后重试") }
            return CatalogPage(results: [], page: page, total: 0, totalPages: page - 1, genres: [], pageTitle: kind.label,
                               sourceURL: Self.url(kind: kind, genre: nil, page: page))
        }
        let app = try await DiscoveryAccess.catalog(kind: kind, genre: theme.isEmpty ? nil : theme, page: page, forceRefresh: forceRefresh)
        return CatalogPage(results: app.items, page: max(1, page), total: app.items.count, totalPages: app.totalPages,
                           genres: app.genres, pageTitle: kind.label, sourceURL: Self.url(kind: kind, genre: nil, page: page))
    }

    /// App ranking board pages. Page 1 opens the board; later pages continue from the cursor the
    /// previous page left, so pages must be read in order (the list view does). nil when the
    /// board did not answer or a later page has no cursor to continue from.
    private func appRanking(kind: CatalogKind, page: Int, forceRefresh: Bool) async throws -> CatalogPage? {
        let pg = max(1, page)
        let selected: String
        switch kind {
        case .hotRealDrama: selected = "human"
        case .hotComicDrama: selected = "comic_series_rank"
        case .hotAIDrama: selected = "ai_playlet"
        default: selected = "all"
        }
        let sub = kind == .hotDrama ? "ranklist_hot_sc" : ""
        let pageKey = "\(kind.rawValue):\(pg)"
        if !forceRefresh, let cached = await rankPages.get(pageKey) { return cached }
        let board: DiscoveryAccess.RankPage
        if pg == 1 {
            board = try await DiscoveryAccess.ranking(selectedItem: selected, subSelectedItem: sub)
        } else {
            guard let cursor = await rankCursors.get(pageKey) else { return nil }
            board = try await DiscoveryAccess.rankingMore(cursor: cursor, selectedItem: selected, subSelectedItem: sub)
        }
        guard !board.items.isEmpty else { return nil }
        let first = await rankOffsets.get("\(kind.rawValue):\(pg)") ?? 0
        let results = board.items.enumerated().map { index, item in
            SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover, episodeCount: item.episodeCount,
                          tags: item.metaLine.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                          description: item.intro, rank: first + index + 1,
                          heat: item.metricTags.first ?? item.recommendText,
                          episodeLabel: item.episodeCount > 0 ? "全\(item.episodeCount)集" : "", completionStatus: .unknown)
        }
        let more = board.hasMore && board.cursor != nil
        if more, let cursor = board.cursor {
            await rankCursors.set("\(kind.rawValue):\(pg + 1)", cursor, ttl: 600)
            await rankOffsets.set("\(kind.rawValue):\(pg + 1)", first + results.count, ttl: 600)
        }
        let result = CatalogPage(results: results, page: pg, total: first + results.count, totalPages: more ? pg + 1 : pg,
                                 genres: [], pageTitle: kind.label, sourceURL: Self.url(kind: kind, genre: nil, page: pg))
        await rankPages.set(pageKey, result, ttl: 120)
        return result
    }

    static func metadata(_ item: JSONValue) -> (label: String, status: CompletionStatus, published: Date?) {
        let label = String((item["episode_right_text"].string ?? "").trimmingCharacters(in: .whitespaces).prefix(80))
        let status: CompletionStatus
        if label.range(of: "^(?:全\\s*\\d+\\s*集|已完结|完结)$", options: .regularExpression) != nil { status = .completed }
        else if label.range(of: "连载|更新至\\s*\\d+\\s*集", options: .regularExpression) != nil { status = .ongoing }
        else { status = .unknown }
        var published: Date?
        if let raw = item["first_visible_time"].number, raw > 0 {
            let ms = raw < 1e12 ? raw * 1000 : raw
            let date = Date(timeIntervalSince1970: ms / 1000)
            if date <= Date() { published = date }
        }
        return (label, status, published)
    }
}

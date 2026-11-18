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

/// Category and ranking pages from the official site. Port of `catalog.js`.
public final class CatalogService: Sendable {
    private let http: HTTPClient
    private let cache = TTLCache<CatalogPage>(limit: 32)

    public init(http: HTTPClient = .shared) { self.http = http }

    public static func url(kind: CatalogKind, genre: String?, page: Int) -> URL {
        let pg = max(1, page)
        var path = "\(Site.origin)/\(kind.isRanking ? "rank" : "category")/\(kind.rawValue)"
        if let genre, !genre.isEmpty, !kind.isRanking { path += "/\(genre)" }
        if pg > 1 { path += "?page=\(pg)" }
        return URL(string: path)!
    }

    public func browse(kind: CatalogKind, genre: String? = nil, page: Int = 1, forceRefresh: Bool = false) async throws -> CatalogPage {
        if let genre, !genre.isEmpty {
            guard !kind.isRanking, genre.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
                throw HongguoError(.input, "无效的目录分类或题材")
            }
        }
        let url = Self.url(kind: kind, genre: genre, page: page)
        if !forceRefresh, let cached = await cache.get(url.absoluteString) { return cached }
        var options = HTTPClient.Options()
        options.timeout = 10
        options.headers = ["User-Agent": UserAgents.web, "Accept-Language": "zh-CN,zh;q=0.9", "Cache-Control": "no-cache"]
        let response: HTTPResponse
        do {
            response = try await http.get(url, options: options)
        } catch let error as HTTPStatusError {
            throw HongguoError(.upstream, "目录请求失败（HTTP \(error.status)）")
        } catch let error as HongguoError where error.kind == .timeout {
            throw HongguoError(.timeout, "目录加载超时，请重试")
        }
        let parsed = kind.isRanking
            ? try Self.parseRanking(response.text, kind: kind, page: page, sourceURL: url)
            : try Self.parseCatalog(response.text, kind: kind, page: page, sourceURL: url)
        await cache.set(url.absoluteString, parsed, ttl: 120)
        return parsed
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

    public static func parseCatalog(_ html: String, kind: CatalogKind, page: Int, sourceURL: URL) throws -> CatalogPage {
        let router = try HTMLData.routerData(html)
        let loader = router["loaderData"].object ?? [:]
        guard let data = loader.values.first(where: { $0["categoryRoute"]["contentType"].string == kind.rawValue }),
              data["isSuccess"].bool != false, let list = data["recommendList"].array else {
            throw HongguoError(.upstream, "来源目录暂不可用，请重试或打开来源页面")
        }
        var seen = Set<String>()
        var results: [SeriesSummary] = []
        for item in list {
            guard let id = item["series_id"].idString, id.isDigitsOnly, id.count >= 6,
                  let name = item["series_name"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  !seen.contains(id) else { continue }
            seen.insert(id)
            let meta = metadata(item)
            results.append(SeriesSummary(
                seriesId: id, title: name, cover: HTMLData.safeCover(item["series_cover"].string),
                episodeCount: Int(item["episode_cnt"].number ?? 0),
                tags: Array((item["tags"].array ?? []).compactMap(\.string).prefix(4)),
                description: item["series_intro"].string ?? "",
                episodeLabel: meta.label, completionStatus: meta.status, publishedAt: meta.published))
        }
        let genres = (data["selectorList"].array ?? []).flatMap { $0["items"].array ?? [] }.compactMap { item -> Genre? in
            guard let slug = item["selector_item_id"].string, slug.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil,
                  let label = item["show_name"].string else { return nil }
            return Genre(slug: slug, label: label)
        }
        return CatalogPage(results: results,
                           page: Int(data["pagination"]["pageNum"].number ?? Double(page)),
                           total: Int(data["pagination"]["total"].number ?? 0),
                           totalPages: Int(data["pagination"]["totalPages"].number ?? 0),
                           genres: genres, pageTitle: data["seo"]["title"].string ?? "", sourceURL: sourceURL)
    }

    public static func parseRanking(_ html: String, kind: CatalogKind, page: Int, sourceURL: URL) throws -> CatalogPage {
        var data: JSONValue = .null
        // Streaming SSR puts the payload inside an HTML-encoded JSON attribute.
        for tag in HTMLData.allMatches("<script\\b([^>]*)>", in: html) {
            let attributes = tag[1]
            guard attributes.range(of: "data-fn-name=[\"']mergeLoaderData[\"']", options: .regularExpression) != nil,
                  let encoded = HTMLData.firstMatch("data-fn-args=(?:\"([^\"]*)\"|'([^']*)')", in: attributes) else { continue }
            let raw = encoded[1].isEmpty ? encoded[2] : encoded[1]
            guard let args = try? JSONValue.parse(HTMLData.decodeEntities(raw)),
                  args[0].string == "rank_\(kind.rawValue)/page", let parts = args[1].array,
                  let content = parts.first(where: { $0["key"].string == "content" && $0["routerDataFnName"].string == "p" }),
                  let payload = content["routerDataFnArgs"][0].string,
                  let parsed = try? JSONValue.parse(payload) else { continue }
            data = parsed
        }
        var seen = Set<String>()
        func normalize(id: String, title: String, rank: Int?, cover: String, episodes: Int, tags: [String], heat: String, item: JSONValue) -> SeriesSummary? {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.isDigitsOnly, id.count >= 6, !title.isEmpty, let rank, rank >= 1, !seen.contains(id) else { return nil }
            seen.insert(id)
            let meta = metadata(item)
            return SeriesSummary(seriesId: id, title: title, cover: HTMLData.safeCover(cover), episodeCount: episodes,
                                 tags: Array(tags.prefix(4)), rank: rank, heat: heat.trimmingCharacters(in: .whitespaces),
                                 episodeLabel: meta.label, completionStatus: meta.status, publishedAt: meta.published)
        }
        var results: [SeriesSummary] = []
        if data["isSuccess"].bool != false, let list = data["rankList"].array {
            for item in list {
                if let summary = normalize(id: item["seriesId"].idString ?? "", title: item["title"].string ?? "",
                                           rank: item["rank"].number.map { Int($0) }, cover: item["cover"].string ?? "",
                                           episodes: item["episodeVids"].array?.count ?? 0,
                                           tags: (item["tags"].array ?? []).compactMap(\.string),
                                           heat: item["heatText"].string ?? "", item: item) {
                    results.append(summary)
                }
            }
        }
        if results.isEmpty {
            // Fallback: semantic headings and detail links in the rendered cards.
            for article in HTMLData.allMatches("<article\\b[^>]*>([\\s\\S]*?)</article>", in: html) {
                let body = article[1]
                guard let heading = HTMLData.firstMatch("<h2\\b[^>]*\\bid=[\"']rank-title-(\\d+)[\"'][^>]*>([\\s\\S]*?)</h2>", in: body),
                      body.contains("/detail?series_id=\(heading[1])") else { continue }
                let cover = HTMLData.firstMatch("<img\\b[^>]*\\bsrc=(?:\"([^\"]*)\"|'([^']*)')", in: body)
                let coverURL = cover.map { HTMLData.decodeEntities($0[1].isEmpty ? $0[2] : $0[1]) } ?? ""
                let tagBlock = HTMLData.firstMatch("<p\\b[^>]*class=[\"'][^\"']*pc-categories-[^\"']*[\"'][^>]*>([\\s\\S]*?)</p>", in: body)?[1] ?? ""
                let tags = HTMLData.allMatches("<span\\b[^>]*>([\\s\\S]*?)</span>", in: tagBlock).map { HTMLData.stripTags($0[1]) }
                let rank = HTMLData.firstMatch("<span\\b[^>]*>\\s*(\\d+)\\s*</span>", in: body).flatMap { Int($0[1]) }
                let heat = HTMLData.firstMatch("[\\d.,]+\\s*[万亿]?\\s*热度", in: HTMLData.stripTags(body))?[0] ?? ""
                if let summary = normalize(id: heading[1], title: HTMLData.stripTags(heading[2]), rank: rank, cover: coverURL,
                                           episodes: 0, tags: tags, heat: heat, item: .null) {
                    results.append(summary)
                }
            }
        }
        guard !results.isEmpty else { throw HongguoError(.upstream, "来源榜单暂不可用，请重试或打开来源页面") }
        let title = HTMLData.firstMatch("<title\\b[^>]*>([\\s\\S]*?)</title>", in: html).map { HTMLData.stripTags($0[1]) } ?? ""
        let current = Int(data["pagination"]["pageNum"].number ?? Double(page))
        let totalPages = Int(data["pagination"]["totalPages"].number ?? Double(current))
        return CatalogPage(results: results, page: current, total: 0, totalPages: max(totalPages, current),
                           genres: [], pageTitle: title, sourceURL: sourceURL)
    }
}

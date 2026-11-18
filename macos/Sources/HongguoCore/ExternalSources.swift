// SPDX-License-Identifier: GPL-3.0-only
// The non-Hongguo catalogues of the Electron app: 西饭 (src/native/xifan.js) and 河马
// (src/native/hema.js), plus the source switch of src/native/media-sources.js. Series ids are
// prefixed (`xifan:<source>:<id>`, `hema:<bookId>`) so they never collide with Hongguo ids, and
// an episode's lock state is read again before every play, never reused from a cached list.
import Foundation

/// A catalogue other than Hongguo: browse by genre, search, episodes and a playable URL.
public protocol MediaSource: Sendable {
    var id: String { get }
    var label: String { get }
    func browse(genre: String?, page: Int) async throws -> SourcePage
    func search(_ keyword: String, page: Int) async throws -> SourcePage
    func episodes(seriesId: String) async throws -> SeriesEpisodes
    /// Throws `.previewOnly` with the source's message when the episode is locked.
    func playInfo(vid: String, seriesId: String?) async throws -> PlayInfo
}

public struct SourcePage: Sendable {
    public var results: [SeriesSummary]
    public var page: Int
    public var hasMore: Bool
    public var genres: [Genre]
    public var total: Int = 0
}

public enum MediaSources {
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var label: String
        public var optIn: Bool
        public var custom = false
    }
    public static let builtin: [Entry] = [
        Entry(id: "hongguo", label: "红果", optIn: false), Entry(id: "xifan", label: "西饭", optIn: false),
        Entry(id: "hema", label: "河马", optIn: false),
        Entry(id: "reelshort", label: "ReelShort（海外）", optIn: true), Entry(id: "dramabox", label: "DramaBox（海外）", optIn: true),
    ]

    /// Sources shown in the switcher: Hongguo always, 西饭/河马 unless turned off, overseas ones only when turned on.
    public static func enabled(_ switches: [String: Bool], custom: [CustomSourceConfig] = []) -> [Entry] {
        builtin.filter { entry in
            entry.id == "hongguo" || (entry.optIn ? switches[entry.id] == true : switches[entry.id] != false)
        } + custom.filter(\.enabled).map { Entry(id: "custom:\($0.id)", label: $0.name, optIn: false, custom: true) }
    }

    /// One instance per built-in source so genre caches survive between calls.
    static let shared = (xifan: XifanSource(), hema: HemaSource(), reelshort: ReelShortSource(), dramabox: DramaBoxSource())

    /// The catalogue behind a source or series id under the current settings; nil for Hongguo
    /// (which has its own services). Throws when the source is turned off or deleted.
    public static func source(for id: String, settings: @escaping @Sendable () -> AppSettings) throws -> MediaSource? {
        let kind = sourceId(of: id)
        let current = settings()
        switch kind {
        case "hongguo": return nil
        case "xifan", "hema", "reelshort", "dramabox":
            guard enabled(current.builtinSources).contains(where: { $0.id == kind }) else {
                throw HongguoError(.unavailable, "此来源已关闭，可在设置中重新开启")
            }
            switch kind {
            case "xifan": return shared.xifan
            case "hema": return shared.hema
            case "reelshort": return shared.reelshort
            default: return shared.dramabox
            }
        default:
            let uuid = try CustomSource.sourceId(id)
            guard let config = current.customSources.first(where: { $0.id == uuid && $0.enabled }) else {
                throw HongguoError(.unavailable, "该自定义源已禁用或删除")
            }
            return CustomSource(config: config, current: { uuid in settings().customSources.first { $0.id == uuid } })
        }
    }

    /// Which source a series or episode id belongs to.
    public static func sourceId(of id: String) -> String {
        if id.hasPrefix("xifan:") { return "xifan" }
        if id.hasPrefix("hema:") { return "hema" }
        if id.hasPrefix("reelshort:") { return "reelshort" }
        if id.hasPrefix("dramabox:") { return "dramabox" }
        if id.hasPrefix("custom:") { return "custom" }
        return "hongguo"
    }

    static func plainText(_ value: String?) -> String {
        (value ?? "").replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTTPS, no credentials, public host (`httpsUrl` + `isPublicMediaUrl`).
    static func httpsURL(_ value: String?) -> String {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              URLGuard.isPublicURL(url) else { return "" }
        return url.absoluteString
    }

    static func locked(_ message: String) -> HongguoError { HongguoError(.previewOnly, message) }
}

// MARK: - 西饭

public final class XifanSource: MediaSource {
    public let id = "xifan"
    public let label = "西饭"
    static let api = "https://xifan-api-cn.youlishipin.com"
    static let idPattern = "^[a-zA-Z0-9_-]{1,200}$"

    public typealias Fetch = @Sendable (_ url: URL) async throws -> Data
    private let fetch: Fetch
    private let genreCache = TTLCache<[XifanGenre]>(limit: 1)

    struct XifanGenre: Sendable { var slug: String; var label: String; var categoryId: Int; var version: Int }

    public init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? { url in
            var options = HTTPClient.Options()
            options.headers = ["User-Agent": "Mozilla/5.0", "Accept": "application/json"]
            options.timeout = 10
            options.maxRedirects = 0
            return try await HTTPClient.shared.get(url, options: options).data
        }
    }

    static func valid(_ part: String) -> Bool { part.range(of: idPattern, options: .regularExpression) != nil }

    static func parseId(_ value: String, episode: Bool = false) throws -> (source: String, duanjuId: String, episodeId: String?, seriesId: String) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "xifan", parts.count == (episode ? 4 : 3), parts.dropFirst().allSatisfy(valid) else {
            throw HongguoError(.input, "西饭剧集编号无效")
        }
        return (parts[1], parts[2], episode ? parts[3] : nil, parts[0..<3].joined(separator: ":"))
    }

    func request(_ path: String, _ params: [(String, String)]) async throws -> JSONValue {
        var components = URLComponents(string: Self.api + path)!
        components.queryItems = (params + [("version", "2001001"), ("androidVersionCode", "28")]).map { URLQueryItem(name: $0.0, value: $0.1) }
        let data: Data
        do { data = try await fetch(components.url!) } catch let error as HongguoError where error.kind == .timeout {
            throw HongguoError(.timeout, "西饭加载超时，请重试")
        } catch { throw HongguoError(.unavailable, "西饭来源暂不可用，请稍后重试") }
        guard let payload = try? JSONValue.parse(data), payload["ret"] == .int(0), payload["result"].object != nil else {
            throw HongguoError(.unavailable, "西饭来源暂不可用，请稍后重试")
        }
        return payload["result"]
    }

    static func contents(_ result: JSONValue) -> [JSONValue] {
        (result["elements"].array ?? []).flatMap { $0["contents"].array ?? [] }
    }

    func genres(force: Bool = false) async throws -> [XifanGenre] {
        if !force, let cached = await genreCache.get("genres") { return cached }
        let result = try await request("/xifan/drama/portalPage", [("reqType", "duanjuCategory")])
        var seen = Set<String>()
        let items = Self.contents(result).flatMap { item -> [JSONValue] in
            let category = item["categoryItemVo"]
            guard category.object != nil else { return [] }
            return category["subCategories"].array ?? [category]
        }.compactMap { item -> XifanGenre? in
            guard case .int(let raw) = item["categoryId"], raw > 0, let id = Int(exactly: raw) else { return nil }
            let label = MediaSources.plainText(item["oppoCategory"].string)
            guard !label.isEmpty else { return nil }
            let slug = "\(id)-\(AppCrypto.hex(Array((item["oppoCategory"].string ?? "").utf8)))"
            return XifanGenre(slug: slug, label: label, categoryId: id, version: item["version"].number.map(Int.init) ?? 1)
        }.filter { seen.insert($0.slug).inserted }
        guard !items.isEmpty else { throw HongguoError(.upstream, "西饭没有返回可用分类，请重试") }
        await genreCache.set("genres", items, ttl: 300)
        return items
    }

    static func normalize(_ result: JSONValue, page: Int, genres: [Genre] = []) -> SourcePage {
        var seen = Set<String>()
        let results = contents(result).map { $0["duanjuVo"] }.compactMap { item -> SeriesSummary? in
            guard let source = item["source"].idString, let duanju = item["duanjuId"].idString, valid(source), valid(duanju) else { return nil }
            let title = MediaSources.plainText(item["title"].string)
            guard !title.isEmpty, seen.insert("\(source):\(duanju)").inserted else { return nil }
            return SeriesSummary(seriesId: "xifan:\(source):\(duanju)", title: title, cover: MediaSources.httpsURL(item["coverImageUrl"].string),
                                 episodeCount: item["total"].number.map(Int.init) ?? 0,
                                 tags: Array((item["categories"].array ?? []).map { MediaSources.plainText($0.string) }.filter { !$0.isEmpty }.prefix(4)))
        }
        return SourcePage(results: results, page: page, hasMore: result["hasMore"].bool == true && !results.isEmpty, genres: genres)
    }

    public func browse(genre: String?, page: Int) async throws -> SourcePage {
        let page = max(1, page)
        let items = try await genres()
        guard let selected = genre.flatMap({ slug in items.first { $0.slug == slug } }) ?? (genre == nil ? items.first { $0.label == "都市" } ?? items.first : nil) else {
            throw HongguoError(.input, "西饭题材无效，请重新选择")
        }
        let result = try await request("/xifan/drama/portalPage", [
            ("reqType", "aggregationPage"), ("offset", String((page - 1) * 30)), ("categoryId", String(selected.categoryId)),
            ("categoryNames", selected.label), ("categoryVersion", String(selected.version)),
        ])
        return Self.normalize(result, page: page, genres: items.map { Genre(slug: $0.slug, label: $0.label) })
    }

    public func search(_ keyword: String, page: Int) async throws -> SourcePage {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { throw HongguoError(.input, "请输入搜索关键词") }
        let page = max(1, page)
        return Self.normalize(try await request("/xifan/search/getSearchList", [("keyword", kw), ("pageIndex", String(page))]), page: page)
    }

    func detail(_ seriesId: String) async throws -> JSONValue {
        let id = try Self.parseId(seriesId)
        let result = try await request("/xifan/drama/getDuanjuInfo", [("source", id.source), ("duanjuId", id.duanjuId)])
        guard result["source"].string == id.source, result["duanjuId"].idString == id.duanjuId, result["episodeList"].array != nil else {
            throw HongguoError(.format, "西饭返回的剧集与请求不一致")
        }
        return result
    }

    /// Verified upstream title conflicts only; a title that merely looks wrong is kept.
    static let verifiedTitleConflicts: [String: Set<String>] = ["xifan:jiuzhou:253\u{0}天龙战神": ["爱归良辰"]]

    static func episodeTitle(seriesId: String, seriesTitle: String, title: String) -> String {
        verifiedTitleConflicts["\(seriesId)\u{0}\(seriesTitle)"]?.contains(title) == true ? "" : title
    }

    static func episodes(_ result: JSONValue, seriesId: String) throws -> SeriesEpisodes {
        let title = MediaSources.plainText(result["title"].string).isEmpty ? "未命名短剧" : MediaSources.plainText(result["title"].string)
        let episodes = (result["episodeList"].array ?? []).compactMap { item -> Episode? in
            guard let episodeId = item["episodeId"].idString, valid(episodeId) else { return nil }
            return Episode(vid: "\(seriesId):\(episodeId)", index: item["index"].number.map(Int.init) ?? 0,
                           title: episodeTitle(seriesId: seriesId, seriesTitle: title, title: MediaSources.plainText(item["title"].string)),
                           seriesId: seriesId, webAvailable: item["unlock"].bool == true, locked: item["unlock"].bool != true)
        }.sorted { $0.index < $1.index }
        guard !episodes.isEmpty else { throw HongguoError(.upstream, "西饭分集列表为空") }
        return SeriesEpisodes(seriesId: seriesId, title: title, cover: MediaSources.httpsURL(result["coverImageUrl"].string),
                              episodes: episodes, webAccessibleEpisodes: episodes.filter { $0.locked != true }.count, source: .api)
    }

    public func episodes(seriesId: String) async throws -> SeriesEpisodes {
        try Self.episodes(try await detail(seriesId), seriesId: seriesId)
    }

    public func playInfo(vid: String, seriesId: String?) async throws -> PlayInfo {
        let id = try Self.parseId(vid, episode: true)
        if let seriesId, !seriesId.isEmpty, seriesId != id.seriesId { throw HongguoError(.input, "西饭分集不属于当前剧集") }
        // Always re-read the access state.
        let result = try await detail(id.seriesId)
        guard let episode = (result["episodeList"].array ?? []).first(where: { $0["episodeId"].idString == id.episodeId }) else {
            throw HongguoError(.upstream, "西饭未找到该分集")
        }
        guard episode["unlock"].bool == true else {
            throw MediaSources.locked("第 \(episode["index"].number.map { String(Int($0)) } ?? "") 集当前锁定，请在西饭官方 App 确认可看范围")
        }
        let url = MediaSources.httpsURL(episode["playUrl"].string)
        guard let playURL = URL(string: url), !url.isEmpty else { throw HongguoError(.upstream, "西饭未提供有效 HTTPS 播放地址") }
        return PlayInfo(url: playURL, spadeA: nil, codec: "", source: .web, vid: vid, userAgent: "Mozilla/5.0", referer: nil)
    }
}

// MARK: - 河马

public final class HemaSource: MediaSource {
    public let id = "hema"
    public let label = "河马"
    static let origin = "https://www.kuaikaw.cn"

    /// GET when `body` is nil (HTML), POST JSON otherwise.
    public typealias Fetch = @Sendable (_ url: URL, _ body: Data?) async throws -> Data
    private let fetch: Fetch
    private let genreCache = TTLCache<[Genre]>(limit: 1)

    public init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? { url, body in
            var options = HTTPClient.Options()
            options.headers = ["User-Agent": "Mozilla/5.0", "Accept": body == nil ? "text/html" : "application/json",
                               "Content-Type": "application/json", "pname": "www.kuaikaw.cn", "Origin": HemaSource.origin,
                               "Referer": HemaSource.origin + "/"]
            options.timeout = 10
            options.maxRedirects = 0
            if let body { return try await HTTPClient.shared.post(url, json: body, options: options).data }
            return try await HTTPClient.shared.get(url, options: options).data
        }
    }

    static func parseId(_ value: String, episode: Bool = false) throws -> (bookId: String, chapterId: String?, seriesId: String) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "hema", parts.count == (episode ? 3 : 2), parts.dropFirst().allSatisfy({ $0.matchesDigits(min: 1, max: 30) }) else {
            throw HongguoError(.input, "河马剧集编号无效")
        }
        return (parts[1], episode ? parts[2] : nil, parts[0..<2].joined(separator: ":"))
    }

    func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        do { return try await fetch(URL(string: Self.origin + path)!, data) }
        catch let error as HongguoError where error.kind == .timeout { throw HongguoError(.timeout, "河马加载超时，请重试") }
        catch { throw HongguoError(.unavailable, "河马来源暂不可用，请稍后重试") }
    }

    /// `props.pageProps` of the Next.js page.
    static func pageData(_ html: String, error: String = "河马目录数据异常，请稍后重试") throws -> JSONValue {
        guard let match = HTMLData.firstMatch("<script\\b[^>]*\\bid=[\"']__NEXT_DATA__[\"'][^>]*>([\\s\\S]*?)</script>", in: html),
              match.count > 1, let json = try? JSONValue.parse(match[1]) else { throw HongguoError(.format, error) }
        let props = json["props"]["pageProps"]
        guard props.object != nil else { throw HongguoError(.format, error) }
        return props
    }

    static func books(_ list: [JSONValue]) -> [SeriesSummary] {
        var seen = Set<String>()
        return list.compactMap { item -> SeriesSummary? in
            guard let id = item["bookId"].idString, id.matchesDigits(min: 1, max: 30) else { return nil }
            let title = MediaSources.plainText(item["bookName"].string)
            guard !title.isEmpty, seen.insert(id).inserted else { return nil }
            return SeriesSummary(seriesId: "hema:\(id)", title: title, cover: MediaSources.httpsURL(item["coverWap"].string),
                                 episodeCount: item["totalChapterNum"].number.map(Int.init) ?? 0,
                                 tags: Array((item["bookTypeThree"].array ?? []).map { MediaSources.plainText($0["name"].string) }.filter { !$0.isEmpty }.prefix(4)))
        }
    }

    static func genres(_ directory: JSONValue) throws -> [Genre] {
        guard let list = directory["typeThreeList"].array else { throw HongguoError(.upstream, "河马没有返回可用题材，请重试") }
        var seen = Set<String>()
        let items = list.compactMap { item -> Genre? in
            guard let ids = item["typeThreeIds"].array, (1...16).contains(ids.count) else { return nil }
            let parts = ids.compactMap(\.idString)
            guard parts.count == ids.count, parts.allSatisfy({ $0.matchesDigits(min: 1, max: 30) }) else { return nil }
            let label = MediaSources.plainText(item["name"].string)
            guard !label.isEmpty else { return nil }
            return Genre(slug: parts.joined(separator: "-"), label: label)
        }.filter { $0.slug != "0" && seen.insert($0.slug).inserted }
        guard !items.isEmpty else { throw HongguoError(.upstream, "河马没有返回可用题材，请重试") }
        return items
    }

    public func browse(genre: String?, page: Int) async throws -> SourcePage {
        let slug = genre ?? "0"
        guard page >= 1, slug.range(of: "^\\d{1,30}(-\\d{1,30}){0,15}$", options: .regularExpression) != nil else {
            throw HongguoError(.input, "河马题材或页码无效，请重新选择")
        }
        var firstHTML: String?
        var items = await genreCache.get("genres")
        if items == nil {
            let html = String(decoding: try await request("/browse"), as: UTF8.self)
            firstHTML = html
            items = try Self.genres(try Self.pageData(html))
            await genreCache.set("genres", items!, ttl: 300)
        }
        guard slug == "0" || items!.contains(where: { $0.slug == slug }) else { throw HongguoError(.input, "河马题材无效，请重新选择") }
        let path = slug == "0" && page == 1 ? "/browse" : "/browse/\(slug)\(page > 1 ? "/\(page)" : "")"
        let html: String
        if path == "/browse", let firstHTML { html = firstHTML } else { html = String(decoding: try await request(path), as: UTF8.self) }
        let data = try Self.pageData(html)
        guard let list = data["bookList"].array, data["page"].number.map(Int.init) == page, (data["typeThreeId"].idString ?? "0") == slug else {
            throw HongguoError(.format, "河马返回的目录与请求不一致，请重试")
        }
        let results = Self.books(list)
        let hasMore = !results.isEmpty && html.range(of: "<a\\b[^>]*\\shref=[\"']/browse/\(slug)/\(page + 1)[\"']", options: .regularExpression) != nil
        return SourcePage(results: results, page: page, hasMore: hasMore, genres: items!)
    }

    public func search(_ keyword: String, page: Int) async throws -> SourcePage {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { throw HongguoError(.input, "请输入搜索关键词") }
        let page = max(1, page)
        let data = try await request("/seo/video/6007", body: ["sourceType": 1, "keyword": kw, "index": page])
        guard let response = try? JSONValue.parse(data), response["retCode"] == .int(0), let list = response["data"]["bookList"].array else {
            throw HongguoError(.format, "河马搜索数据异常，请稍后重试")
        }
        let results = Self.books(list)
        return SourcePage(results: results, page: page, hasMore: response["data"]["isMore"] == .int(1) && !results.isEmpty,
                          genres: [], total: response["data"]["totalSize"].number.map(Int.init) ?? 0)
    }

    func detail(_ seriesId: String) async throws -> JSONValue {
        let id = try Self.parseId(seriesId)
        let html = String(decoding: try await request("/drama/\(id.bookId)"), as: UTF8.self)
        let result = try Self.pageData(html, error: "河马详情数据异常，请稍后重试")
        try Self.checkDetail(result, bookId: id.bookId)
        return result
    }

    static func checkDetail(_ result: JSONValue, bookId: String) throws {
        guard result["bookInfoVo"]["bookId"].idString == bookId, let chapters = result["chapterList"].array else {
            throw HongguoError(.format, "河马返回的剧集与请求不一致")
        }
        var seen = Set<String>()
        for chapter in chapters {
            guard let id = chapter["chapterId"].idString, id.matchesDigits(min: 1, max: 30), seen.insert(id).inserted,
                  chapter["bookId"].isNull || chapter["bookId"].idString == bookId else {
                throw HongguoError(.format, "河马分集数据异常，请稍后重试")
            }
        }
    }

    static func episodes(_ result: JSONValue, seriesId: String) throws -> SeriesEpisodes {
        let name = MediaSources.plainText(result["bookInfoVo"]["bookName"].string)
        let title = name.isEmpty ? "未命名短剧" : name
        let episodes = (result["chapterList"].array ?? []).enumerated().map { offset, chapter in
            let free = chapter["isCharge"].string == "0"
            return Episode(vid: "\(seriesId):\(chapter["chapterId"].idString ?? "")", index: chapter["chapterIndex"].number.map(Int.init) ?? offset + 1,
                           title: MediaSources.plainText(chapter["chapterName"].string), seriesId: seriesId, webAvailable: free, locked: !free)
        }.sorted { $0.index < $1.index }
        guard !episodes.isEmpty else { throw HongguoError(.upstream, "河马分集列表为空") }
        return SeriesEpisodes(seriesId: seriesId, title: title, cover: MediaSources.httpsURL(result["bookInfoVo"]["coverWap"].string),
                              episodes: episodes, webAccessibleEpisodes: episodes.filter { $0.locked != true }.count, source: .web)
    }

    public func episodes(seriesId: String) async throws -> SeriesEpisodes {
        try Self.episodes(try await detail(seriesId), seriesId: seriesId)
    }

    public func playInfo(vid: String, seriesId: String?) async throws -> PlayInfo {
        let id = try Self.parseId(vid, episode: true)
        if let seriesId, !seriesId.isEmpty, try Self.parseId(seriesId).seriesId != id.seriesId { throw HongguoError(.input, "河马分集不属于当前剧集") }
        // Re-read the public detail every time: a free/paid decision is never reused.
        let result = try await detail(id.seriesId)
        guard let chapter = (result["chapterList"].array ?? []).first(where: { $0["chapterId"].idString == id.chapterId }) else {
            throw HongguoError(.upstream, "河马未找到该分集")
        }
        guard chapter["isCharge"].string == "0" else {
            throw MediaSources.locked("第 \(chapter["chapterIndex"].number.map { String(Int($0)) } ?? "") 集当前锁定，请在河马官方平台确认可看范围")
        }
        let video = chapter["chapterVideoVo"]
        let url = MediaSources.httpsURL(video["mp4720p"].string).isEmpty ? MediaSources.httpsURL(video["mp4"].string) : MediaSources.httpsURL(video["mp4720p"].string)
        guard !url.isEmpty, let playURL = URL(string: url) else { throw HongguoError(.upstream, "河马未提供有效 HTTPS 播放地址") }
        return PlayInfo(url: playURL, spadeA: nil, codec: "", source: .web, vid: vid, userAgent: "Mozilla/5.0", referer: Self.origin + "/")
    }
}

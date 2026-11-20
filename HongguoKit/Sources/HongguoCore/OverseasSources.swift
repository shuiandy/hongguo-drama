// SPDX-License-Identifier: GPL-3.0-only
// The opt-in overseas catalogues of the Electron app: ReelShort (src/native/reelshort.js, routes
// adapted from wanglinsaputra/Rest-Api-ReelShort, MIT) and DramaBox (src/native/dramabox.js,
// adapted from zuomeizuoyang/shortdrama-player, MIT). Both read only the public English
// website's server-rendered data: no account, signing key or unlock API.
import Foundation

/// A GET for a server-rendered page: status and body, any status returned, redirects not followed.
public typealias PageFetch = @Sendable (_ url: URL, _ timeout: TimeInterval) async throws -> (status: Int, body: Data)

enum NextPage {
    static func defaultFetch(maxBytes: Int) -> PageFetch {
        { url, timeout in
            var options = HTTPClient.Options()
            options.headers = ["User-Agent": "Mozilla/5.0", "Referer": (url.scheme ?? "https") + "://" + (url.host ?? "") + "/",
                               "Accept-Language": "en-US,en;q=0.9"]
            options.timeout = timeout
            options.maxRedirects = 0
            options.maxBytes = maxBytes
            options.acceptStatus = 100...599
            let response = try await HTTPClient.shared.get(url, options: options)
            return (response.status, response.data)
        }
    }

    /// The whole `__NEXT_DATA__` JSON of a Next.js page.
    static func data(_ html: String) -> JSONValue? {
        guard let match = HTMLData.firstMatch("<script\\b(?=[^>]*\\bid=[\"']__NEXT_DATA__[\"'])[^>]*>([\\s\\S]*?)</script\\s*>", in: html),
              match.count > 1 else { return nil }
        return try? JSONValue.parse(match[1])
    }

    static func url(_ origin: String, _ route: String, _ params: [(String, String)]) -> URL {
        var components = URLComponents(string: origin + route)!
        if !params.isEmpty { components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return components.url!
    }

    /// Runs one page request with the Electron error wording; `deadline` is shared by a whole operation.
    static func load(_ fetch: PageFetch, _ url: URL, name: String, deadline: Date?, regionHint: String) async throws -> JSONValue {
        let remaining = deadline.map { $0.timeIntervalSinceNow } ?? 10
        guard remaining > 0 else { throw HongguoError(.timeout, "\(name) 加载超时，请重试") }
        let response: (status: Int, body: Data)
        do { response = try await fetch(url, min(10, remaining)) } catch let error as HongguoError where error.kind == .timeout {
            throw HongguoError(.timeout, "\(name) 加载超时，请重试")
        } catch {
            throw HongguoError(.network, "\(name) 连接失败，请检查网络\(regionHint)或稍后重试")
        }
        switch response.status {
        case 403, 451: throw HongguoError(.unavailable, name == "ReelShort" ? "ReelShort 当前地区或网络暂不可用（HTTP \(response.status)）"
                                            : "DramaBox 当前网络或地区受限（HTTP \(response.status)），请检查网络分流")
        case 429: throw HongguoError(.unavailable, "\(name) 请求过于频繁，请稍后重试")
        case 200...299: break
        default: throw HongguoError(.network, "\(name) 连接失败，请检查网络\(regionHint)或稍后重试")
        }
        guard let data = Self.data(String(decoding: response.body, as: UTF8.self)) else {
            throw HongguoError(.format, "\(name) 官网数据格式已变化，请等待适配")
        }
        return data
    }

    static func dedupe(_ items: [SeriesSummary?]) -> [SeriesSummary] {
        var seen = Set<String>()
        return items.compactMap { $0 }.filter { seen.insert($0.seriesId).inserted }
    }
}

// MARK: - ReelShort

public final class ReelShortSource: MediaSource {
    public let id = "reelshort"
    public let label = "ReelShort（海外）"
    static let origin = "https://www.reelshort.com"
    static let idPattern = "^[a-zA-Z0-9_]{1,100}$"
    static let slugPattern = "^[a-z0-9]+(-[a-z0-9]+)*$"
    private let fetch: PageFetch

    public init(fetch: PageFetch? = nil) { self.fetch = fetch ?? NextPage.defaultFetch(maxBytes: 4 * 1024 * 1024) }

    static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }

    static func slug(_ title: String) -> String {
        MediaSources.plainText(title).lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " +", with: "-", options: .regularExpression)
    }

    struct ID { var bookId: String; var slug: String; var number: Int; var chapterId: String; var seriesId: String }

    static func parseId(_ value: String, episode: Bool = false) throws -> ID {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "reelshort", parts.count == (episode ? 5 : 3), matches(parts[1], idPattern),
              matches(parts[2], slugPattern), parts[2].count <= 200,
              !episode || (matches(parts[3], "^[1-9][0-9]{0,3}$") && matches(parts[4], idPattern)) else {
            throw HongguoError(.input, "ReelShort 剧集编号无效")
        }
        return ID(bookId: parts[1], slug: parts[2], number: episode ? Int(parts[3])! : 0, chapterId: episode ? parts[4] : "",
                  seriesId: parts[0..<3].joined(separator: ":"))
    }

    /// A `reelshort:` id or an official `https://www.reelshort.com/movie/<slug>-<id>` share link.
    public static func resolveSeriesId(_ value: String) throws -> String {
        if value.hasPrefix("reelshort:") { return try parseId(value).seriesId }
        guard let url = URL(string: value), url.scheme != nil else { throw HongguoError(.input, "ReelShort 分享链接无效") }
        guard url.scheme == "https", url.host == "www.reelshort.com", url.port == nil, url.user == nil, url.password == nil,
              let match = HTMLData.firstMatch("^/movie/([a-z0-9-]+)-([a-zA-Z0-9_]+)/?$", in: url.path(percentEncoded: false), options: []),
              match.count > 2 else { throw HongguoError(.input, "请输入 ReelShort 官网剧集链接") }
        return try parseId("reelshort:\(match[2]):\(match[1])").seriesId
    }

    func request(_ route: String, _ params: [(String, String)] = [], deadline: Date? = nil) async throws -> JSONValue {
        let props = try await NextPage.load(fetch, NextPage.url(Self.origin, route, params), name: "ReelShort", deadline: deadline, regionHint: "")["props"]["pageProps"]
        guard props.object != nil else { throw HongguoError(.format, "ReelShort 官网数据格式已变化，请等待适配") }
        return props
    }

    static func mediaURL(_ value: JSONValue) -> String {
        guard let text = value.string, text.hasPrefix("https://"), URLGuard.isPublicURL(text) else { return "" }
        return text
    }

    static func locked(_ item: JSONValue) -> Bool {
        ["locked", "is_locked", "is_lock", "isCharge"].contains { [JSONValue.bool(true), .int(1), .double(1), .string("1")].contains(item[$0]) }
    }

    static func book(_ book: JSONValue) -> SeriesSummary? {
        let id = book["book_id"].idString.flatMap { $0.isEmpty ? nil : $0 } ?? book["_id"].idString ?? ""
        let title = MediaSources.plainText(book["book_title"].string)
        let path = slug(title)
        guard matches(id, idPattern), !title.isEmpty, matches(path, slugPattern), path.count <= 200 else { return nil }
        return SeriesSummary(seriesId: "reelshort:\(id):\(path)", title: title, cover: mediaURL(book["book_pic"]),
                             episodeCount: book["chapter_count"].number.map(Int.init) ?? 0, description: MediaSources.plainText(book["special_desc"].string))
    }

    static func pageResult(_ books: [JSONValue], page: Int, genres: [Genre] = []) throws -> SourcePage {
        let results = NextPage.dedupe(books.prefix(500).map(book))
        if !books.isEmpty && results.isEmpty { throw HongguoError(.format, "ReelShort 片单缺少可用剧集编号，请等待适配") }
        // Only the public website snapshot exists: no verified pagination cursor.
        return SourcePage(results: results, page: page, hasMore: false, genres: genres, total: results.count)
    }

    public func browse(genre: String?, page: Int) async throws -> SourcePage {
        guard page >= 1 else { throw HongguoError(.input, "ReelShort 页码无效") }
        if page > 1 { return try Self.pageResult([], page: page) }
        let deadline = Date().addingTimeInterval(10)
        let data = try await request("/", deadline: deadline)
        guard let shelves = data["fallback"]["/api/ms/hall/webInfo"]["bookShelfList"].array, shelves.count <= 100 else {
            throw HongguoError(.format, "ReelShort 官网片单格式已变化，请等待适配")
        }
        let genres = shelves.enumerated().map { Genre(slug: "shelf-\($0.offset)", label: MediaSources.plainText($0.element["bookshelf_name"].string)) }
            .filter { !$0.label.isEmpty }
        let genre = genre.flatMap { $0.isEmpty ? nil : $0 }
        let selected = genre.flatMap { slug in genres.first { $0.slug == slug } }
        if genre != nil && selected == nil { throw HongguoError(.input, "ReelShort 分类已变化，请重新选择") }
        let chosen = selected.map { [shelves[Int($0.slug.dropFirst(6))!]] } ?? shelves
        var books: [JSONValue] = []
        var seen = Set<String>()
        // A shelf entry may omit its id: look it up by exact title, at most 12 books within one deadline.
        for entry in chosen.flatMap({ $0["books"].array ?? [] }) {
            let title = MediaSources.plainText(entry["book_title"].string)
            let key = title.lowercased()
            guard !title.isEmpty, seen.insert(key).inserted else { continue }
            if Self.book(entry) != nil {
                books.append(entry)
            } else {
                let found = try await search(title, page: 1, deadline: deadline).results.filter { $0.title.lowercased() == key }
                guard found.count == 1 else { throw HongguoError(.upstream, "ReelShort 片单缺少唯一对应的剧集编号，请按完整剧名搜索") }
                guard case .object(var object) = entry else { continue }
                object["book_id"] = .string(try Self.parseId(found[0].seriesId).bookId)
                books.append(.object(object))
            }
            if books.count >= 12 { break }
        }
        return try Self.pageResult(books, page: page, genres: genres)
    }

    public func search(_ keyword: String, page: Int) async throws -> SourcePage {
        try await search(keyword, page: page, deadline: nil)
    }

    func search(_ keyword: String, page: Int, deadline: Date?) async throws -> SourcePage {
        let keywords = MediaSources.plainText(keyword)
        guard !keywords.isEmpty, keywords.count <= 200, page >= 1 else { throw HongguoError(.input, "ReelShort 搜索词或页码无效") }
        if page > 1 { return try Self.pageResult([], page: page) }
        guard let books = try await request("/search", [("keywords", keywords)], deadline: deadline)["books"].array else {
            throw HongguoError(.format, "ReelShort 官网搜索格式已变化，请等待适配")
        }
        return try Self.pageResult(books, page: page)
    }

    public func episodes(seriesId: String) async throws -> SeriesEpisodes {
        let id = try Self.parseId(seriesId)
        let data = try await request("/movie/\(id.slug)-\(id.bookId)")["data"]
        let ownId = data["book_id"].idString.flatMap { $0.isEmpty ? nil : $0 } ?? data["_id"].idString
        guard let online = data["online_base"].array, online.count <= 10000, ownId == nil || ownId == "" || ownId == id.bookId else {
            throw HongguoError(.format, "ReelShort 返回的剧集与请求不一致")
        }
        let title = MediaSources.plainText(data["book_title"].string)
        guard !title.isEmpty else { throw HongguoError(.format, "ReelShort 缺少剧集标题，请等待适配") }
        var seen: [Int: String] = [:]
        var episodes: [Episode] = []
        for item in online {
            guard let raw = item["serial_number"].number, raw == raw.rounded(), raw > 0, raw <= 9999,
                  let chapter = item["chapter_id"].idString, Self.matches(chapter, Self.idPattern) else { continue }
            let number = Int(raw)
            let vid = "\(id.seriesId):\(number):\(chapter)"
            if let other = seen[number] {
                if other != vid { throw HongguoError(.format, "ReelShort 分集编号冲突，请等待适配") }
                continue
            }
            seen[number] = vid
            let name = MediaSources.plainText(item["chapter_name"].string)
            let isLocked = Self.locked(item)
            episodes.append(Episode(vid: vid, index: number, title: name.isEmpty ? "第 \(number) 集" : name, seriesId: id.seriesId,
                                    webAvailable: !isLocked, locked: isLocked))
        }
        episodes.sort { $0.index < $1.index }
        guard !episodes.isEmpty else { throw HongguoError(.upstream, "ReelShort 分集列表为空") }
        return SeriesEpisodes(seriesId: id.seriesId, title: title, cover: Self.mediaURL(data["book_pic"]), episodes: episodes,
                              webAccessibleEpisodes: episodes.filter { $0.locked != true }.count, source: .web)
    }

    public func playInfo(vid: String, seriesId: String?) async throws -> PlayInfo {
        let id = try Self.parseId(vid, episode: true)
        if let seriesId, !seriesId.isEmpty, seriesId != id.seriesId { throw HongguoError(.input, "ReelShort 分集不属于当前剧集") }
        let list = try await episodes(seriesId: id.seriesId)
        guard let episode = list.episodes.first(where: { $0.vid == vid }) else { throw HongguoError(.upstream, "ReelShort 未找到该分集") }
        if episode.locked == true { throw MediaSources.locked("该集已锁定，请在 ReelShort 官方平台确认观看权限") }
        let data = try await request("/episodes/episode-\(id.number)-\(id.slug)-\(id.bookId)-\(id.chapterId)", [("play_time", "1")])["data"]
        let chapter = data["chapter_id"].idString ?? ""
        guard data.object != nil, data["serial_number"].number == Double(id.number), chapter.isEmpty || chapter == id.chapterId else {
            throw HongguoError(.format, "ReelShort 返回的分集与请求不一致")
        }
        if Self.locked(data) || (data["video_url"].string ?? "").isEmpty {
            throw MediaSources.locked("该集未提供公开播放地址，请在 ReelShort 官方平台确认观看权限")
        }
        let url = Self.mediaURL(data["video_url"])
        guard let playURL = URL(string: url), ["mp4", "m3u8"].contains(playURL.pathExtension.lowercased()) else {
            throw HongguoError(.upstream, "ReelShort 未提供可直接播放的 HTTPS MP4 或 M3U8 地址")
        }
        return PlayInfo(url: playURL, spadeA: nil, codec: "", source: .web, vid: vid, userAgent: "Mozilla/5.0", referer: Self.origin + "/")
    }
}

// MARK: - DramaBox

public final class DramaBoxSource: MediaSource {
    public let id = "dramabox"
    public let label = "DramaBox（海外）"
    static let origin = "https://www.dramabox.com"
    private let fetch: PageFetch

    public init(fetch: PageFetch? = nil) { self.fetch = fetch ?? NextPage.defaultFetch(maxBytes: 8 * 1024 * 1024) }

    static func parseId(_ value: String, episode: Bool = false) throws -> (bookId: String, chapterId: String, seriesId: String) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "dramabox", parts.count == (episode ? 3 : 2), parts.dropFirst().allSatisfy({ $0.matchesDigits(min: 1, max: 24) }) else {
            throw HongguoError(.input, "DramaBox 剧集编号无效")
        }
        return (parts[1], episode ? parts[2] : "", parts[0..<2].joined(separator: ":"))
    }

    /// A `dramabox:` id or an English share link on www.dramabox.com / www.dramaboxdb.com.
    public static func resolveSeriesId(_ value: String) throws -> String {
        if value.hasPrefix("dramabox:") { return try parseId(value).seriesId }
        guard let url = URL(string: value), url.scheme != nil else { throw HongguoError(.input, "DramaBox 分享链接无效") }
        guard url.scheme == "https", ["www.dramabox.com", "www.dramaboxdb.com"].contains(url.host ?? ""), url.port == nil,
              url.user == nil, url.password == nil,
              let match = HTMLData.firstMatch("^/(?:drama|movie)/(\\d{1,24})(?:/|$)", in: url.path(percentEncoded: false), options: []),
              match.count > 1 else { throw HongguoError(.input, "请输入 DramaBox 英文官网剧集链接") }
        return "dramabox:\(match[1])"
    }

    func request(_ route: String, _ params: [(String, String)] = []) async throws -> JSONValue {
        let data = try await NextPage.load(fetch, NextPage.url(Self.origin, route, params), name: "DramaBox", deadline: nil, regionHint: "分流")
        let props = data["props"]["pageProps"]
        let locale = props["locale"].isNull ? data["locale"] : props["locale"]
        guard props.object != nil, locale == .string("en") else { throw HongguoError(.format, "DramaBox 官网数据或语言不匹配") }
        return props
    }

    static func book(_ book: JSONValue) -> SeriesSummary? {
        let name = MediaSources.plainText(book["bookName"].string).isEmpty ? MediaSources.plainText(book["name"].string) : MediaSources.plainText(book["bookName"].string)
        guard let id = book["bookId"].idString, id.matchesDigits(min: 1, max: 24), !name.isEmpty else { return nil }
        let coverValue = (book["cover"].string ?? "").isEmpty ? book["coverWap"].string : book["cover"].string
        let cover = coverValue.flatMap { URLGuard.isPublicURL($0) ? $0 : nil } ?? ""
        let count = book["chapterCount"].isNull ? book["totalChapterNum"] : book["chapterCount"]
        return SeriesSummary(seriesId: "dramabox:\(id)", title: name, cover: cover, episodeCount: count.number.map(Int.init) ?? 0,
                             description: MediaSources.plainText(book["introduction"].string))
    }

    static func pageResult(_ props: JSONValue, page: Int, pagesKey: String) throws -> SourcePage {
        guard let list = props["bookList"].array, list.count <= 500, props["pageNo"].number == Double(page),
              let pages = props[pagesKey].number, pages == pages.rounded(), pages >= 0 else {
            throw HongguoError(.format, "DramaBox 官网分页与请求不一致")
        }
        let results = NextPage.dedupe(list.map(book))
        if !list.isEmpty && results.isEmpty { throw HongguoError(.format, "DramaBox 未返回有效剧集") }
        return SourcePage(results: results, page: page, hasMore: !results.isEmpty && Double(page) < pages, genres: [],
                          total: props["totalNum"].number.map(Int.init) ?? 0)
    }

    public func browse(genre: String?, page: Int) async throws -> SourcePage {
        guard (1...10000).contains(page), genre?.isEmpty ?? true else { throw HongguoError(.input, "DramaBox 页码或分类无效") }
        return try Self.pageResult(try await request(page == 1 ? "/browse" : "/browse/0/\(page)"), page: page, pagesKey: "pages")
    }

    public func search(_ keyword: String, page: Int) async throws -> SourcePage {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200, (1...50).contains(page) else { throw HongguoError(.input, "DramaBox 搜索词或页码无效") }
        return try Self.pageResult(try await request("/search", [("searchValue", value), ("page", String(page))]), page: page, pagesKey: "totalPage")
    }

    func detail(_ seriesId: String) async throws -> (book: SeriesSummary, chapters: [JSONValue]) {
        let id = try Self.parseId(seriesId)
        let props = try await request("/drama/\(id.bookId)")
        guard let book = Self.book(props["bookInfo"]), book.seriesId == seriesId, let chapters = props["chapterList"].array,
              !chapters.isEmpty, chapters.count <= 10000, book.episodeCount == chapters.count else {
            throw HongguoError(.format, "DramaBox 返回的剧集或完整分集数量不一致")
        }
        let sorted = chapters.sorted { ($0["index"].number ?? 0) < ($1["index"].number ?? 0) }
        var ids = Set<String>()
        for (offset, chapter) in sorted.enumerated() {
            guard let cid = chapter["id"].idString, cid.matchesDigits(min: 1, max: 24), ids.insert(cid).inserted,
                  chapter["index"] == .int(Int64(offset)) else { throw HongguoError(.format, "DramaBox 分集编号重复或不连续") }
        }
        return (book, sorted)
    }

    public func episodes(seriesId: String) async throws -> SeriesEpisodes {
        let (book, chapters) = try await detail(seriesId)
        let episodes = chapters.enumerated().map { offset, chapter -> Episode in
            let name = MediaSources.plainText(chapter["name"].string)
            let open = chapter["unlock"].bool == true
            return Episode(vid: "\(seriesId):\(chapter["id"].idString!)", index: offset + 1, title: name.isEmpty ? "第 \(offset + 1) 集" : name,
                           seriesId: seriesId, webAvailable: open, locked: !open)
        }
        return SeriesEpisodes(seriesId: seriesId, title: book.title, cover: book.cover, episodes: episodes,
                              webAccessibleEpisodes: episodes.filter { $0.locked != true }.count, source: .web)
    }

    /// Official HTTPS CDN only (`dramaboxdb.com` and its subdomains), no port or credentials.
    public static func isMediaURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil, url.user == nil, url.password == nil, URLGuard.isPublicURL(url),
              let host = url.host?.lowercased() else { return false }
        return host == "dramaboxdb.com" || host.hasSuffix(".dramaboxdb.com")
    }

    public func playInfo(vid: String, seriesId: String?) async throws -> PlayInfo {
        let id = try Self.parseId(vid, episode: true)
        if let seriesId, !seriesId.isEmpty, seriesId != id.seriesId { throw HongguoError(.input, "DramaBox 分集不属于当前剧集") }
        let (_, chapters) = try await detail(id.seriesId)
        guard let chapter = chapters.first(where: { $0["id"].idString == id.chapterId }) else { throw HongguoError(.upstream, "DramaBox 未找到该分集") }
        guard chapter["unlock"].bool == true else { throw MediaSources.locked("该集未公开解锁，请在 DramaBox 官方平台确认观看权限") }
        guard let url = chapter["mp4"].string.flatMap(URL.init(string:)), Self.isMediaURL(url) else {
            throw HongguoError(.security, "DramaBox 片源必须来自官方 HTTPS CDN")
        }
        let m3u8 = chapter["m3u8Flag"]
        let flagged = !(m3u8.isNull || m3u8 == .bool(false) || m3u8 == .int(0) || m3u8 == .string("") || m3u8 == .double(0))
        guard !flagged, url.pathExtension.lowercased() == "mp4", url.path.range(of: "encrypt", options: .caseInsensitive) == nil else {
            throw HongguoError(.unavailable, "DramaBox 当前仅支持官方公开未加密 MP4")
        }
        return PlayInfo(url: url, spadeA: nil, codec: "", source: .web, vid: vid, userAgent: "Mozilla/5.0", referer: Self.origin + "/")
    }
}

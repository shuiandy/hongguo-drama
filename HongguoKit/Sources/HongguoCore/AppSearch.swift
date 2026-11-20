// SPDX-License-Identifier: GPL-3.0-only
// The App search (`/reading/bookapi/search/tab/v`), the only search every app uses, and the
// App "近期上新" catalogue (a list of its own, not a search fallback). Ports of
// src/native/hongguo-app-search.js and src/native/hongguo-app-new.js. No website search.
import Foundation

// MARK: - Title helpers

public enum SearchText {
    /// Strips tags and the common entities, collapses whitespace (`cleanTitle`).
    public static func clean(_ value: String?) -> String {
        var text = (value ?? "").replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Catalogue covers: a HEIC object on the novel picture CDN maps to its public JPEG variant;
    /// other HEIC covers are dropped.
    public static func catalogCover(_ value: String?) -> String {
        let text = (value ?? "").trimmingCharacters(in: .whitespaces)
        let isHTTP = text.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
        let isHEIC = text.range(of: "\\.heic(\\?|$)", options: [.regularExpression, .caseInsensitive]) != nil
        let compatible = isHTTP && !isHEIC ? text : ""
        guard let value, let url = URL(string: value), url.path.lowercased().hasSuffix(".heic") else { return compatible }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), host.range(of: "(^|\\.)(fqnovelpic\\.com|byteimg\\.com)$", options: .regularExpression) != nil,
              url.path.hasPrefix("/novel-pic/"), url.path.contains("~") else { return "" }
        return "https://p3-novel.byteimg.com\(url.path.split(separator: "~", maxSplits: 1)[0])~tplv-shrink:640:0.image"
    }

    static func integer(_ value: JSONValue) -> Int? {
        switch value {
        case .int(let i): return i >= 0 ? Int(exactly: i) : nil
        case .double(let d): return d >= 0 && d.rounded() == d && d <= 9_007_199_254_740_991 ? Int(d) : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isDigitsOnly && !t.isEmpty ? Int(t) : nil
        default: return nil
        }
    }
}

// MARK: - App search

public struct AppSearchCursor: Equatable, Sendable {
    public var searchId: String
    public var passback: String
    public var nextOffset: Int?
}

public struct AppSearchPage: Sendable {
    public var results: [SeriesSummary]
    public var page: Int
    public var hasMore: Bool
    public var cursor: AppSearchCursor
}

public final class AppSearchService: Sendable {
    static let searchTab = 11
    private let transport: AppTransport
    private let signer: @Sendable () -> AppLegacySigner

    public init(http: HTTPClient = .shared) {
        transport = AppTransport(http: http)
        signer = { AppLegacySigner.shared }
    }

    public func search(_ keyword: String, page: Int = 1, cursor: AppSearchCursor? = nil, timeout: TimeInterval = 8) async throws -> AppSearchPage {
        let kw = SearchText.clean(keyword)
        guard !kw.isEmpty, kw.utf16.count <= 80 else { throw HongguoError(.input, "App 搜索词无效") }
        guard (1...50).contains(page) else { throw HongguoError(.input, "App 搜索页码需为 1 至 50 的整数") }
        if page > 1, cursor == nil || (cursor!.searchId.isEmpty && cursor!.passback.isEmpty && cursor!.nextOffset == nil) {
            throw HongguoError(.input, "App 搜索游标已失效，请重新搜索")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let identity: PlaybackIdentity
        do {
            identity = try await PersistentAppDevice.shared.get(transport: transport)
        } catch {
            throw HongguoError(.unavailable, "App 搜索暂不可用")
        }
        guard Date() < deadline else { throw HongguoError(.timeout, "App 搜索超时") }
        let signed = try signer().search(keyword: kw, page: page,
                                         cursor: cursor.map { .init(searchId: $0.searchId, passback: $0.passback, nextOffset: $0.nextOffset) },
                                         identity: identity, nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
        let payload: JSONValue
        do {
            payload = try await transport.requestJSON(signed.url, headers: signed.headers + PersistentAppDevice.authHeaders(),
                                                      deadline: deadline)
        } catch let error as AppSourceError {
            if error.code == .timeout { throw HongguoError(.timeout, "App 搜索超时") }
            throw HongguoError(.unavailable, "App 搜索暂不可用")
        }
        return try Self.parse(payload, page: page)
    }

    /// Port of `parseSearchPayload`: the short-drama tab only, de-duplicated, no ad or suggestion cells.
    /// Covers are kept as the App sends them (HEIC included), with heat and tags from `sub_title_list`.
    public static func parse(_ payload: JSONValue, page: Int) throws -> AppSearchPage {
        guard (1...50).contains(page) else { throw HongguoError(.input, "App 搜索页码需为 1 至 50 的整数") }
        guard payload.object != nil else { throw HongguoError(.upstream, "App 搜索返回空响应") }
        if let code = SearchText.integer(payload["code"]), code != 0 { throw HongguoError(.upstream, "App 搜索返回业务错误") }
        if case .int(let code) = payload["code"], code != 0 { throw HongguoError(.upstream, "App 搜索返回业务错误") }
        guard let tabs = payload["search_tabs"].array ?? payload["data"]["search_tabs"].array else {
            throw HongguoError(.format, "App 搜索数据结构异常")
        }
        guard let tab = tabs.first(where: { SearchText.integer($0["tab_type"]) == searchTab }) else {
            throw HongguoError(.format, "App 搜索暂未返回短剧结果")
        }
        var seen = Set<String>(), results: [SeriesSummary] = []
        for cell in tab["data"].array ?? [] {
            guard let video = (cell["video_data"].array ?? []).first(where: { ($0["series_id"].idString ?? "").matchesDigits(min: 1, max: 30) }),
                  let seriesId = video["series_id"].idString else { continue }
            let title = SearchText.clean(cell["search_high_light"]["title"]["text"].string ?? video["title"].string ?? cell["cell_name"].string)
            guard !title.isEmpty, seen.insert(seriesId).inserted else { continue }
            let count = SearchText.integer(video["episode_cnt"]) ?? SearchText.integer(video["episode_count"]) ?? 0
            let rawCover = video["cover"].string ?? video["series_cover"].string ?? video["video_detail"]["series_cover"].string ?? ""
            let subs = video["sub_title_list"].array ?? []
            let rawHeat = AccountService.cleanText(
                subs.first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string
                ?? subs.first(where: { ($0["content"].string ?? "").contains("热度") })?["content"].string
            )
            let heat = (!rawHeat.isEmpty && !rawHeat.contains("热度")) ? "\(rawHeat)热度" : rawHeat
            let tags = subs.filter { Int($0["data_type"].number ?? 0) == 3 }
                .map { AccountService.cleanText($0["content"].string) }.filter { !$0.isEmpty }
            results.append(SeriesSummary(seriesId: seriesId, title: title, cover: DiscoveryAccess.normalizedCover(rawCover),
                                         episodeCount: count, tags: tags,
                                         description: SearchText.clean(video["series_intro"].string ?? video["video_desc"].string ?? cell["series_intro"].string),
                                         heat: heat, episodeLabel: count > 0 ? "全\(count)集" : ""))
        }
        let hasMore = tab["has_more"].bool == true && page < 50
        return AppSearchPage(results: results, page: page, hasMore: hasMore,
                             cursor: AppSearchCursor(searchId: tab["search_id"].idString ?? "", passback: tab["passback"].string ?? "",
                                                     nextOffset: SearchText.integer(tab["next_offset"])))
    }
}

// MARK: - App new releases

public struct NewRelease: Equatable, Sendable {
    public var series: SeriesSummary
    public var releasedToday: Bool
}

public actor NewReleaseService {
    public static let shared = NewReleaseService()
    static let pageLimit = 50
    static let cacheTTL: TimeInterval = 60
    /// Live-action and AI dramas: same endpoint, different filter.
    static let genres = [("default", "short_play"), ("ai_series", "ai_series")]

    public struct Listing: Sendable { public var items: [NewRelease]; public var cached: Bool; public var partial: Bool }

    /// One catalogue page: payload in, JSON out. Injected in tests.
    public typealias Fetch = @Sendable (_ body: [UInt8], _ deadline: Date) async throws -> JSONValue
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var cache: (expires: Date, pages: Int, items: [NewRelease])?
    private var inflight: (pages: Int, task: Task<Listing, Error>)?

    public init(fetch: Fetch? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        // The category list with the persistent device, like every other catalogue request.
        self.fetch = fetch ?? { body, deadline in
            try await AppCatalogueAccess.landpage(body: Data(body), timeout: max(1, deadline.timeIntervalSinceNow))
        }
        self.now = now
    }

    static func pageBody(scene: String, genre: String, offset: Int, sessionId: String) -> [UInt8] {
        let body: [String: Any] = [
            "filter_ids": "", "req_scene": scene, "offset": offset, "need_selector_panel": false, "limit": pageLimit,
            "select_items": ["genre": [genre], "sort": ["online_time"], "category_dim_theme": [String](), "category_dim_role": [String](),
                             "category_dim_epoch": [String](), "gender": [String](), "online_time": ["days_7"], "creation_status": [String]()],
            "session_id": sessionId, "req_type": offset > 0 ? "only_content" : "default", "client_req_type": 3,
        ]
        return Array((try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data())
    }

    static func row(_ row: JSONValue) -> NewRelease? {
        guard let id = row["series_id"].idString, id.matchesDigits(min: 1, max: 30) else { return nil }
        let title = SearchText.clean(row["title"].string ?? row["series_title"].string ?? row["series_name"].string)
        guard !title.isEmpty else { return nil }
        var labels: [String] = []
        func add(_ value: String?) { let text = SearchText.clean(value); if !text.isEmpty, !labels.contains(text) { labels.append(text) } }
        add(row["tag_info"]["text"].string)
        for item in row["sub_title_list"].array ?? [] { add(item["content"].string) }
        let summary = SeriesSummary(seriesId: id, title: title, cover: SearchText.catalogCover(row["cover"].string),
                                    episodeCount: SearchText.integer(row["episode_cnt"]) ?? 0,
                                    tags: Array(labels.filter { $0 != "新剧" && $0 != "今日上新" }.prefix(4)),
                                    description: SearchText.clean(row["video_desc"].string ?? row["series_intro"].string))
        return NewRelease(series: summary, releasedToday: labels.contains("今日上新"))
    }

    /// Merges rows; a series in both lists keeps the "today" mark and the fuller fields.
    static func collect(_ rows: [JSONValue]) -> [NewRelease] {
        var order: [String] = [], byId: [String: NewRelease] = [:]
        for raw in rows {
            guard let item = row(raw) else { continue }
            guard var existing = byId[item.series.seriesId] else { byId[item.series.seriesId] = item; order.append(item.series.seriesId); continue }
            existing.releasedToday = existing.releasedToday || item.releasedToday
            var tags = existing.series.tags
            for tag in item.series.tags where !tags.contains(tag) { tags.append(tag) }
            existing.series.tags = Array(tags.prefix(4))
            if existing.series.cover.isEmpty { existing.series.cover = item.series.cover }
            if existing.series.description.isEmpty { existing.series.description = item.series.description }
            if existing.series.episodeCount == 0 { existing.series.episodeCount = item.series.episodeCount }
            byId[item.series.seriesId] = existing
        }
        return order.compactMap { byId[$0] }
    }

    private func fetchGenre(scene: String, genre: String, pages: Int, deadline: Date) async throws -> [JSONValue] {
        var rows: [JSONValue] = [], offset = 0, sessionId = ""
        for _ in 0..<pages {
            guard now() < deadline else { break }
            let payload = try await fetch(Self.pageBody(scene: scene, genre: genre, offset: offset, sessionId: sessionId), deadline)
            guard payload.object != nil else { throw HongguoError(.upstream, "App 上新返回空响应") }
            if let code = SearchText.integer(payload["code"]), code != 0 { throw HongguoError(.upstream, "App 上新服务暂不可用") }
            guard let data = payload["data"].object, let videos = data["video_data"]?.array else { throw HongguoError(.format, "App 上新数据结构异常") }
            rows += videos
            guard data["has_more"]?.bool == true, let next = data["next_offset"].flatMap(SearchText.integer), next > offset else { break }
            offset = next
            sessionId = data["session_id"]?.idString ?? data["session_id"]?.string ?? ""
        }
        // Nothing read before the deadline is a timeout, not "no new releases".
        if rows.isEmpty && now() >= deadline { throw HongguoError(.timeout, "App 上新请求超时") }
        return rows
    }

    /// The last 7 days of releases (live action + AI), newest first. Complete results are cached briefly.
    public func list(pages: Int = 2, timeout: TimeInterval = 8, useCache: Bool = true) async throws -> Listing {
        let count = max(1, min(8, pages))
        if useCache, let cache, cache.expires > now(), cache.pages >= count { return Listing(items: cache.items, cached: true, partial: false) }
        if let inflight, inflight.pages >= count { return try await inflight.task.value }
        let deadline = now().addingTimeInterval(timeout)
        let task = Task { () throws -> Listing in
            var rows: [JSONValue] = [], failures: [Error] = []
            await withTaskGroup(of: (Int, Result<[JSONValue], Error>).self) { group in
                for (index, (scene, genre)) in Self.genres.enumerated() {
                    group.addTask {
                        do { return (index, .success(try await self.fetchGenre(scene: scene, genre: genre, pages: count, deadline: deadline))) }
                        catch { return (index, .failure(error)) }
                    }
                }
                // Keep live action before AI, as the JS does with allSettled.
                var settled: [(Int, Result<[JSONValue], Error>)] = []
                for await result in group { settled.append(result) }
                for (_, result) in settled.sorted(by: { $0.0 < $1.0 }) {
                    switch result { case .success(let value): rows += value; case .failure(let error): failures.append(error) }
                }
            }
            let items = Self.collect(rows)
            if items.isEmpty, let first = failures.first { throw first }
            return Listing(items: items, cached: false, partial: !failures.isEmpty)
        }
        inflight = (count, task)
        defer { if inflight?.task == task { inflight = nil } }
        let result = try await task.value
        if !result.partial, !result.items.isEmpty { cache = (now().addingTimeInterval(Self.cacheTTL), count, result.items) }
        return result
    }

    public func clearCache() { cache = nil; inflight = nil }
}

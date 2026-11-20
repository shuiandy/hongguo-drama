// SPDX-License-Identifier: GPL-3.0-only
// Ports of src/native/hongguo-app-search.js (signed App search), src/native/hongguo-app-new.js
// (App "近期上新" catalogue) and the hongguo branch of `searchAtSourcePage` in main.js, which
// combines the website search with both.
import Foundation

// MARK: - Title helpers

public enum SearchText {
    /// NFKC, lower case, without spaces, punctuation and symbols (`normalizeTitle`).
    public static func normalize(_ value: String) -> String {
        let folded = value.precomposedStringWithCompatibilityMapping.lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { scalar in
            let p = scalar.properties
            if p.isWhitespace { return false }
            switch p.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return false
            default: return true
            }
        }))
    }

    /// Up to two looser queries: the title without punctuation, then its first clause.
    public static func relaxedQueries(_ keyword: String) -> [String] {
        let text = keyword.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = normalizeKeepingCase(text)
        var out: [String] = []
        if !stripped.isEmpty, stripped != text { out.append(stripped) }
        let clauses = splitClauses(text)
        if let first = clauses.first(where: { $0.count >= 2 }), first != text, !out.contains(first) { out.append(first) }
        return Array(out.prefix(2))
    }

    static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default: return false
        }
    }

    static func normalizeKeepingCase(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isSeparator($0) }))
    }

    static func splitClauses(_ text: String) -> [String] {
        var parts: [String] = [], current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isSeparator(scalar) { if !current.isEmpty { parts.append(String(current)); current = .init() } }
            else { current.append(scalar) }
        }
        if !current.isEmpty { parts.append(String(current)) }
        return parts
    }

    /// Strips tags and the common entities, collapses whitespace (`cleanTitle`).
    public static func clean(_ value: String?) -> String {
        var text = (value ?? "").replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// App covers; HEIC variants are dropped, as AppKit may not show every one of them.
    public static func appCover(_ value: String?) -> String {
        let url = (value ?? "").trimmingCharacters(in: .whitespaces)
        guard url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil else { return "" }
        return url.range(of: "\\.heic(\\?|$)", options: [.regularExpression, .caseInsensitive]) != nil ? "" : url
    }

    /// Catalogue covers: a HEIC object on the novel picture CDN maps to its public JPEG variant.
    public static func catalogCover(_ value: String?) -> String {
        let compatible = appCover(value)
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

// MARK: - Shared anonymous identity

/// One registered App identity for search, kept in memory; failures are shared for 10 s.
actor AppSearchIdentity {
    static let shared = AppSearchIdentity()
    private var identity: PlaybackIdentity?
    private var retryAfter = Date.distantPast

    func get(transport: AppTransport) async throws -> PlaybackIdentity {
        if let identity { return identity }
        guard Date() >= retryAfter else { throw HongguoError(.unavailable, "App 搜索暂不可用") }
        do {
            let value = try await PlaybackDevice.registerOnce(transport: transport)
            identity = value
            return value
        } catch {
            retryAfter = Date().addingTimeInterval(10)
            throw HongguoError(.unavailable, "App 搜索暂不可用")
        }
    }

    func reset() { identity = nil }
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
        let identity = try await AppSearchIdentity.shared.get(transport: transport)
        guard Date() < deadline else { throw HongguoError(.timeout, "App 搜索超时") }
        let signed = try signer().search(keyword: kw, page: page,
                                         cursor: cursor.map { .init(searchId: $0.searchId, passback: $0.passback, nextOffset: $0.nextOffset) },
                                         identity: identity, nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
        let payload: JSONValue
        do {
            payload = try await transport.requestJSON(signed.url, headers: signed.headers, deadline: deadline)
        } catch let error as AppSourceError {
            if error.code == .timeout { throw HongguoError(.timeout, "App 搜索超时") }
            throw HongguoError(.unavailable, "App 搜索暂不可用")
        }
        return try Self.parse(payload, page: page)
    }

    /// Port of `parseSearchPayload`: the short-drama tab only, de-duplicated, no ad or suggestion cells.
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
            results.append(SeriesSummary(seriesId: seriesId, title: title, cover: SearchText.appCover(video["cover"].string),
                                         episodeCount: count,
                                         description: SearchText.clean(video["series_intro"].string ?? video["video_desc"].string ?? cell["series_intro"].string)))
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
    static let categoryPath = "/reading/distribution/category/landpage/v/"
    static let pageLimit = 50
    static let cacheTTL: TimeInterval = 60
    static let maxResults = 20
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
        let transport = AppTransport(http: .shared)
        self.fetch = fetch ?? { body, deadline in
            let signed = try AppLegacySigner.shared.metadata(path: NewReleaseService.categoryPath, values: [], payload: body,
                                                             nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
            do {
                return try await transport.requestJSON(signed.url, method: "POST", headers: signed.headers, body: body, deadline: deadline)
            } catch let error as AppSourceError where error.code == .timeout {
                throw HongguoError(.timeout, "App 上新请求超时")
            } catch let error as AppSourceError {
                throw HongguoError(.unavailable, error.message)
            }
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

    /// Exact title first, then titles containing the query, then the query containing the title.
    public static func match(_ items: [NewRelease], keyword: String) -> [NewRelease] {
        let query = SearchText.normalize(keyword)
        guard query.count >= 2 else { return [] }
        var scored: [(NewRelease, Int, Int)] = []
        for (index, item) in items.enumerated() {
            let title = SearchText.normalize(item.series.title)
            guard !title.isEmpty else { continue }
            let score = title == query ? 0 : title.contains(query) ? 1 : (title.count >= 2 && query.contains(title)) ? 2 : -1
            if score >= 0 { scored.append((item, score, index)) }
        }
        return scored.sorted { ($0.1, $0.0.releasedToday ? 0 : 1, $0.2) < ($1.1, $1.0.releasedToday ? 0 : 1, $1.2) }
            .map(\.0).prefix(maxResults).map { $0 }
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

    public func search(_ keyword: String, timeout: TimeInterval = 8) async throws -> (results: [NewRelease], partial: Bool) {
        let listing = try await list(timeout: timeout)
        return (Self.match(listing.items, keyword: keyword), listing.partial)
    }

    public func clearCache() { cache = nil; inflight = nil }
}

// MARK: - Combined search

public struct HongguoSearchResult: Sendable {
    public enum Channel: String, Sendable { case web, app, appNew }
    public var results: [SeriesSummary]
    public var channel: Channel
    public var page: Int
    public var hasMore: Bool
    /// Needed to load page 2+ on the App channel.
    public var appCursor: AppSearchCursor? = nil
    /// Series found through the App new-release list.
    public var newReleaseIds: Set<String> = []
    public var releasedTodayIds: Set<String> = []
    /// Loose queries that were used because the original found no title match.
    public var relaxedQueries: [String] = []
    /// A supplementary search or the primary source did not finish; results may be incomplete.
    public var notice: String = ""
}

/// The hongguo search flow of the Electron app: optional App search first, the website with
/// looser queries, then the App new-release list when no title matches exactly, and App fallbacks
/// when the website fails. Page 2+ stays on the channel page 1 used.
public actor HongguoSearch {
    public static let shared = HongguoSearch()
    static let appCooldown: TimeInterval = 120
    static let newReleaseCooldown: TimeInterval = 30

    public typealias WebSearch = @Sendable (_ keyword: String, _ page: Int) async throws -> SearchPage
    public typealias AppSearch = @Sendable (_ keyword: String, _ page: Int, _ cursor: AppSearchCursor?) async throws -> AppSearchPage
    public typealias NewReleases = @Sendable (_ keyword: String, _ timeout: TimeInterval) async throws -> (results: [NewRelease], partial: Bool)

    private let web: WebSearch
    private let app: AppSearch
    private let newReleases: NewReleases
    private var appCooldownUntil = Date.distantPast
    private var newReleaseCooldownUntil = Date.distantPast

    public init(web: WebSearch? = nil, app: AppSearch? = nil, newReleases: NewReleases? = nil) {
        let webService = SearchService(), appService = AppSearchService()
        self.web = web ?? { try await webService.search($0, page: $1) }
        self.app = app ?? { try await appService.search($0, page: $1, cursor: $2) }
        self.newReleases = newReleases ?? { try await NewReleaseService.shared.search($0, timeout: $1) }
    }

    static func hasTitleMatch(_ items: [SeriesSummary], _ query: String) -> Bool {
        !query.isEmpty && items.contains { SearchText.normalize($0.title).contains(query) }
    }

    static func hasExactMatch(_ items: [SeriesSummary], _ query: String) -> Bool {
        !query.isEmpty && items.contains { SearchText.normalize($0.title) == query }
    }

    private func supplement(_ keyword: String, timeout: TimeInterval) async -> (results: [NewRelease], partial: Bool, checked: Bool, error: String) {
        guard SearchText.normalize(keyword).count >= 2 else { return ([], false, false, "") }
        guard Date() >= newReleaseCooldownUntil else { return ([], false, false, "App 上新补搜暂时不可用，请稍后重试") }
        guard timeout >= 0.9 else { return ([], false, false, "") }
        do {
            let found = try await newReleases(keyword, min(8, timeout))
            newReleaseCooldownUntil = found.partial && found.results.isEmpty ? Date().addingTimeInterval(Self.newReleaseCooldown) : .distantPast
            return (found.results, found.partial, true, found.partial ? "App 上新目录只读取到部分分类" : "")
        } catch {
            newReleaseCooldownUntil = Date().addingTimeInterval(Self.newReleaseCooldown)
            return ([], false, true, (error as? HongguoError)?.message ?? "App 上新补搜失败")
        }
    }

    private func appResult(_ page: AppSearchPage, notice: String = "") -> HongguoSearchResult {
        HongguoSearchResult(results: page.results, channel: .app, page: page.page, hasMore: page.hasMore, appCursor: page.cursor, notice: notice)
    }

    /// - Parameters:
    ///   - appFirst: ask the App search first (default); the website only when it finds nothing.
    ///   - channel/appCursor: from page 1's result when loading more.
    public func search(_ keyword: String, page: Int = 1, appFirst: Bool = true, fuzzy: Bool = true,
                       channel: HongguoSearchResult.Channel? = nil, appCursor: AppSearchCursor? = nil) async throws -> HongguoSearchResult {
        guard (1...50).contains(page) else { throw HongguoError(.input, "搜索页码必须是 1 至 50 的整数") }
        let query = SearchText.normalize(keyword)
        if page > 1 {
            switch channel {
            case .app:
                do {
                    let result = try await app(keyword, page, appCursor)
                    appCooldownUntil = .distantPast
                    return appResult(result)
                } catch {
                    appCooldownUntil = Date().addingTimeInterval(Self.appCooldown)
                    throw error
                }
            case .web:
                let response = try await web(keyword, page)
                return HongguoSearchResult(results: response.results, channel: .web, page: page, hasMore: response.hasMore)
            default:
                throw HongguoError(.input, "该搜索通道不支持加载更多，请重新搜索")
            }
        }
        let appEnabled = appFirst && Date() >= appCooldownUntil
        if appEnabled {
            do {
                let result = try await app(keyword, 1, nil)
                appCooldownUntil = .distantPast
                // Any App result is used; the website search only runs when the App finds nothing.
                if !result.results.isEmpty { return appResult(result) }
            } catch {
                appCooldownUntil = Date().addingTimeInterval(Self.appCooldown)
            }
        }
        do {
            let response = try await web(keyword, 1)
            var results = response.results
            var attempted: [String] = [], errors: [String] = []
            if fuzzy, !Self.hasTitleMatch(results, query) {
                for relaxed in SearchText.relaxedQueries(keyword) {
                    do {
                        let extra = try await web(relaxed, 1)
                        let known = Set(results.map(\.seriesId))
                        results += extra.results.filter { !known.contains($0.seriesId) }
                        attempted.append(relaxed)
                        if Self.hasTitleMatch(results, query) { break }
                    } catch {
                        errors.append((error as? HongguoError)?.message ?? "补搜失败")
                    }
                }
            }
            var out = HongguoSearchResult(results: results, channel: .web, page: 1, hasMore: response.hasMore, relaxedQueries: attempted)
            if fuzzy, query.count >= 2, !Self.hasExactMatch(results, query) {
                // With usable website results the supplement only gets a short extra budget.
                let found = await supplement(keyword, timeout: results.isEmpty ? 8 : 2.5)
                merge(found.results, into: &out)
                if !found.error.isEmpty { errors.append(found.error) }
            }
            if !errors.isEmpty {
                let unique = errors.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "；")
                // No results at all plus a failure must not read as "nothing found".
                if out.results.isEmpty { throw HongguoError(.upstream, "搜索未完成：\(unique)") }
                out.notice = "补充搜索未完成：\(unique)"
            }
            return out
        } catch let error as HongguoError where error.message.hasPrefix("搜索未完成") {
            throw error
        } catch {
            let message = (error as? HongguoError)?.message ?? "搜索失败"
            if (error as? HongguoError)?.kind == .input { throw error }
            if !appEnabled, Date() >= appCooldownUntil {
                do {
                    let result = try await app(keyword, 1, nil)
                    appCooldownUntil = .distantPast
                    if !result.results.isEmpty { return appResult(result, notice: "官网搜索未完成：\(message)；已自动切换 App 搜索") }
                } catch {
                    appCooldownUntil = Date().addingTimeInterval(Self.appCooldown)
                }
            }
            if fuzzy, query.count >= 2 {
                let found = await supplement(keyword, timeout: 8)
                if !found.results.isEmpty {
                    var out = HongguoSearchResult(results: [], channel: .appNew, page: 1, hasMore: false)
                    merge(found.results, into: &out)
                    out.notice = "官网搜索未完成：\(message)；已显示 App 上新补搜结果" + (found.error.isEmpty ? "" : "；App 上新补搜未完成：\(found.error)")
                    return out
                }
                if found.checked, !found.error.isEmpty {
                    throw HongguoError(.upstream, "官网搜索未完成：\(message)；App 上新补搜未完成：\(found.error)")
                }
            }
            throw error
        }
    }

    private func merge(_ releases: [NewRelease], into out: inout HongguoSearchResult) {
        for release in releases {
            let id = release.series.seriesId
            out.newReleaseIds.insert(id)
            if release.releasedToday { out.releasedTodayIds.insert(id) }
            if let at = out.results.firstIndex(where: { $0.seriesId == id }) {
                // The website entry wins field by field; empty ones are filled from the App.
                var existing = out.results[at]
                if existing.cover.isEmpty { existing.cover = release.series.cover }
                if existing.description.isEmpty { existing.description = release.series.description }
                if existing.episodeCount == 0 { existing.episodeCount = release.series.episodeCount }
                out.results[at] = existing
            } else {
                out.results.append(release.series)
            }
        }
    }
}

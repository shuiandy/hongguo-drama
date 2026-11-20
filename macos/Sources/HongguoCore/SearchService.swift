import Foundation

public enum Site {
    public static let origin = "https://hongguoduanju.com"
    public static let referer = origin + "/"
    public static func detailURL(_ seriesId: String) -> URL { URL(string: "\(origin)/detail?series_id=\(seriesId)")! }
    public static func playerURL(_ seriesId: String, _ vid: String? = nil) -> URL {
        URL(string: vid.map { "\(origin)/player/\(seriesId)/\($0)" } ?? "\(origin)/player/\(seriesId)")!
    }
}

/// Short-lived in-memory response cache shared by the services.
actor TTLCache<Value: Sendable> {
    private var entries: [String: (Value, Date)] = [:]
    private var order: [String] = []
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    func get(_ key: String) -> Value? {
        guard let (value, expires) = entries[key], expires > Date() else {
            entries[key] = nil
            return nil
        }
        return value
    }

    func set(_ key: String, _ value: Value, ttl: TimeInterval) {
        if entries[key] == nil { order.append(key) }
        entries[key] = (value, Date().addingTimeInterval(ttl))
        while order.count > limit {
            entries[order.removeFirst()] = nil
        }
    }

    func clear() { entries.removeAll(); order.removeAll() }
}

/// Official website search (`/api/search/result`). Port of `hongguo-search.js`.
public final class SearchService: Sendable {
    public static let endpoint = URL(string: "\(Site.origin)/api/search/result")!
    private let http: HTTPClient
    private let cache = TTLCache<SearchPage>(limit: 30)

    public init(http: HTTPClient = .shared) { self.http = http }

    public static func normalizeKeyword(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func search(_ keyword: String, page: Int = 1) async throws -> SearchPage {
        let kw = Self.normalizeKeyword(keyword)
        guard !kw.isEmpty, kw.count <= 200 else { throw HongguoError(.input, "请输入 1 至 200 字的搜索词") }
        let page = max(1, min(50, page))
        let key = "\(kw)\u{0}\(page)"
        if let cached = await cache.get(key) { return cached }

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "aid", value: "8662"),
            URLQueryItem(name: "query", value: kw),
            URLQueryItem(name: "page", value: String(page)),
        ]
        var options = HTTPClient.Options()
        options.timeout = 10
        options.headers = [
            "User-Agent": UserAgents.web,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": Site.referer,
        ]
        var lastError: Error = HongguoError(.upstream, "搜索失败")
        for attempt in 0...1 {
            do {
                let response = try await http.get(components.url!, options: options)
                var parsed = try Self.parse(response.data)
                parsed.keyword = kw
                await cache.set(key, parsed, ttl: 60)
                return parsed
            } catch let error as HTTPStatusError {
                lastError = HongguoError(error.status == 429 ? .upstream : .upstream,
                                         error.status == 429 ? "搜索请求过于频繁，请稍后重试" : "搜索服务暂不可用（HTTP \(error.status)）")
                if error.status >= 400 && error.status < 500 { break }
            } catch let error as HongguoError where error.kind == .format {
                throw error
            } catch {
                lastError = error
            }
            if attempt == 0 { try await Task.sleep(nanoseconds: 400_000_000) }
        }
        throw lastError
    }

    /// Converts `searchList` into summaries. Exposed for tests.
    public static func parse(_ data: Data) throws -> SearchPage {
        guard !data.isEmpty else { throw HongguoError(.upstream, "搜索响应为空") }
        guard let payload = try? JSONValue.parse(data), let root = payload.object else {
            throw HongguoError(.upstream, "搜索返回了网页内容")
        }
        if let code = root["code"]?.string {
            throw HongguoError(.upstream, "搜索服务暂不可用（\(root["message"]?.string ?? code)）")
        }
        guard let list = root["searchList"]?.array else { throw HongguoError(.format, "搜索返回异常数据") }
        var results: [SeriesSummary] = []
        var seen = Set<String>()
        for item in list {
            let videoData = item["video_data"]
            let video = (videoData.object?.isEmpty == false) ? videoData : item
            let seriesId = (video["series_id"].idString ?? item["series_id"].idString ?? item["keyword"].idString ?? "")
                .trimmingCharacters(in: .whitespaces)
            let rawTitle = video["series_name"].string ?? video["series_title"].string ?? item["name"].string ?? video["title"].string ?? ""
            let title = HTMLData.decodeEntities(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard seriesId.isDigitsOnly, seriesId.count >= 6, !title.isEmpty, !seen.contains(seriesId) else { continue }
            seen.insert(seriesId)
            results.append(SeriesSummary(
                seriesId: seriesId,
                title: title,
                cover: HTMLData.safeCover(video["series_cover"].string ?? video["cover"].string),
                episodeCount: episodeCount(video),
                tags: tags(video),
                description: HTMLData.decodeEntities(video["series_intro"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        if results.isEmpty && !list.isEmpty { throw HongguoError(.format, "搜索返回的条目无法识别") }
        let total = root["totalCount"]?.number.map(Int.init) ?? results.count
        return SearchPage(keyword: "", results: results, total: max(0, total),
                          totalPages: max(0, root["totalPages"]?.number.map(Int.init) ?? 0),
                          page: max(1, root["pageNum"]?.number.map(Int.init) ?? 1),
                          hasMore: root["hasMore"]?.bool == true)
    }

    static func episodeCount(_ video: JSONValue) -> Int {
        if let count = video["episode_cnt"].number, count > 0, count.rounded() == count { return Int(count) }
        let right = video["episode_right_text"].string ?? ""
        if let match = HTMLData.firstMatch("(\\d+)\\s*集", in: right), let n = Int(match[1]) { return n }
        return 0
    }

    static func tags(_ video: JSONValue) -> [String] {
        let list = video["tags"].array ?? video["category_list"].array ?? []
        var tags: [String] = []
        for item in list {
            let label = item.string ?? item["name"].string ?? item["tag_name"].string ?? item["title"].string ?? ""
            let text = label.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty && !tags.contains(text) { tags.append(text) }
            if tags.count >= 4 { break }
        }
        return tags
    }
}

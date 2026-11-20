import Foundation

/// The official website: the series page (episode list, series facts, score, reviews, cast), an
/// episode's player page (its like count), share links and "open the source page" links.
public enum Site {
    public static let origin = "https://hongguoduanju.com"
    public static let referer = origin + "/"
    public static func detailURL(_ seriesId: String) -> URL { URL(string: "\(origin)/detail?series_id=\(seriesId)")! }
    public static func playerURL(_ seriesId: String, _ vid: String? = nil) -> URL {
        URL(string: vid.map { "\(origin)/player/\(seriesId)/\($0)" } ?? "\(origin)/player/\(seriesId)")!
    }
}

/// The website pages' router data, cached for a minute so the detail view, the player overlay and
/// the reviews share one request: the series page (`/detail?series_id=`) and an episode's player
/// page (`/player/<series>/<vid>`, which redirects for episodes the website does not show).
enum SitePages {
    private static let cache = TTLCache<JSONValue>(limit: 64)

    static func seriesPage(_ seriesId: String, http: HTTPClient = .shared) async throws -> JSONValue {
        try await load(key: "s:\(seriesId)", url: Site.detailURL(seriesId), seriesId: seriesId, http: http)
    }

    static func playerPage(_ seriesId: String, vid: String, http: HTTPClient = .shared) async throws -> JSONValue {
        try await load(key: "p:\(seriesId):\(vid)", url: Site.playerURL(seriesId, vid), seriesId: seriesId, http: http)
    }

    private static func load(key: String, url: URL, seriesId: String, http: HTTPClient) async throws -> JSONValue {
        if let cached = await cache.get(key) { return cached }
        var options = HTTPClient.Options()
        options.headers = ["User-Agent": UserAgents.web, "Referer": Site.referer,
                           "Accept": "text/html,application/xhtml+xml", "Accept-Language": "zh-CN,zh;q=0.9"]
        options.timeout = 8
        options.maxRedirects = 0
        let response = try await http.get(url, options: options)
        // With redirects off a 3xx comes back as a response: the website hides this episode.
        if (300...399).contains(response.status) { throw HongguoError(.unavailable, "官网未公开这一集") }
        let data = try loaderData(response.text, seriesId: seriesId)
        await cache.set(key, data, ttl: 60)
        return data
    }

    /// The page's loader entry that carries `seriesDetail` for `seriesId`.
    static func loaderData(_ html: String, seriesId: String) throws -> JSONValue {
        let router = try HTMLData.routerData(html)
        guard let data = (router["loaderData"].object ?? [:]).values.first(where: { !$0["seriesDetail"].isNull && $0["isSuccess"].bool != false }) else {
            throw HongguoError(.format, "来源页面未返回公开剧集信息")
        }
        guard data["seriesDetail"]["series_id"].idString == seriesId else { throw HongguoError(.format, "来源页面剧集不匹配") }
        return data
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

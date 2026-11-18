import Foundation

/// Public comments of one episode ("本集评论"), the fallback when timed danmaku is unavailable.
/// Port of src/native/episode-comments.js + the episode branch of public-details.js: the
/// anonymous player page embeds a preview of the episode's reviews and has no paging API.
public struct EpisodeComments: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        /// sha256 of stable fields; the page has no comment ids.
        public var id: String
        public var content: String
    }
    public var seriesId: String
    public var vid: String
    public var items: [Item]
    public var total: Int?
    public var likeCount: Int?
    /// Always shown: the website only offers part of the comments.
    public var notice: String

    public static let limitedNotice = "官网仅提供本集部分评论，暂未提供可用的公开翻页接口；更多评论请到红果短剧 App 查看。"
}

public final class EpisodeCommentService: Sendable {
    private let http: HTTPClient
    private let cache = TTLCache<EpisodeComments>(limit: 64)

    public init(http: HTTPClient = .shared) { self.http = http }

    public func comments(seriesId: String, vid: String, limit: Int = 30) async throws -> EpisodeComments {
        guard seriesId.matchesDigits(min: 6, max: 30), vid.matchesDigits(min: 6, max: 30), (1...30).contains(limit) else {
            throw HongguoError(.input, "评论请求编号或条数无效")
        }
        let key = "\(seriesId):\(vid):\(limit)"
        if let cached = await cache.get(key) { return cached }
        var options = HTTPClient.Options()
        options.headers = ["User-Agent": UserAgents.web, "Referer": Site.referer,
                           "Accept": "text/html,application/xhtml+xml", "Accept-Language": "zh-CN,zh;q=0.9"]
        options.timeout = 10
        options.maxRedirects = 0
        let response: HTTPResponse
        do {
            response = try await http.get(Site.playerURL(seriesId, vid), options: options)
        } catch let error as HTTPStatusError where error.status == 302 {
            throw HongguoError(.unavailable, "该集在官网需要解锁，暂无公开评论")
        }
        let result = try Self.parse(response.text, seriesId: seriesId, vid: vid, limit: limit)
        await cache.set(key, result, ttl: 30)
        return result
    }

    public static func parse(_ html: String, seriesId: String, vid: String, limit: Int = 30) throws -> EpisodeComments {
        let router = try HTMLData.routerData(html)
        guard let data = (router["loaderData"].object ?? [:]).values.first(where: { !$0["seriesDetail"].isNull && $0["isSuccess"].bool != false }) else {
            throw HongguoError(.format, "来源页面未返回公开剧集信息")
        }
        guard data["seriesDetail"]["series_id"].idString == seriesId else { throw HongguoError(.format, "来源页面剧集不匹配") }
        guard data["vid"].idString == vid else { throw HongguoError(.format, "来源页面分集不匹配") }
        func count(_ value: JSONValue) -> Int? { value.number.flatMap { $0 >= 0 && $0.isFinite ? Int($0) : nil } }
        let social = data["episodeSocialInfo"]
        var seen = Set<String>()
        var items: [EpisodeComments.Item] = []
        for review in social["reviews"]["reviews"].array ?? [] {
            guard let raw = review["content"].string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let content = String(raw.prefix(20000))
            let author = String((review["user_name"].string ?? "").prefix(200))
            let created = count(review["create_time"]).map { $0 < 1_000_000_000_000 ? $0 * 1000 : $0 }
            let id = DownloadNaming.sha256Prefix("\(seriesId)\u{0}\(vid)\u{0}\(author)\u{0}\(created.map(String.init) ?? "")\u{0}\(content)", 64)
            guard seen.insert(id).inserted else { continue }
            items.append(.init(id: id, content: content))
            if items.count >= limit { break }
        }
        return EpisodeComments(seriesId: seriesId, vid: vid, items: items, total: count(social["reviews"]["total_count"]),
                               likeCount: count(social["episode_like_count"]), notice: EpisodeComments.limitedNotice)
    }
}

import Foundation

/// One episode and its series: the episode's comments (author, date, likes, paged) from the App
/// comment API, its like count and the series' facts and collect count from the App series detail
/// (`OfficialSeriesDetail`), and tags, cast and first-shown date from the website's series page.
/// Read-only.
public struct EpisodeSocial: Sendable, Equatable {
    public struct Comment: Sendable, Equatable, Identifiable {
        public var id: String
        public var author: String
        public var avatar: String
        public var content: String
        public var createdAt: Date?
        public var likes: Int
        /// Series reviews carry a score out of 10; episode comments do not.
        public var rating: Int?

        public init(id: String, author: String, avatar: String, content: String, createdAt: Date?, likes: Int, rating: Int? = nil) {
            self.id = id; self.author = author; self.avatar = avatar; self.content = content
            self.createdAt = createdAt; self.likes = likes; self.rating = rating
        }
    }

    public struct CastMember: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var role: String
        public var avatar: String
    }

    public var seriesId: String
    public var vid: String
    public var title: String
    public var cover: String
    public var intro: String
    public var episodeCount: Int
    public var tags: [String]
    public var cast: [CastMember]
    public var firstShown: Date?
    public var favoriteCount: Int?
    public var comments: [Comment]
    /// How many comments the service counts for the episode; far more than one page carries.
    public var commentTotal: Int?
    public var episodeLikes: Int?
    /// Pagination cursor for loading additional comments from the App comment API.
    public var nextCursor: String
    public var hasMoreComments: Bool

    public init(seriesId: String, vid: String, title: String, cover: String, intro: String, episodeCount: Int, tags: [String],
                cast: [CastMember], firstShown: Date?, favoriteCount: Int?, comments: [Comment], commentTotal: Int?, episodeLikes: Int?,
                nextCursor: String = "", hasMoreComments: Bool = false) {
        self.seriesId = seriesId; self.vid = vid; self.title = title; self.cover = cover; self.intro = intro
        self.episodeCount = episodeCount; self.tags = tags; self.cast = cast; self.firstShown = firstShown
        self.favoriteCount = favoriteCount; self.comments = comments; self.commentTotal = commentTotal; self.episodeLikes = episodeLikes
        self.nextCursor = nextCursor; self.hasMoreComments = hasMoreComments
    }
}

/// The score, how many rated it, the heat text, the first few reviews with their scores and the
/// cast from the public series page (`/detail?series_id=`), plus the collect count and filing
/// number from the App series detail. Read-only, signed out.
public struct SeriesReviews: Sendable, Equatable {
    public var rating: Double?
    public var ratingCount: Int?
    public var heatText: String
    public var favoriteCount: Int?
    public var reviews: [EpisodeSocial.Comment]
    public var reviewTotal: Int?
    /// The series' filing number as the page prints it (`record_number`), "" when it has none.
    public var recordNumber = ""
    /// The cast as the page lists it (`seriesDetail.celebrities`), empty when it has none.
    public var cast: [EpisodeSocial.CastMember] = []

    public init(rating: Double?, ratingCount: Int?, heatText: String, favoriteCount: Int?, reviews: [EpisodeSocial.Comment], reviewTotal: Int?) {
        self.rating = rating; self.ratingCount = ratingCount; self.heatText = heatText
        self.favoriteCount = favoriteCount; self.reviews = reviews; self.reviewTotal = reviewTotal
    }
}

public enum EpisodeSocialService {
    /// Score, rating count, heat, the first reviews and the cast from the website's series page
    /// (shared one-minute cache with `load` and `SeriesService`); the collect count and filing number
    /// from the App series detail (nil and "" when it did not answer).
    public static func reviews(seriesId: String, http: HTTPClient = .shared) async throws -> SeriesReviews {
        guard seriesId.matchesDigits(min: 6, max: 30) else { throw HongguoError(.input, "剧集编号无效") }
        async let detail = try? OfficialSeriesDetail.load(seriesId, http: http)
        let page = try await SitePages.seriesPage(seriesId, http: http)
        return reviews(from: page, detail: await detail)
    }

    public static func parseReviews(_ html: String, seriesId: String) throws -> SeriesReviews {
        reviews(from: try SitePages.loaderData(html, seriesId: seriesId), detail: nil)
    }

    static func reviews(from data: JSONValue, detail: OfficialSeriesDetail?) -> SeriesReviews {
        let social = data["seriesSocialInfo"]
        let score = social["rating"].number ?? social["rating"].string.flatMap(Double.init)
        var result = SeriesReviews(
            rating: score.flatMap { $0 > 0 && $0 <= 10 ? $0 : nil },
            ratingCount: integer(social["rating_count"]),
            heatText: social["hot_score_data"]["text"].string ?? "",
            favoriteCount: detail?.favoriteCount,
            reviews: comments(social["reviews"]["reviews"]),
            reviewTotal: integer(social["reviews"]["total_count"]))
        result.recordNumber = detail?.recordNumber ?? ""
        result.cast = cast(data["seriesDetail"]["celebrities"])
        return result
    }

    static func comments(_ list: JSONValue) -> [EpisodeSocial.Comment] {
        var seen = Set<String>()
        var comments: [EpisodeSocial.Comment] = []
        for review in list.array ?? [] {
            guard let raw = review["content"].string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let author = String((review["user_name"].string ?? "").prefix(200))
            let created = date(review["create_time"])
            let content = String(raw.prefix(20000))
            let id = DownloadNaming.sha256Prefix("\(author)\u{0}\(created?.timeIntervalSince1970 ?? 0)\u{0}\(content)", 32)
            guard seen.insert(id).inserted else { continue }
            comments.append(.init(id: id, author: author, avatar: secure(review["user_avatar"].string ?? ""), content: content,
                                  createdAt: created, likes: integer(review["digg_count"]) ?? 0,
                                  rating: integer(review["rating"]).flatMap { (1...10).contains($0) ? $0 : nil }))
        }
        return comments
    }

    public struct CommentPage: Sendable, Equatable {
        public var comments: [EpisodeSocial.Comment]
        public var total: Int?
        public var cursor: String
        public var hasMore: Bool
        public init(comments: [EpisodeSocial.Comment], total: Int?, cursor: String, hasMore: Bool) {
            self.comments = comments; self.total = total; self.cursor = cursor; self.hasMore = hasMore
        }
    }

    private static let cache = TTLCache<EpisodeSocial>(limit: 64)

    /// One episode's social panel: series facts, collect count and the episode's like count from the
    /// App series detail, tags, cast and first-shown date from the website's series page, and the
    /// first page of comments from the App comment API. Throws only when neither the App detail nor
    /// the comments answered.
    public static func load(seriesId: String, vid: String, http: HTTPClient = .shared) async throws -> EpisodeSocial {
        guard seriesId.matchesDigits(min: 6, max: 30), vid.matchesDigits(min: 6, max: 30) else {
            throw HongguoError(.input, "剧集编号无效")
        }
        let key = "\(seriesId):\(vid)"
        if let cached = await cache.get(key) { return cached }

        async let detailTask = try? OfficialSeriesDetail.load(seriesId, http: http)
        async let seriesTask = try? SitePages.seriesPage(seriesId, http: http)
        async let commentsTask = try? commentsPage(seriesId: seriesId, vid: vid, cursor: "", count: 20, http: http)
        let detail = await detailTask
        let series = await seriesTask
        let appComments = await commentsTask
        guard detail != nil || appComments != nil else {
            throw HongguoError(.unavailable, "剧集信息和评论暂时取不到，请稍后重试")
        }
        let result = social(seriesId: seriesId, vid: vid, detail: detail, series: series ?? .null, comments: appComments)
        await cache.set(key, result, ttl: 60)
        return result
    }

    static func social(seriesId: String, vid: String, detail: OfficialSeriesDetail?, series: JSONValue, comments page: CommentPage?) -> EpisodeSocial {
        let web = series["seriesDetail"]
        return EpisodeSocial(
            seriesId: seriesId,
            vid: vid,
            title: detail?.title ?? "",
            cover: secure(detail?.cover ?? ""),
            intro: detail?.intro ?? "",
            episodeCount: detail?.episodeCount ?? 0,
            tags: (web["tags"].array ?? []).compactMap { $0.string ?? $0["name"].string },
            cast: cast(web["celebrities"]),
            firstShown: date(web["first_visible_time"]),
            favoriteCount: detail?.favoriteCount,
            comments: page?.comments ?? [],
            commentTotal: page?.total,
            episodeLikes: detail?.likes(vid: vid),
            nextCursor: page?.cursor ?? "",
            hasMoreComments: page?.hasMore ?? false
        )
    }

    /// Fetches one page of episode comments from the official App comment API
    /// (`/novel/commentapi/comment/list/<vid>/v1/`, `comment_source=4, server_channel=18, comment_type=4`).
    public static func commentsPage(
        seriesId: String,
        vid: String,
        cursor: String = "",
        count: Int = 20,
        http: HTTPClient = .shared
    ) async throws -> CommentPage {
        guard seriesId.matchesDigits(min: 6, max: 30), vid.matchesDigits(min: 6, max: 30) else {
            throw HongguoError(.input, "剧集编号无效")
        }
        let stampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let stamp = stampMs / 1000
        let device = try await PersistentAppDevice.dataIdentity(transport: AppTransport(http: http)).identity
        let rawQuery = DanmakuSigner.buildQuery(stampMs: stampMs, deviceId: device.deviceId, installId: device.iid)
        guard let url = URL(string: "https://api5-normal-sinfonlineb.fqnovel.com/novel/commentapi/comment/list/\(vid)/v1/?\(rawQuery)") else {
            throw HongguoError(.input, "评论请求地址无效")
        }
        let signHeaders = try DanmakuSigner.headers(rawQuery: rawQuery, stamp: stamp, nonce: AppCrypto.randomBytes(DanmakuSigner.nonceBytes))
        var options = HTTPClient.Options()
        options.timeout = 8
        let headers: [(String, String)] = [
            ("User-Agent", DanmakuService.userAgent), ("Accept", "application/json"),
            ("X-XS-From-Web", "0"), ("Sdk-Version", "2"),
            ("Content-Type", "application/json; charset=utf-8"),
            ("Comment-Source", "4"), ("Server-Channel", "18"),
        ] + signHeaders + PersistentAppDevice.authHeaders()
        for (k, v) in headers { options.headers[k] = v }
        let bodyObj: [String: Any] = [
            "comment_source": 4, "server_channel": 18, "group_id": vid, "group_type": 30,
            "comment_type": 4, "sort": 1, "count": count, "cursor": cursor,
            "aid": 8662, "compliance_status": 0,
            "business_param": ["book_id": seriesId],
        ]
        let rawBody = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])
        let resp = try await http.post(url, json: rawBody, options: options)
        guard let payload = try? JSONValue.parse(resp.data), Int(payload["code"].number ?? -1) == 0 else {
            throw HongguoError(.upstream, "评论接口暂时不可用")
        }
        let data = payload["data"]
        var seen = Set<String>()
        var parsed: [EpisodeSocial.Comment] = []
        for row in data["data_list"].array ?? [] {
            let c = row["comment"]
            let common = c["common"]
            guard let rawText = common["content"]["text"].string,
                  !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let base = common["user_info"]["base_info"]
            let author = String((base["user_name"].string ?? "").prefix(200))
            let rawAvatar = [base["user_avatar"].string, base["expand_user_avatar"].string]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let created = date(common["create_timestamp"])
            let content = String(rawText.prefix(20000))
            let cid = c["comment_id"].idString ?? DownloadNaming.sha256Prefix("\(author)\u{0}\(created?.timeIntervalSince1970 ?? 0)\u{0}\(content)", 32)
            guard seen.insert(cid).inserted else { continue }
            parsed.append(.init(
                id: cid,
                author: author,
                avatar: secure(rawAvatar),
                content: content,
                createdAt: created,
                likes: integer(c["stat"]["digg_count"]) ?? 0
            ))
        }
        let listInfo = data["common_list_info"]
        let nextCursor = listInfo["cursor"].string ?? ""
        let hasMore = listInfo["has_more"].bool == true && !nextCursor.isEmpty && !parsed.isEmpty
        return CommentPage(
            comments: parsed,
            total: integer(listInfo["total"]),
            cursor: nextCursor,
            hasMore: hasMore
        )
    }

    /// Counts and times arrive as numbers or as digit strings.
    static func integer(_ value: JSONValue) -> Int? {
        if let number = value.number, number.isFinite, number >= 0 { return Int(number) }
        if let text = value.string, let parsed = Int(text), parsed >= 0 { return parsed }
        return nil
    }

    static func date(_ value: JSONValue) -> Date? {
        guard let raw = integer(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(raw > 1_000_000_000_000 ? raw / 1000 : raw))
    }

    /// The page gives some images as http; the app only loads https.
    static func secure(_ url: String) -> String {
        url.hasPrefix("http://") ? "https://" + url.dropFirst(7) : url
    }

    /// The page's `celebrities` list.
    static func cast(_ list: JSONValue) -> [EpisodeSocial.CastMember] {
        (list.array ?? []).compactMap { person -> EpisodeSocial.CastMember? in
            guard let name = person["nickname"].string, !name.isEmpty else { return nil }
            return .init(id: person["celebrity_id"].idString ?? name, name: name, role: person["sub_title"].string ?? "",
                         avatar: secure(person["avatar"].string ?? ""))
        }
    }
}

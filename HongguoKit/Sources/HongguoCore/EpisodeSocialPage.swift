import Foundation

/// One episode and its series: the episode's comments (author, date, likes, paged) from the App
/// comment API; its like count, the series' facts, collect count, cast and tags from the App series
/// detail (`OfficialSeriesDetail`); the first-shown date from the App's book_pack_fields read
/// (`OfficialSeriesStats`). Read-only.
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

    public struct CastMember: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var role: String
        public var avatar: String
        /// The actor's own introduction, "" when there is none.
        public var intro: String = ""
        /// `encrypted_celebrity_id`, the key of the actor works read; "" when the reply has none.
        public var encryptedId: String = ""
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

/// The score, how many rated it, the review count and the first page of reviews with their scores
/// from the App comment list (`OfficialSeriesReviews`); the heat from the App's book_pack_fields read
/// (`OfficialSeriesStats`); the collect count, filing number and cast from the App series detail.
/// Read-only, signed out.
public struct SeriesReviews: Sendable, Equatable {
    public var rating: Double?
    public var ratingCount: Int?
    public var heatText: String
    public var favoriteCount: Int?
    public var reviews: [EpisodeSocial.Comment]
    public var reviewTotal: Int?
    /// The series' filing number (`record_info.record_number`), "" when it has none.
    public var recordNumber = ""
    /// The cast (`celebrities`), empty when it has none.
    public var cast: [EpisodeSocial.CastMember] = []
    /// Cursor for `EpisodeSocialService.moreReviews`.
    public var nextCursor = ""
    public var hasMoreReviews = false

    public init(rating: Double?, ratingCount: Int?, heatText: String, favoriteCount: Int?, reviews: [EpisodeSocial.Comment], reviewTotal: Int?) {
        self.rating = rating; self.ratingCount = ratingCount; self.heatText = heatText
        self.favoriteCount = favoriteCount; self.reviews = reviews; self.reviewTotal = reviewTotal
    }
}

public enum EpisodeSocialService {
    /// Score, rating count, review count and the first reviews from the App comment list (required);
    /// heat from the App's book_pack_fields read, the collect count, filing number and cast from the
    /// App series detail (left empty when either did not answer).
    public static func reviews(seriesId: String, http: HTTPClient = .shared) async throws -> SeriesReviews {
        guard seriesId.matchesDigits(min: 6, max: 30) else { throw HongguoError(.input, "剧集编号无效") }
        async let detail = try? OfficialSeriesDetail.load(seriesId, http: http)
        async let stats = try? OfficialSeriesStats.load(seriesId, http: http)
        let list = try await OfficialSeriesReviews.load(seriesId, http: http)
        return reviews(from: list, detail: await detail, stats: await stats)
    }

    /// The next page of written reviews after `cursor` (`SeriesReviews.nextCursor`).
    public static func moreReviews(seriesId: String, cursor: String, count: Int = 10, http: HTTPClient = .shared) async throws -> CommentPage {
        guard seriesId.matchesDigits(min: 6, max: 30), !cursor.isEmpty else { throw HongguoError(.input, "剧评翻页参数无效") }
        return try await OfficialSeriesReviews.load(seriesId, cursor: cursor, count: count, http: http).page
    }

    static func reviews(from list: OfficialSeriesReviews, detail: OfficialSeriesDetail?, stats: OfficialSeriesStats?) -> SeriesReviews {
        var result = SeriesReviews(
            rating: list.rating,
            ratingCount: list.ratingCount,
            heatText: stats?.heatText ?? "",
            favoriteCount: detail?.favoriteCount,
            reviews: list.page.comments,
            reviewTotal: list.page.total)
        result.recordNumber = detail?.recordNumber ?? ""
        result.cast = detail?.cast ?? []
        result.nextCursor = list.page.cursor
        result.hasMoreReviews = list.page.hasMore
        return result
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

    /// One episode's social panel: series facts, collect count, cast, tags and the episode's like
    /// count from the App series detail, the first-shown date from the App's book_pack_fields read,
    /// and the first page of comments from the App comment API. Throws only when neither the App
    /// detail nor the comments answered.
    public static func load(seriesId: String, vid: String, http: HTTPClient = .shared) async throws -> EpisodeSocial {
        guard seriesId.matchesDigits(min: 6, max: 30), vid.matchesDigits(min: 6, max: 30) else {
            throw HongguoError(.input, "剧集编号无效")
        }
        let key = "\(seriesId):\(vid)"
        if let cached = await cache.get(key) { return cached }

        async let detailTask = try? OfficialSeriesDetail.load(seriesId, http: http)
        async let statsTask = try? OfficialSeriesStats.load(seriesId, http: http)
        async let commentsTask = try? commentsPage(seriesId: seriesId, vid: vid, cursor: "", count: 20, http: http)
        let detail = await detailTask
        let stats = await statsTask
        let appComments = await commentsTask
        guard detail != nil || appComments != nil else {
            throw HongguoError(.unavailable, "剧集信息和评论暂时取不到，请稍后重试")
        }
        let result = social(seriesId: seriesId, vid: vid, detail: detail, stats: stats, comments: appComments)
        await cache.set(key, result, ttl: 60)
        return result
    }

    static func social(seriesId: String, vid: String, detail: OfficialSeriesDetail?, stats: OfficialSeriesStats?,
                       comments page: CommentPage?) -> EpisodeSocial {
        EpisodeSocial(
            seriesId: seriesId,
            vid: vid,
            title: detail?.title ?? "",
            cover: secure(detail?.cover ?? ""),
            intro: detail?.intro ?? "",
            episodeCount: detail?.episodeCount ?? 0,
            tags: detail?.tags ?? [],
            cast: detail?.cast ?? [],
            firstShown: stats?.publishedAt,
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
        let payload = try await AppCommentClient.post("/novel/commentapi/comment/list/\(vid)/v1/", body: [
            "comment_source": 4, "server_channel": 18, "group_id": vid, "group_type": 30,
            "comment_type": 4, "sort": 1, "count": count, "cursor": cursor,
            "aid": 8662, "compliance_status": 0,
            "business_param": ["book_id": seriesId],
        ], headers: [("Comment-Source", "4"), ("Server-Channel", "18")] + PersistentAppDevice.authHeaders(), http: http)
        guard Int(payload["code"].number ?? -1) == 0 else { throw HongguoError(.upstream, "评论接口暂时不可用") }
        return commentPage(from: payload["data"])
    }

    /// One page of the App comment list (`data`): episode comments, or series reviews with their
    /// score out of 10 (`comment.expand.score`).
    static func commentPage(from data: JSONValue) -> CommentPage {
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
            let score = integer(c["expand"]["score"]) ?? integer(common["expand"]["score"])
            parsed.append(.init(
                id: cid,
                author: author,
                avatar: secure(rawAvatar),
                content: content,
                createdAt: created,
                likes: integer(c["stat"]["digg_count"]) ?? 0,
                rating: score.flatMap { (1...10).contains($0) ? $0 : nil }
            ))
        }
        let listInfo = data["common_list_info"]
        let nextCursor = listInfo["cursor"].string ?? listInfo["cursor"].idString ?? ""
        let hasMore = listInfo["has_more"].bool == true && !nextCursor.isEmpty && !parsed.isEmpty
        return CommentPage(comments: parsed, total: integer(listInfo["total"]), cursor: nextCursor, hasMore: hasMore)
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

    /// Some images arrive as http; the app only loads https.
    static func secure(_ url: String) -> String {
        url.hasPrefix("http://") ? "https://" + url.dropFirst(7) : url
    }

    /// A `celebrities` list: the role is `sub_title` (饰 林小满), else `role_name`.
    static func cast(_ list: JSONValue) -> [EpisodeSocial.CastMember] {
        var seen = Set<String>()
        return (list.array ?? []).compactMap { person -> EpisodeSocial.CastMember? in
            guard let name = person["nickname"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let id = person["celebrity_id"].idString ?? name
            guard seen.insert(id).inserted else { return nil }
            let subtitle = (person["sub_title"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(id: id, name: name, role: subtitle.isEmpty ? (person["role_name"].string ?? "") : subtitle,
                         avatar: secure(person["avatar"].string ?? ""),
                         intro: String((person["intro"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)),
                         encryptedId: (person["encrypted_celebrity_id"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

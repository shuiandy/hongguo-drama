import Foundation

/// One episode and its series as the App reports them: the episode's comments (author, date,
/// likes, paged), its like count, and the series' facts from the App detail request. Read-only.
/// `cast` is always empty here; the cast comes with `SeriesReviews` (the series page).
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

/// What the public series page (`/detail?series_id=`) says: the score, how many rated it, the
/// heat text, the first few reviews with their scores and the cast. Read-only, anonymous. The
/// only data still read from the website (score and written reviews have no App equivalent).
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
    private static let reviewCache = TTLCache<SeriesReviews>(limit: 64)

    public static func reviews(seriesId: String, http: HTTPClient = .shared) async throws -> SeriesReviews {
        guard seriesId.matchesDigits(min: 6, max: 30) else { throw HongguoError(.input, "剧集编号无效") }
        if let cached = await reviewCache.get(seriesId) { return cached }
        async let appTask = try? fetchAppSeriesDetail(seriesId: seriesId, http: http)
        async let webTask: Result<SeriesReviews, Error> = {
            do { return .success(try await loadWebReviews(seriesId: seriesId, http: http)) }
            catch { return .failure(error) }
        }()
        let appDetail = await appTask
        let webResult = await webTask
        // Score, reviews and cast come only from the series page; heat, collect count and filing
        // number only from the App detail. Neither fills in for the other.
        if case .failure(let webError) = webResult, appDetail == nil { throw webError }
        let web = try? webResult.get()
        var result = SeriesReviews(rating: web?.rating, ratingCount: web?.ratingCount,
                                   heatText: appDetail?.heatText ?? "", favoriteCount: appDetail?.favoriteCount,
                                   reviews: web?.reviews ?? [], reviewTotal: web?.reviewTotal)
        result.recordNumber = appDetail?.recordNumber ?? ""
        result.cast = web?.cast ?? []
        await reviewCache.set(seriesId, result, ttl: 60)
        return result
    }

    private static func loadWebReviews(seriesId: String, http: HTTPClient) async throws -> SeriesReviews {
        var options = HTTPClient.Options()
        options.headers = ["User-Agent": UserAgents.web, "Referer": Site.referer,
                           "Accept": "text/html,application/xhtml+xml", "Accept-Language": "zh-CN,zh;q=0.9"]
        options.timeout = 6
        let response = try await http.get(Site.detailURL(seriesId), options: options)
        return try parseReviews(response.text, seriesId: seriesId)
    }

    public static func parseReviews(_ html: String, seriesId: String) throws -> SeriesReviews {
        let router = try HTMLData.routerData(html)
        guard let data = (router["loaderData"].object ?? [:]).values.first(where: { !$0["seriesDetail"].isNull && $0["isSuccess"].bool != false }) else {
            throw HongguoError(.format, "来源页面未返回公开剧集信息")
        }
        guard data["seriesDetail"]["series_id"].idString == seriesId else { throw HongguoError(.format, "来源页面剧集不匹配") }
        let social = data["seriesSocialInfo"]
        let score = social["rating"].number ?? social["rating"].string.flatMap(Double.init)
        var result = SeriesReviews(
            rating: score.flatMap { $0 > 0 && $0 <= 10 ? $0 : nil },
            ratingCount: integer(social["rating_count"]),
            heatText: social["hot_score_data"]["text"].string ?? "",
            favoriteCount: integer(social["series_favorite_count"]),
            reviews: comments(social["reviews"]["reviews"]),
            reviewTotal: integer(social["reviews"]["total_count"]))
        let record = (data["seriesDetail"]["record_number"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if record.count <= 80 { result.recordNumber = record }
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

    private struct AppSeriesDetail: Sendable {
        struct EpisodeCounts: Sendable {
            var likes: Int?
            var comments: Int?
        }
        var title: String
        var cover: String
        var intro: String
        var episodeCount: Int
        var tags: [String]
        var firstShown: Date?
        var favoriteCount: Int?
        var heatText: String
        var recordNumber: String
        var episodeList: [Episode]
        var episodes: [String: EpisodeCounts]
    }

    private static let cache = TTLCache<EpisodeSocial>(limit: 64)
    private static let seriesDetailCache = TTLCache<AppSeriesDetail>(limit: 32)

    public static func load(seriesId: String, vid: String, http: HTTPClient = .shared) async throws -> EpisodeSocial {
        guard seriesId.matchesDigits(min: 6, max: 30), vid.matchesDigits(min: 6, max: 30) else {
            throw HongguoError(.input, "剧集编号无效")
        }
        let key = "\(seriesId):\(vid)"
        if let cached = await cache.get(key) { return cached }

        async let detailTask = try? fetchAppSeriesDetail(seriesId: seriesId, http: http)
        async let commentsTask = try? commentsPage(seriesId: seriesId, vid: vid, cursor: "", count: 20, http: http)
        let appDetail = await detailTask
        let appComments = await commentsTask
        guard appDetail != nil || appComments != nil else {
            throw HongguoError(.unavailable, "App 剧集信息和评论暂时取不到，请稍后重试")
        }
        let epCounts = appDetail?.episodes[vid]
        let result = EpisodeSocial(
            seriesId: seriesId,
            vid: vid,
            title: appDetail?.title ?? "",
            cover: appDetail?.cover ?? "",
            intro: appDetail?.intro ?? "",
            episodeCount: appDetail?.episodeCount ?? 0,
            tags: appDetail?.tags ?? [],
            cast: [],
            firstShown: appDetail?.firstShown,
            favoriteCount: appDetail?.favoriteCount,
            comments: appComments?.comments ?? [],
            commentTotal: appComments?.total ?? epCounts?.comments,
            episodeLikes: epCounts?.likes,
            nextCursor: appComments?.cursor ?? "",
            hasMoreComments: appComments?.hasMore ?? false
        )
        await cache.set(key, result, ttl: 60)
        return result
    }

    /// Fetches series-level favorite count + every episode's like & comment count in one signed
    /// App request (`/novel/player/multi_video_detail/v1/`), cached per series for 5 minutes.
    private static func fetchAppSeriesDetail(seriesId: String, http: HTTPClient) async throws -> AppSeriesDetail {
        if let cached = await seriesDetailCache.get(seriesId) { return cached }
        let transport = AppTransport(http: http)
        // The persistent device, its token and the login Cookie, with the official iOS 7.4.3 profile.
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
        let extra: [(String, String)] = [("x-ss-dp", "8662"), ("sdk-version", "2")] + dToken + PersistentAppDevice.authHeaders()
        let bodyObj: [String: Any] = [
            "biz_param": [
                "detail_page_version": 0, "disable_digg_stat": false,
                "need_all_video_definition": false, "need_mp4_align": false,
                "source": 7, "use_os_player": false, "use_server_dns": false,
            ],
            "dr_scene": "player",
            "series_id": seriesId,
        ]
        let payload = try AppCrypto.gzip(Array(try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let signed = try PlaybackSignerV5.shared.sign(
            base: "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_detail/v1/",
            values: AppSource.iosProfile + [("iid", identity.iid), ("cdid", identity.cdid), ("device_id", identity.deviceId)],
            body: payload,
            nowMillis: now
        )
        let j = try await transport.requestJSON(
            signed.url, method: "POST",
            headers: signed.headers + [
                ("User-Agent", AppSource.iosPlayerUA), ("Accept", "application/json"),
                ("Content-Type", "application/json; charset=utf-8"), ("Content-Encoding", "gzip"),
            ] + extra,
            body: payload, deadline: Date().addingTimeInterval(10)
        )
        guard Int(j["code"].number ?? -1) == 0 else {
            throw HongguoError(.upstream, "剧集详情接口暂时不可用")
        }
        let vd = j["data"][seriesId]["video_data"]
        guard vd.object != nil else { throw HongguoError(.format, "剧集详情格式异常") }
        if let sid = vd["series_id"].idString, !sid.isEmpty, sid != seriesId {
            throw HongguoError(.format, "剧集详情与请求不一致")
        }
        var episodeMap: [String: AppSeriesDetail.EpisodeCounts] = [:]
        var episodeList: [Episode] = []
        var seenVids = Set<String>()
        let videoList = vd["video_list"].array ?? []
        for (offset, item) in videoList.enumerated() {
            guard let itemVid = item["vid"].idString, itemVid.matchesDigits(min: 1, max: 30) else { continue }
            if let itemSid = item["series_id"].idString, !itemSid.isEmpty, itemSid != seriesId { continue }
            episodeMap[itemVid] = AppSeriesDetail.EpisodeCounts(
                likes: integer(item["digged_count"]),
                comments: integer(item["comment_count"])
            )
            guard seenVids.insert(itemVid).inserted else { continue }
            let idx = integer(item["vid_index"]).flatMap { $0 > 0 ? $0 : nil } ?? (offset + 1)
            episodeList.append(Episode(
                vid: itemVid,
                index: idx,
                title: item["title"].string ?? "",
                seriesId: seriesId,
                webAvailable: nil
            ))
        }
        episodeList.sort { $0.index < $1.index }

        let secondaryInfos = vd["secondary_infos"].array ?? []
        let secondaryTags = secondaryInfos
            .filter { Int($0["data_type"].number ?? 0) == 3 }
            .compactMap { $0["content"].string }
        let rawTags = secondaryTags
            + (vd["abstract_tags"].array ?? []).compactMap { $0.string ?? $0["text"].string ?? $0["content"].string }
            + (vd["rec_tags"].array ?? []).compactMap { $0.string ?? $0["text"].string ?? $0["content"].string }
        var seenTags = Set<String>()
        let cleanTags = rawTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 16 && seenTags.insert($0).inserted }

        let heatText: String = {
            if let info = secondaryInfos.first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string {
                let cleaned = info.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned.contains("热度") ? cleaned : "\(cleaned)热度" }
            }
            if let score = integer(vd["hot_score"]), score > 0 {
                return score >= 10_000 ? "\(score / 10_000)万热度" : "\(score)热度"
            }
            return ""
        }()
        let rawRecord = (vd["record_info"]["record_number"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recordNumber = rawRecord.count <= 80 ? rawRecord : ""

        let detail = AppSeriesDetail(
            title: vd["series_title"].string ?? "",
            cover: secure(HTMLData.safeCover(vd["series_cover"].string ?? "")),
            intro: vd["series_intro"].string ?? "",
            episodeCount: integer(vd["episode_cnt"]) ?? episodeList.count,
            tags: cleanTags,
            firstShown: date(vd["create_time"]),
            favoriteCount: integer(vd["followed_cnt"]),
            heatText: heatText,
            recordNumber: recordNumber,
            episodeList: episodeList,
            episodes: episodeMap
        )
        await seriesDetailCache.set(seriesId, detail, ttl: 300)
        return detail
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

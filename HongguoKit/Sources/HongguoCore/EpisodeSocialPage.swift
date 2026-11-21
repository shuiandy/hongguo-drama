import Foundation

/// One episode and its series: the episode's comments (author, date, likes, paged) from the App
/// comment API; its like count, the series' facts, collect count, cast and tags from the App series
/// detail (`OfficialSeriesDetail`); the first-shown date from the App's book_pack_fields read
/// (`OfficialSeriesStats`). Read-only.
public struct EpisodeSocial: Sendable, Equatable {
    public struct CommentImage: Sendable, Equatable, Hashable {
        public var url: String
        public var thumbnailUrl: String
        public var width: Int
        public var height: Int
        public var format: String

        public init(url: String, thumbnailUrl: String = "", width: Int = 0, height: Int = 0, format: String = "jpeg") {
            self.url = url
            self.thumbnailUrl = thumbnailUrl.isEmpty ? url : thumbnailUrl
            self.width = width
            self.height = height
            self.format = format
        }
    }

    public struct Comment: Sendable, Equatable, Identifiable {
        public var id: String
        public var author: String
        public var avatar: String
        public var content: String
        public var createdAt: Date?
        public var likes: Int
        /// Series reviews carry a score out of 10; episode comments do not.
        public var rating: Int?
        /// Number of replies on this comment (`stat.reply_count`).
        public var replyCount: Int
        /// Images attached to the comment (`content.image_data_list.image_data`).
        public var images: [CommentImage]

        public init(
            id: String,
            author: String,
            avatar: String,
            content: String,
            createdAt: Date?,
            likes: Int,
            rating: Int? = nil,
            replyCount: Int = 0,
            images: [CommentImage] = []
        ) {
            self.id = id; self.author = author; self.avatar = avatar; self.content = content
            self.createdAt = createdAt; self.likes = likes; self.rating = rating
            self.replyCount = replyCount; self.images = images
        }
    }

    public struct Reply: Sendable, Equatable, Identifiable {
        public var id: String
        public var author: String
        public var avatar: String
        public var content: String
        public var createdAt: Date?
        public var likes: Int
        /// Nickname of the user being replied to when replying to another reply; "" for direct replies to the comment.
        public var replyToAuthor: String

        public init(id: String, author: String, avatar: String, content: String, createdAt: Date?, likes: Int, replyToAuthor: String = "") {
            self.id = id; self.author = author; self.avatar = avatar; self.content = content
            self.createdAt = createdAt; self.likes = likes; self.replyToAuthor = replyToAuthor
        }
    }

    public struct CastMember: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var role: String
        public var avatar: String
        /// The actor's own introduction, "" when there is none.
        public var intro: String = ""
        /// `encrypted_celebrity_id`, the key of the official actor panel's works read
        /// (`/reading/user/celebrity/works/v1/`, not used: the home page has more); "" when none.
        public var encryptedId: String = ""
        /// The actor's own 红果 account (`uid` in `schema`, `sslocal://guest_profile?uid=…`), whose
        /// user profile is the official actor home page; "" when the entry has none.
        public var profileUserId: String = ""
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

    public struct ReplyPage: Sendable, Equatable {
        public var replies: [EpisodeSocial.Reply]
        public var total: Int?
        public var cursor: String
        public var hasMore: Bool
        public init(replies: [EpisodeSocial.Reply], total: Int?, cursor: String, hasMore: Bool) {
            self.replies = replies; self.total = total; self.cursor = cursor; self.hasMore = hasMore
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
        if detail != nil && appComments != nil {
            await cache.set(key, result, ttl: 60)
        }
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
        let rawList = data["data_list"].array ?? []
        var seen = Set<String>()
        var parsed: [EpisodeSocial.Comment] = []
        for row in rawList {
            guard let item = parseComment(row["comment"]), seen.insert(item.id).inserted else { continue }
            parsed.append(item)
        }
        let listInfo = data["common_list_info"]
        let nextCursor = listInfo["cursor"].string ?? listInfo["cursor"].idString ?? ""
        let hasMore = listInfo["has_more"].bool == true && !nextCursor.isEmpty && !rawList.isEmpty
        return CommentPage(comments: parsed, total: integer(listInfo["total"]), cursor: nextCursor, hasMore: hasMore)
    }

    public struct CommentImageAttachment: Sendable, Equatable {
        public static let maxUploadBytes = 2 * 1024 * 1024

        public var jpegData: Data
        public var width: Int
        public var height: Int
        public var format: String

        public init(jpegData: Data, width: Int, height: Int, format: String = "jpeg") {
            self.jpegData = jpegData
            self.width = width
            self.height = height
            self.format = format
        }
    }

    static func parseComment(_ c: JSONValue) -> EpisodeSocial.Comment? {
        let common = c["common"].isNull ? c["Common"] : c["common"]
        let contentObj = common["content"]
        let rawText = contentObj["text"].string ?? ""
        let images = parseCommentImages(contentObj["image_data_list"]["image_data"])
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
        let base = common["user_info"]["base_info"]
        let author = String((base["user_name"].string ?? "").prefix(200))
        let rawAvatar = [base["user_avatar"].string, base["expand_user_avatar"].string]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let created = date(common["create_timestamp"])
        let content = String(rawText.prefix(20000))
        let imageSeed = images.first?.url ?? ""
        let cid = c["comment_id"].idString ?? DownloadNaming.sha256Prefix("\(author)\u{0}\(created?.timeIntervalSince1970 ?? 0)\u{0}\(content)\u{0}\(imageSeed)", 32)
        let score = integer(c["expand"]["score"]) ?? integer(common["expand"]["score"])
        return .init(
            id: cid,
            author: author,
            avatar: secure(rawAvatar),
            content: content,
            createdAt: created,
            likes: integer(c["stat"]["digg_count"]) ?? 0,
            rating: score.flatMap { (1...10).contains($0) ? $0 : nil },
            replyCount: integer(c["stat"]["reply_count"]) ?? 0,
            images: images
        )
    }

    static func parseCommentImages(_ list: JSONValue) -> [EpisodeSocial.CommentImage] {
        (list.array ?? []).compactMap { item -> EpisodeSocial.CommentImage? in
            let fullCandidates = [
                item["dynamic_url"].string,
                item["expand_web_url"].string,
                item["web_url"].string,
                item["web_uri"].string.flatMap { $0.hasPrefix("http") ? $0 : nil },
            ]
            guard let rawFull = fullCandidates
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) else { return nil }
            let thumbObj = item["thumb_nails"].array?.first
            let thumbCandidates = [
                thumbObj?["dynamic_url"].string,
                thumbObj?["web_url"].string,
                thumbObj?["web_uri"].string.flatMap { $0.hasPrefix("http") ? $0 : nil },
                item["web_url"].string,
            ]
            let rawThumb = thumbCandidates
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) ?? rawFull
            return EpisodeSocial.CommentImage(
                url: secure(rawFull),
                thumbnailUrl: secure(rawThumb),
                width: integer(item["width"]) ?? 0,
                height: integer(item["height"]) ?? 0,
                format: (item["format"].string ?? "jpeg").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Uploads a JPEG image via official 7.4.3 `POST https://reading.snssdk.com/reading/reader/upload/picture/`
    /// (multipart field `picture`, filename `temp.jpeg`, `image/jpeg`, max 2 MiB) and returns its uploaded image metadata.
    public static func uploadCommentImage(
        _ attachment: CommentImageAttachment,
        accountId: String? = nil,
        http: HTTPClient = .shared
    ) async throws -> EpisodeSocial.CommentImage {
        guard !attachment.jpegData.isEmpty else { throw HongguoError(.input, "图片数据为空") }
        guard attachment.jpegData.count <= CommentImageAttachment.maxUploadBytes else {
            throw HongguoError(.input, "图片不能超过 2 MB")
        }
        guard !MacTestRunner.isActive, let saved = try KeychainCredentialStore().load() else {
            throw HongguoError(.input, "请先登录再上传图片")
        }
        if let accountId, saved.profile?.id != accountId {
            throw HongguoError(.cancelled, "账号已切换")
        }
        try Task.checkCancellation()
        guard let url = URL(string: "https://reading.snssdk.com/reading/reader/upload/picture/?aid=8662&app_name=dragon_app&version_code=74532") else {
            throw HongguoError(.input, "上传地址无效")
        }
        let boundary = "Boundary-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let body = buildMultipartPictureBody(jpegData: attachment.jpegData, boundary: boundary)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        var options = HTTPClient.Options()
        options.timeout = 30
        options.maxRedirects = 0
        options.headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        options.headers["Accept"] = "application/json"
        options.headers["Cookie"] = saved.cookie
        for (name, value) in PersistentAppDevice.authHeaders() {
            options.headers[name] = value
        }
        let response: HTTPResponse
        do {
            response = try await http.send(request, options: options)
        } catch let error as HTTPStatusError where error.status == 401 {
            Task { await AccountService.shared.notifyPossibleAuthFailure() }
            throw HongguoError(.unavailable, "登录已过期，请重新扫码登录")
        }
        let payload = try JSONValue.parse(response.data)
        return try parseUploadedImage(
            payload,
            width: attachment.width,
            height: attachment.height,
            format: attachment.format,
            onAuthExpired: {
                Task { await AccountService.shared.notifyPossibleAuthFailure() }
            }
        )
    }

    static func buildMultipartPictureBody(jpegData: Data, boundary: String) -> Data {
        var data = Data()
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"picture\"; filename=\"temp.jpeg\"\r\n".utf8))
        data.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        data.append(jpegData)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return data
    }

    static func parseUploadedImage(
        _ payload: JSONValue,
        width: Int,
        height: Int,
        format: String = "jpeg",
        onAuthExpired: (() -> Void)? = nil
    ) throws -> EpisodeSocial.CommentImage {
        let code = payload["code"].signedInt ?? -1
        let msg = AccountService.cleanText(payload["message"].string ?? payload["msg"].string)
        if code == 103_006 {
            onAuthExpired?()
            throw HongguoError(.unavailable, "登录已过期，请重新扫码登录")
        }
        guard code == 0 else {
            throw HongguoError(.upstream, msg.isEmpty ? "图片上传失败" : msg)
        }
        let uri = (payload["data"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else {
            throw HongguoError(.upstream, "图片上传未返回地址")
        }
        let cleanFormat = format.trimmingCharacters(in: .whitespacesAndNewlines)
        return EpisodeSocial.CommentImage(
            url: secure(uri),
            width: max(0, width),
            height: max(0, height),
            format: cleanFormat.isEmpty ? "jpeg" : cleanFormat
        )
    }

    /// Publishes an episode comment to `/novel/commentapi/comment/add/v1/` (signed in).
    /// Matches official 7.4.3 `FQCRpcAddCommentRequest` (`commit_source=10`, `group_type=30`,
    /// `data_type=4`, `comment_type=0`, `image_data`, `business_param.book_id`, `business_param.offset`).
    public static func postComment(
        seriesId: String,
        vid: String,
        text: String,
        images: [CommentImageAttachment] = [],
        offsetMs: Int64 = 0,
        accountId: String? = nil,
        http: HTTPClient = .shared
    ) async throws -> EpisodeSocial.Comment {
        guard seriesId.matchesDigits(min: 6, max: 30), vid.matchesDigits(min: 6, max: 30) else {
            throw HongguoError(.input, "剧集编号无效")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { throw HongguoError(.input, "请输入评论内容或选择图片") }
        guard trimmed.count <= 1000 else { throw HongguoError(.input, "评论内容不能超过 1000 字") }
        guard images.count <= 3 else { throw HongguoError(.input, "单条评论最多上传 3 张图片") }
        guard !MacTestRunner.isActive, let saved = try KeychainCredentialStore().load() else {
            throw HongguoError(.input, "请先登录再发表评论")
        }
        if let accountId, saved.profile?.id != accountId {
            throw HongguoError(.cancelled, "账号已切换")
        }
        try Task.checkCancellation()
        var uploaded: [EpisodeSocial.CommentImage] = []
        for attachment in images {
            try Task.checkCancellation()
            let image = try await uploadCommentImage(attachment, accountId: accountId, http: http)
            uploaded.append(image)
        }
        try Task.checkCancellation()
        let body = postCommentBody(seriesId: seriesId, vid: vid, text: trimmed, images: uploaded, offsetMs: offsetMs)
        let payload: JSONValue
        do {
            payload = try await AppCommentClient.post(
                "/novel/commentapi/comment/add/v1/",
                body: body,
                headers: [("Comment-Source", "4"), ("Server-Channel", "18"), ("Cookie", saved.cookie)],
                http: http
            )
        } catch let error as HTTPStatusError where error.status == 401 {
            Task { await AccountService.shared.notifyPossibleAuthFailure() }
            throw HongguoError(.unavailable, "登录已过期，请重新扫码登录")
        }
        let posted = try parsePostedComment(
            payload,
            fallbackText: trimmed,
            fallbackImages: uploaded,
            fallbackAuthor: saved.profile?.nickname ?? "",
            fallbackAvatar: "",
            onAuthExpired: {
                Task { await AccountService.shared.notifyPossibleAuthFailure() }
            }
        )
        await cache.remove("\(seriesId):\(vid)")
        return posted
    }

    static func postCommentBody(
        seriesId: String,
        vid: String,
        text: String,
        images: [EpisodeSocial.CommentImage] = [],
        offsetMs: Int64 = 0
    ) -> [String: Any] {
        var body: [String: Any] = [
            "aid": 8662,
            "commit_source": 10,
            "group_id": vid,
            "group_type": 30,
            "data_type": 4,
            "comment_type": 0,
            "text": text,
            "business_param": [
                "book_id": seriesId,
                "offset": max(0, offsetMs),
            ],
        ]
        if !images.isEmpty {
            body["image_data"] = images.map { image in
                [
                    "web_uri": image.url,
                    "width": max(0, image.width),
                    "height": max(0, image.height),
                    "format": image.format.isEmpty ? "jpeg" : image.format,
                ] as [String: Any]
            }
        }
        return body
    }

    static func parsePostedComment(
        _ payload: JSONValue,
        fallbackText: String,
        fallbackImages: [EpisodeSocial.CommentImage] = [],
        fallbackAuthor: String,
        fallbackAvatar: String,
        now: Date = Date(),
        onAuthExpired: (() -> Void)? = nil
    ) throws -> EpisodeSocial.Comment {
        let code = payload["code"].signedInt ?? -1
        let msg = AccountService.cleanText(payload["message"].string ?? payload["msg"].string)
        if code == 103_006 {
            onAuthExpired?()
            throw HongguoError(.unavailable, "登录已过期，请重新扫码登录")
        }
        guard code == 0 else {
            throw HongguoError(.upstream, msg.isEmpty ? "评论发表失败" : msg)
        }
        let info = payload["data"]["comment_info"]
        if var parsed = parseComment(info) {
            if parsed.author.isEmpty { parsed.author = fallbackAuthor }
            if parsed.avatar.isEmpty { parsed.avatar = secure(fallbackAvatar) }
            if parsed.createdAt == nil { parsed.createdAt = now }
            if parsed.images.isEmpty && !fallbackImages.isEmpty { parsed.images = fallbackImages }
            return parsed
        }
        let cid = info["comment_id"].idString
            ?? payload["data"]["comment_id"].idString
            ?? DownloadNaming.sha256Prefix("\(fallbackAuthor)\u{0}\(now.timeIntervalSince1970)\u{0}\(fallbackText)\u{0}\(fallbackImages.first?.url ?? "")", 32)
        return .init(
            id: cid,
            author: fallbackAuthor,
            avatar: secure(fallbackAvatar),
            content: fallbackText,
            createdAt: now,
            likes: 0,
            images: fallbackImages
        )
    }

    /// Fetches one page of replies for an episode comment from the official App comment API
    /// (`/novel/commentapi/reply/list/<commentId>/v1/`, `comment_source=504, server_channel=18, comment_type=4`).
    public static func repliesPage(
        seriesId: String,
        vid: String,
        commentId: String,
        cursor: String = "",
        count: Int = 10,
        http: HTTPClient = .shared
    ) async throws -> ReplyPage {
        guard seriesId.matchesDigits(min: 6, max: 30),
              vid.matchesDigits(min: 6, max: 30),
              commentId.matchesDigits(min: 1, max: 30) else {
            throw HongguoError(.input, "评论回复请求参数无效")
        }
        let pageSize = min(max(count, 1), 20)
        let payload = try await AppCommentClient.post("/novel/commentapi/reply/list/\(commentId)/v1/", body: [
            "comment_source": 504,
            "server_channel": 18,
            "group_id": vid,
            "group_type": 30,
            "comment_id": commentId,
            "comment_type": 4,
            "count": pageSize,
            "cursor": cursor,
            "aid": 8662,
            "compliance_status": 0,
            "business_param": ["book_id": seriesId],
        ], headers: [("Comment-Source", "504"), ("Server-Channel", "18")] + PersistentAppDevice.authHeaders(), http: http)
        guard Int(payload["code"].number ?? -1) == 0 else { throw HongguoError(.upstream, "评论回复接口暂时不可用") }
        return replyPage(from: payload["data"])
    }

    /// One page of replies (`data`): rows live under `reply_list` with a capitalised `Common` block
    /// and pagination metadata in `comment_list_info`.
    static func replyPage(from data: JSONValue) -> ReplyPage {
        let rawList = data["reply_list"].array ?? []
        var seen = Set<String>()
        var parsed: [EpisodeSocial.Reply] = []
        for row in rawList {
            let common = row["Common"].isNull ? row["common"] : row["Common"]
            guard let rawText = common["content"]["text"].string,
                  !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let base = common["user_info"]["base_info"]
            let author = String((base["user_name"].string ?? "").prefix(200))
            let rawAvatar = [base["user_avatar"].string, base["expand_user_avatar"].string]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let created = date(common["create_timestamp"])
            let content = String(rawText.prefix(20000))
            let rid = row["reply_id"].idString ?? DownloadNaming.sha256Prefix("\(author)\u{0}\(created?.timeIntervalSince1970 ?? 0)\u{0}\(content)", 32)
            guard seen.insert(rid).inserted else { continue }
            let toReplyId = row["reply_to_reply_id"].idString ?? ""
            let rawReplyToAuthor = (!toReplyId.isEmpty && toReplyId != "0")
                ? (row["reply_to_user_info"]["base_info"]["user_name"].string ?? "")
                : ""
            let replyToAuthor = String(rawReplyToAuthor.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            parsed.append(.init(
                id: rid,
                author: author,
                avatar: secure(rawAvatar),
                content: content,
                createdAt: created,
                likes: integer(row["stat"]["digg_count"]) ?? 0,
                replyToAuthor: replyToAuthor
            ))
        }
        let listInfo = data["comment_list_info"].isNull ? data["common_list_info"] : data["comment_list_info"]
        let nextCursor = listInfo["cursor"].string ?? listInfo["cursor"].idString ?? ""
        let hasMore = listInfo["has_more"].bool == true && !nextCursor.isEmpty && !rawList.isEmpty
        return ReplyPage(replies: parsed, total: integer(listInfo["total"]), cursor: nextCursor, hasMore: hasMore)
    }

    /// Counts and times arrive as numbers or as digit strings.
    static func integer(_ value: JSONValue) -> Int? {
        guard let parsed = value.signedInt, parsed >= 0 else { return nil }
        return parsed
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
                         encryptedId: (person["encrypted_celebrity_id"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                         profileUserId: profileUserId(person["schema"].string))
        }
    }

    /// `uid` of a `sslocal://guest_profile?uid=…` link; "" for anything else.
    static func profileUserId(_ schema: String?) -> String {
        guard let text = schema?.trimmingCharacters(in: .whitespacesAndNewlines), let parts = URLComponents(string: text),
              parts.host == "guest_profile",
              let uid = parts.queryItems?.first(where: { $0.name == "uid" })?.value, uid.matchesDigits(min: 6, max: 30) else { return "" }
        return uid
    }
}

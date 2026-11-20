import Foundation

/// POST on the App data host signed like the Android 7.3.5 comment client (`DanmakuSigner`): plain
/// JSON body, the persistent device. The comment lists and the book_pack_fields read use it.
enum AppCommentClient {
    static let host = "https://api5-normal-sinfonlineb.fqnovel.com"

    static func post(_ path: String, body: [String: Any], headers extra: [(String, String)] = [],
                     http: HTTPClient) async throws -> JSONValue {
        let stampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let device = try await PersistentAppDevice.dataIdentity(transport: AppTransport(http: http)).identity
        let rawQuery = DanmakuSigner.buildQuery(stampMs: stampMs, deviceId: device.deviceId, installId: device.iid)
        guard let url = URL(string: "\(host)\(path)?\(rawQuery)") else { throw HongguoError(.input, "请求地址无效") }
        var options = HTTPClient.Options()
        options.timeout = 8
        let signing = try DanmakuSigner.headers(rawQuery: rawQuery, stamp: stampMs / 1000,
                                                nonce: AppCrypto.randomBytes(DanmakuSigner.nonceBytes))
        let headers: [(String, String)] = [
            ("User-Agent", DanmakuService.userAgent), ("Accept", "application/json"),
            ("X-XS-From-Web", "0"), ("Sdk-Version", "2"), ("Content-Type", "application/json; charset=utf-8"),
        ] + extra + signing
        for (key, value) in headers { options.headers[key] = value }
        let response = try await http.post(url, json: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
                                           options: options)
        guard let payload = try? JSONValue.parse(response.data) else { throw HongguoError(.upstream, "红果接口返回了无法识别的内容") }
        return payload
    }
}

/// A series' heat and first-shown time as the official app reads them with POST
/// `/reading/distribution/book_pack_fields/inner_feed_detail/v1/` (`req_ids` as numbers, only fields
/// this channel packs). Signed out. Its `digg_cnt` comes back 0 and its `followed_cnt` does not
/// match the detail's for some series, so neither is read: the like and collect counts are the
/// series detail's.
struct OfficialSeriesStats: Sendable, Equatable {
    /// `stat_info.hot_score_data.Text`, e.g. 5263万热度; "" when there is none.
    var heatText: String
    var heatScore: Int?
    /// `base_info.publish_time`.
    var publishedAt: Date?

    static let path = "/reading/distribution/book_pack_fields/inner_feed_detail/v1/"
    static let fields = ["hot_score_data", "publish_time"]
    private static let cache = TTLCache<OfficialSeriesStats>(limit: 64)

    static func load(_ seriesId: String, http: HTTPClient = .shared) async throws -> OfficialSeriesStats {
        if let cached = await cache.get(seriesId) { return cached }
        let stats = try parse(try await request(seriesId, http: http), seriesId: seriesId)
        await cache.set(seriesId, stats, ttl: 60)
        return stats
    }

    static func request(_ seriesId: String, http: HTTPClient = .shared) async throws -> JSONValue {
        guard seriesId.matchesDigits(min: 6, max: 19), let id = Int64(seriesId) else { throw HongguoError(.input, "无效的剧集编号") }
        return try await AppCommentClient.post(path, body: [
            "book_pack_channel": "inner_feed_detail", "req_ids": [id], "req_fields": fields,
        ], http: http)
    }

    static func parse(_ json: JSONValue, seriesId: String) throws -> OfficialSeriesStats {
        let code = Int(json["code"].number ?? -1)
        guard code == 0 else { throw HongguoError(.upstream, "红果剧集统计接口暂时不可用（\(code)）") }
        let entry = json["data"][seriesId]
        guard entry.object != nil else { throw HongguoError(.upstream, "红果剧集统计接口没有返回这部剧") }
        let heat = entry["stat_info"]["hot_score_data"]
        let text = (heat["Text"].string ?? heat["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let published = EpisodeSocialService.date(entry["base_info"]["publish_time"])
        return OfficialSeriesStats(
            heatText: text.count <= 40 ? text : "",
            heatScore: EpisodeSocialService.integer(heat["Score"]).flatMap { $0 > 0 ? $0 : nil },
            publishedAt: published)
    }
}

/// A series' score, how many rated it, the review count and one page of written reviews (each with
/// its score) from the official app's comment list with the review page's values
/// (`FQCShortPlayCommentListViewModel`: comment_source 1, server_channel 3003, group_type 1,
/// comment_type 2). Signed out; pages with the reply's cursor.
struct OfficialSeriesReviews: Sendable, Equatable {
    /// `extra.credibility_score`, out of 10; nil when not rated yet (the reply gives -1).
    var rating: Double?
    /// `extra.credibility_score_count`.
    var ratingCount: Int?
    var page: EpisodeSocialService.CommentPage

    static let source = 1
    static let channel = 3003
    private static let cache = TTLCache<OfficialSeriesReviews>(limit: 64)

    /// The first page is cached for a minute, so the detail view and the player overlay share it.
    static func load(_ seriesId: String, cursor: String = "", count: Int = 10, http: HTTPClient = .shared) async throws -> OfficialSeriesReviews {
        let key = "\(seriesId):\(count)"
        if cursor.isEmpty, let cached = await cache.get(key) { return cached }
        let reviews = try parse(try await request(seriesId, cursor: cursor, count: count, http: http))
        if cursor.isEmpty { await cache.set(key, reviews, ttl: 60) }
        return reviews
    }

    static func request(_ seriesId: String, cursor: String = "", count: Int = 10, http: HTTPClient = .shared) async throws -> JSONValue {
        guard seriesId.matchesDigits(min: 6, max: 30), (1...20).contains(count), cursor.count <= 200 else {
            throw HongguoError(.input, "剧评请求编号或条数无效")
        }
        return try await AppCommentClient.post("/novel/commentapi/comment/list/\(seriesId)/v1/", body: [
            "comment_source": source, "server_channel": channel, "group_id": seriesId, "group_type": 1,
            "comment_type": 2, "sort": 1, "count": count, "cursor": cursor, "aid": 8662, "compliance_status": 0,
            "business_param": ["book_id": seriesId, "need_count": true],
        ], headers: [("Comment-Source", String(source)), ("Server-Channel", String(channel))], http: http)
    }

    static func parse(_ json: JSONValue) throws -> OfficialSeriesReviews {
        let code = Int(json["code"].number ?? -1)
        guard code == 0 else { throw HongguoError(.upstream, "红果剧评接口暂时不可用（\(code)）") }
        let data = json["data"]
        let extra = data["extra"]
        let score = extra["credibility_score"].number ?? extra["credibility_score"].string.flatMap(Double.init)
        return OfficialSeriesReviews(
            rating: score.flatMap { $0 > 0 && $0 <= 10 ? $0 : nil },
            ratingCount: EpisodeSocialService.integer(extra["credibility_score_count"]),
            page: EpisodeSocialService.commentPage(from: data))
    }
}

import Foundation

/// Episode lists, play URLs, public details and share-link resolution for Hongguo series.
/// One source for each, no fallbacks: play URLs come only from the official iOS client's play
/// request (`AuthenticatedPlaybackSource`); the episode list and the series facts come only from the
/// public website's series pages, because the App detail request (`multi_video_detail`, every
/// route in the official 7.4.3 RPC table) has answered empty for every client but the official
/// app since 2026-11-20.
public final class SeriesService: Sendable {
    private let http: HTTPClient
    private let episodeCache = TTLCache<SeriesEpisodes>(limit: 64)
    private let detailsCache = TTLCache<PublicDetails>(limit: 64)

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    private var pageOptions: HTTPClient.Options {
        var options = HTTPClient.Options()
        options.headers = [
            "User-Agent": UserAgents.web,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": Site.referer,
        ]
        return options
    }

    // MARK: Episodes

    public func episodes(seriesId: String, force: Bool = false) async throws -> SeriesEpisodes {
        guard seriesId.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "无效的剧集编号") }
        if !force, let cached = await episodeCache.get(seriesId) { return cached }
        let result = try await episodesFromWeb(seriesId)
        await episodeCache.set(seriesId, result, ttl: 60)
        return result
    }

    /// Races the website's player page and series page for the same `vid_list`; some CDN edges
    /// hang on one of them.
    func episodesFromWeb(_ seriesId: String) async throws -> SeriesEpisodes {
        let urls = [Site.playerURL(seriesId), Site.detailURL(seriesId)]
        var options = pageOptions
        options.timeout = 6
        return try await withThrowingTaskGroup(of: SeriesEpisodes.self) { group in
            for url in urls {
                group.addTask { [http] in
                    let response = try await http.get(url, options: options)
                    return try Self.parseEpisodeList(response.text, seriesId: seriesId)
                }
            }
            var firstError: Error?
            while let next = await group.nextResult() {
                switch next {
                case .success(let value):
                    group.cancelAll()
                    return value
                case .failure(let error):
                    if (error as? HongguoError)?.kind == .cancelled || error is CancellationError { throw error }
                    if firstError == nil { firstError = error }
                }
            }
            throw firstError ?? HongguoError(.upstream, "官网分集列表加载失败")
        }
    }

    /// The episode list in the website's router data (`seriesDetail.vid_list`, in episode order).
    /// Every episode plays through the App source, so `webAvailable` stays unset.
    public static func parseEpisodeList(_ html: String, seriesId: String) throws -> SeriesEpisodes {
        let router = try HTMLData.routerData(html)
        let loader = router["loaderData"]
        var data = loader["player_(series_id)/page"]
        if data.isNull { data = loader["player_(series_id)/(vid)/page"] }
        if data.isNull { data = loader["detail_page"] }
        let detail = data["seriesDetail"]
        let detailId = detail["series_id"].idString ?? ""
        guard !data.isNull, data["isSuccess"].bool != false, detailId.matchesDigits(min: 1, max: 30), detailId == seriesId,
              data["series_id"].isNull || data["series_id"].idString == seriesId else {
            throw HongguoError(.format, "官网返回的剧集与请求不一致或缺少剧集身份")
        }
        guard let list = detail["vid_list"].array else { throw HongguoError(.format, "官网页面未找到分集数据（vid_list）") }
        let vids = list.compactMap(\.idString)
        guard vids.count == list.count, vids.allSatisfy({ $0.matchesDigits(min: 1, max: 30) }), Set(vids).count == vids.count else {
            throw HongguoError(.format, "官网分集数据异常")
        }
        guard !vids.isEmpty else { throw HongguoError(.format, "官网分集列表为空") }
        let title = detail["series_name"].string ?? "未命名短剧"
        let cover = HTMLData.safeCover(detail["series_cover"].string)
        let episodes = vids.enumerated().map { i, vid in
            Episode(vid: vid, index: i + 1, title: "", seriesId: seriesId, webAvailable: nil)
        }
        return SeriesEpisodes(seriesId: seriesId, title: title, cover: cover, episodes: episodes,
                              webAccessibleEpisodes: nil, source: .web)
    }

    // MARK: Play URL

    /// Resolves a playable URL through the official iOS client's play request
    /// (`AuthenticatedPlaybackSource`, which caches the result until the server's expiry).
    public func playInfo(vid: String, seriesId: String?, force: Bool = false) async throws -> PlayInfo {
        guard vid.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "无效的分集编号") }
        let started = Date()
        do {
            let resolved = try await AuthenticatedPlaybackSource.shared.resolveWithMeta(vid: vid, force: force)
            AccountDataAccess.onWriteLog?("play ok route=\(resolved.route) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return resolved.info
        } catch is CancellationError {
            throw HongguoError(.cancelled, "已取消 App 片源请求")
        } catch let error as HongguoError where error.kind == .cancelled {
            throw error
        } catch {
            AccountDataAccess.onWriteLog?("play failed ms=\(Int(Date().timeIntervalSince(started) * 1000)): \(Self.describe(error).prefix(60))")
            throw HongguoError((error as? HongguoError)?.kind ?? .unavailable,
                               "本集取源失败：\(Self.describe(error))。请重试或在官方 App 确认可播情况。")
        }
    }

    /// Renews the persistent device ahead of the first episode, so that episode does not wait for it.
    public func warmUpPlayback() async {
        await AuthenticatedPlaybackSource.shared.warmUpIdentity()
    }

    /// Asks for the play models of up to 6 episodes in one request, for episodes the viewer is
    /// likely to pick next. Best effort: it steps aside for a viewer's own lookup and pauses for
    /// 30 seconds after an empty reply.
    public func prefetchPlayInfo(vids: [String]) async {
        await AuthenticatedPlaybackSource.shared.prefetchBatch(vids: vids)
    }

    /// One quiet try at an episode's source for prefetching: no device recovery and no retry.
    /// nil when it did not answer.
    public func prefetchedPlayInfo(vid: String, seriesId: String?) async -> PlayInfo? {
        guard vid.matchesDigits(min: 1, max: 30) else { return nil }
        let source = AuthenticatedPlaybackSource.shared
        if let hit = await source.cachedPlayInfoWithMeta(vid: vid) { return hit.info }
        return try? await source.resolveWithMeta(vid: vid, allowRecovery: false).info
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Public details

    public func publicDetails(seriesId: String) async throws -> PublicDetails {
        guard seriesId.matchesDigits(min: 6, max: 30) else { throw HongguoError(.input, "仅支持有效的红果剧集编号") }
        if let cached = await detailsCache.get(seriesId) { return cached }
        // Everything from the public series page: synopsis, cover, episode label, completion,
        // score, reviews, counts and first-shown date.
        var details = try await publicDetailsFromWeb(seriesId: seriesId)
        if let published = details.publishedAt, published > Date() { details.publishedAt = nil }
        await detailsCache.set(seriesId, details, ttl: 30)
        return details
    }

    func publicDetailsFromWeb(seriesId: String) async throws -> PublicDetails {
        var options = pageOptions
        options.timeout = 10
        options.maxRedirects = 0
        let response = try await http.get(Site.detailURL(seriesId), options: options)
        return try Self.parsePublicDetails(response.text, seriesId: seriesId)
    }

    public static func parsePublicDetails(_ html: String, seriesId: String, reviewLimit: Int = 50) throws -> PublicDetails {
        let router = try HTMLData.routerData(html)
        guard let data = (router["loaderData"].object ?? [:]).values.first(where: { !$0["seriesDetail"].isNull && $0["isSuccess"].bool != false }) else {
            throw HongguoError(.format, "来源页面未返回公开剧集信息")
        }
        let detail = data["seriesDetail"]
        guard detail["series_id"].idString == seriesId else { throw HongguoError(.format, "来源页面剧集不匹配") }
        let social = data["seriesSocialInfo"]
        func count(_ value: JSONValue) -> Int? { value.number.flatMap { $0 >= 0 ? Int($0) : nil } }
        let reviews = (social["reviews"]["reviews"].array ?? []).compactMap { item -> Review? in
            guard let content = item["content"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
            let created = item["create_time"].number.map { Date(timeIntervalSince1970: $0 < 1e12 ? $0 : $0 / 1000) }
            return Review(author: String((item["user_name"].string ?? "").prefix(200)),
                          avatar: HTMLData.safeCover(item["user_avatar"].string),
                          content: String(content.prefix(20000)), createdAt: created,
                          likes: count(item["digg_count"]), rating: item["rating"].number)
        }
        let meta = CatalogService.metadata(detail)
        return PublicDetails(seriesId: seriesId, description: detail["series_intro"].string ?? "",
                             cover: HTMLData.safeCover(detail["series_cover"].string),
                             episodeLabel: meta.label, completionStatus: meta.status,
                             rating: social["rating"].number, ratingCount: count(social["rating_count"]),
                             likeCount: count(social["series_like_count"]), favoriteCount: count(social["series_favorite_count"]),
                             reviewTotal: count(social["reviews"]["total_count"]), reviews: Array(reviews.prefix(reviewLimit)),
                             publishedAt: meta.published)
    }

    // MARK: Share links

    /// Accepts a series id, text containing `series_id=...`, or a share link (redirects are followed
    /// manually, each hop guarded). Returns the numeric series id.
    public func resolveSeriesId(_ input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8192 else { throw HongguoError(.input, "分享内容无效或过长") }
        if trimmed.matchesDigits(min: 1, max: 30) { return trimmed }
        let linkPattern = "https?://[^\\s<>\"'，。！？；、【】（）]+"
        let withoutLinks = trimmed.replacingOccurrences(of: linkPattern, with: " ", options: [.regularExpression, .caseInsensitive])
        if let match = HTMLData.firstMatch("(?:^|[^A-Za-z0-9_])(?:video_)?series_id[\"']?\\s*[:=]\\s*[\"']?(\\d{1,30})(?![A-Za-z0-9_])", in: withoutLinks) {
            return match[1]
        }
        guard var link = HTMLData.firstMatch(linkPattern, in: trimmed)?[0] else {
            throw HongguoError(.input, "请输入有效的 HTTP 或 HTTPS 分享链接，或剧集 ID")
        }
        while let last = link.last, "),.;!".contains(last) { link.removeLast() }
        guard link.count <= 4096, var url = URL(string: link), URLGuard.isPublicURL(url) else {
            throw HongguoError(.input, "分享链接必须指向公网 HTTP 或 HTTPS 地址")
        }
        if let id = Self.seriesIdFromURL(url) { return id }
        var options = HTTPClient.Options()
        options.headers = ["User-Agent": UserAgents.web]
        options.maxRedirects = 0
        options.timeout = 25
        options.maxBytes = 2 * 1024 * 1024
        for _ in 0...5 {
            let response = try await http.get(url, options: options)
            if (300...399).contains(response.status) {
                guard let location = response.header("Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      URLGuard.isPublicURL(next) else { throw HongguoError(.input, "分享链接跳转无效") }
                if let id = Self.seriesIdFromURL(next) { return id }
                url = next
                continue
            }
            let body = response.text
            if let match = HTMLData.firstMatch("video_series_id=(\\d{1,30})(?!\\d)", in: body)
                ?? HTMLData.firstMatch("\"(?:video_id|series_id)\"\\s*:\\s*\"(\\d{1,30})\"", in: body) {
                return match[1]
            }
            throw HongguoError(.input, "无法从分享链接解析剧集 ID")
        }
        throw HongguoError(.input, "分享链接跳转次数过多")
    }

    public static func seriesIdFromURL(_ url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        let direct = query.first { $0.name == "video_series_id" }?.value ?? query.first { $0.name == "series_id" }?.value
        if let direct, direct.matchesDigits(min: 1, max: 30) { return direct }
        if let match = HTMLData.firstMatch("^/player/(\\d{1,30})(?:/|$)", in: url.path) { return match[1] }
        if let scheme = query.first(where: { $0.name == "schemeParams" })?.value,
           let match = HTMLData.firstMatch("\"video_id\"\\s*:\\s*\"(\\d{1,30})\"", in: scheme.removingPercentEncoding ?? scheme) {
            return match[1]
        }
        return nil
    }
}

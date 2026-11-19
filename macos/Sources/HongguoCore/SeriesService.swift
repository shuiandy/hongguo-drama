import Foundation

/// Episode lists, play URLs, public details and share-link resolution for Hongguo series.
/// Port of the web-first paths in `hongguo.js` and `public-details.js`.
public final class SeriesService: Sendable {
    private let http: HTTPClient
    private let api: LegacyAPI
    private let appSource: AppSource
    private let fastSource: FastAppPlaybackSource
    private let episodeCache = TTLCache<SeriesEpisodes>(limit: 64)
    private let playCache = TTLCache<PlayInfo>(limit: 128)
    private let detailsCache = TTLCache<PublicDetails>(limit: 64)
    private let failedWeb = TTLCache<Bool>(limit: 128)

    public init(http: HTTPClient = .shared) {
        self.http = http
        self.api = LegacyAPI(http: http)
        // One process-wide App queue (pacing and refusal handling are shared, as in Electron).
        self.appSource = http === HTTPClient.shared ? .shared : AppSource(http: http)
        // One process-wide device identity, shared by the player, prefetch and downloads.
        self.fastSource = http === HTTPClient.shared ? .shared : FastAppPlaybackSource(http: http)
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
        let result: SeriesEpisodes
        do {
            result = try await episodesFromWeb(seriesId)
        } catch {
            let webMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            do {
                result = try await api.episodes(seriesId: seriesId)
            } catch {
                let apiMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw HongguoError(.unavailable, "获取分集失败：官网数据源（\(webMessage)），备用接口（\(apiMessage)）")
            }
        }
        await episodeCache.set(seriesId, result, ttl: 60)
        return result
    }

    /// Races the player page and the detail page; some CDN edges hang on one of them.
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
                    if firstError == nil { firstError = error }
                }
            }
            throw firstError ?? HongguoError(.upstream, "加载失败")
        }
    }

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
        var accessible: Int?
        if let n = detail["accessible_episode_cnt"].number, n >= 0, n.rounded() == n { accessible = min(Int(n), vids.count) }
        let episodes = vids.enumerated().map { i, vid in
            Episode(vid: vid, index: i + 1, title: "", seriesId: seriesId, webAvailable: accessible.map { i < $0 })
        }
        return SeriesEpisodes(seriesId: seriesId, title: title, cover: cover, episodes: episodes,
                              webAccessibleEpisodes: accessible, source: .web)
    }

    // MARK: Play URL

    /// Resolves a playable URL. Order: the fast App source (one anonymous device kept in memory,
    /// signed player/v1; an empty reply is asked again at once), then the queued App source with
    /// its legacy signature, then the legacy preload API, and the official web page last.
    /// The web page comes last because it answers with a preview or 404 for nearly every
    /// episode and costs about two seconds each time; a web address that just failed to play
    /// is not asked again for five minutes.
    public func playInfo(vid: String, seriesId: String?, force: Bool = false) async throws -> PlayInfo {
        try await playInfo(vid: vid, seriesId: seriesId, force: force, webAvailable: nil)
    }

    /// `webAvailable` is what the catalogue says about the web page having this episode.
    /// It no longer changes the order (the web page is always last); `false` skips the web page.
    public func playInfo(vid: String, seriesId: String?, force: Bool, webAvailable: Bool?) async throws -> PlayInfo {
        guard vid.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "无效的分集编号") }
        let key = "\(seriesId ?? ""):\(vid)"
        if !force, let cached = await playCache.get(key) { return cached }
        var failures: [String] = []
        var refused = false
        for attempt in 0..<2 {
            do {
                let info = try await fastSource.resolve(vid: vid, force: force || attempt > 0)
                await playCache.set(key, info, ttl: 30)
                return info
            } catch let error as AppSourceError {
                if error.code == .cancelled { throw error.hongguoError }
                refused = error.isHardRejection
                if attempt == 0, error.code == .emptyResponse { continue }
                failures.append("App：\(Self.describe(error))")
                break
            } catch is CancellationError {
                throw HongguoError(.cancelled, "已取消 App 片源请求")
            } catch {
                failures.append("App：\(Self.describe(error))")
                break
            }
        }
        // After an explicit refusal the same request through the queue would only be refused again.
        if !refused {
            do {
                let info = try await appSource.playInfo(vid: vid)
                await playCache.set(key, info, ttl: 30)
                return info
            } catch let error as AppSourceError where error.code == .cancelled {
                throw error.hongguoError
            } catch {
                failures.append("App 排队通道：\(Self.describe(error))")
            }
        }
        do {
            let info = try await api.playInfo(vid: vid)
            await playCache.set(key, info, ttl: 30)
            return info
        } catch {
            failures.append("旧接口：\(Self.describe(error))")
        }
        let recentlyFailed = await failedWeb.get(vid) == true
        if !recentlyFailed, webAvailable != false {
            do {
                let info = try await playInfoFromWeb(vid: vid, seriesId: seriesId)
                await playCache.set(key, info, ttl: 30)
                return info
            } catch let error as HongguoError where error.kind == .cancelled {
                throw error
            } catch {
                failures.append("网页：\(Self.describe(error))")
            }
        }
        throw HongguoError(.unavailable, "本集取源失败：\(failures.joined(separator: "；"))。请重试或在官方 App 确认可播情况。")
    }

    /// Registers the anonymous playback device ahead of the first episode, so that episode does
    /// not wait for the registration (about half a second).
    public func warmUpPlayback() async {
        await fastSource.warmUpIdentity()
    }

    /// Asks for the play models of up to 6 episodes in one request, for episodes the viewer is
    /// likely to pick next. Best effort: it steps aside for a viewer's own lookup and pauses for
    /// 30 seconds after an empty reply.
    public func prefetchPlayInfo(vids: [String]) async {
        await fastSource.prefetchBatch(vids: vids)
    }

    /// One quiet try at an episode's source for prefetching: the fast App source only, no retry
    /// and no other source. nil when it did not answer.
    public func prefetchedPlayInfo(vid: String, seriesId: String?) async -> PlayInfo? {
        guard vid.matchesDigits(min: 1, max: 30) else { return nil }
        let key = "\(seriesId ?? ""):\(vid)"
        if let cached = await playCache.get(key) { return cached }
        return try? await fastSource.resolve(vid: vid)
    }

    /// Call when a media request for a web URL failed, so retries leave the web page out for 5 minutes.
    public func markWebMediaFailure(_ info: PlayInfo) async {
        guard info.source == .web else { return }
        await failedWeb.set(info.vid, true, ttl: 300)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func playInfoFromWeb(vid: String, seriesId: String?) async throws -> PlayInfo {
        var candidates: [URL] = []
        if let seriesId, !seriesId.isEmpty { candidates.append(Site.playerURL(seriesId, vid)) }
        candidates.append(URL(string: "\(Site.origin)/player/_/\(vid)")!)
        var options = pageOptions
        options.timeout = 6
        var lastError: Error = HongguoError(.unavailable, "暂未取得有效片源")
        for url in candidates {
            do {
                let response = try await http.get(url, options: options)
                return try Self.parseWebPlayInfo(response.text, vid: vid, seriesId: seriesId)
            } catch let error as HongguoError where error.kind == .previewOnly {
                throw error
            } catch let error as HongguoError where error.kind == .cancelled {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Picks the `VideoObject.contentUrl` bound to the current player (not recommendations).
    public static func parseWebPlayInfo(_ html: String, vid: String, seriesId: String?) throws -> PlayInfo {
        let router = try HTMLData.routerData(html)
        let data = router["loaderData"]["player_(series_id)/(vid)/page"]
        guard !data.isNull else { throw HongguoError(.format, "接口未返回本集片源模型") }
        guard data["isSuccess"].bool != false else { throw HongguoError(.upstream, "接口暂时拒绝本次请求") }
        let actualSid = data["series_id"].idString ?? ""
        let seo = data["publicVideoSeo"]
        guard data["vid"].idString == vid, actualSid.isDigitsOnly,
              seriesId == nil || seriesId!.isEmpty || actualSid == seriesId,
              data["seriesDetail"]["series_id"].idString == actualSid else {
            throw HongguoError(.format, "片源数据无法解析")
        }
        guard seo["available"].bool == true, seo["itemId"].idString == vid, seo["seriesId"].idString == actualSid else {
            throw HongguoError(.unavailable, "暂未取得有效片源")
        }
        if data["protectedPlayback"].bool == true { throw HongguoError(.previewOnly, "网页仅提供预览，未作为完整片源") }

        func matchesPlayer(_ value: String?, _ videoURL: URL) -> Bool {
            guard let value, let target = URL(string: value), target.scheme == "https", target.host == "hongguoduanju.com",
                  target.user == nil, target.password == nil else { return false }
            if target.path == "/player/\(actualSid)/\(vid)" { return true }
            return target.path == "/player/\(actualSid)" && videoURL.host == "hongguoduanju.com"
                && videoURL.scheme == "https" && videoURL.path.hasPrefix("/video/public/\(vid)/")
        }
        var blocked = false
        for script in HTMLData.scripts(html) {
            guard script.attributes.range(of: "\\btype\\s*=\\s*[\"']application/ld\\+json[\"']", options: [.regularExpression, .caseInsensitive]) != nil,
                  let video = try? JSONValue.parse(script.body), video["@type"].string == "VideoObject",
                  let contentURL = video["contentUrl"].string,
                  let videoURL = URL(string: normalizeVideoURL(contentURL)) else { continue }
            guard matchesPlayer(video["url"].string, videoURL) else { continue }
            if let id = video["@id"].string, !matchesPlayer(id, videoURL) { continue }
            guard URLGuard.isPublicURL(videoURL) else { blocked = true; continue }
            return PlayInfo(url: upgradeToHTTPS(videoURL), spadeA: nil, codec: "", source: .web, vid: vid,
                            userAgent: UserAgents.web, referer: Site.referer)
        }
        throw blocked ? URLGuard.blocked() : HongguoError(.unavailable, "暂未取得有效片源")
    }

    /// Strips escapes and the `Range` query parameter so the CDN serves the whole file.
    public static func normalizeVideoURL(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "([?&])Range=[^&]*", with: "$1", options: [.regularExpression, .caseInsensitive])
        while value.hasSuffix("?") || value.hasSuffix("&") { value.removeLast() }
        return value.replacingOccurrences(of: "?&", with: "?").replacingOccurrences(of: "&&", with: "&")
    }

    /// App Transport Security stays on, so plain-http CDN links are tried over https.
    static func upgradeToHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    // MARK: Public details

    public func publicDetails(seriesId: String) async throws -> PublicDetails {
        guard seriesId.matchesDigits(min: 6, max: 30) else { throw HongguoError(.input, "仅支持有效的红果剧集编号") }
        if let cached = await detailsCache.get(seriesId) { return cached }
        var options = pageOptions
        options.timeout = 10
        options.maxRedirects = 0
        let response = try await http.get(Site.detailURL(seriesId), options: options)
        let details = try Self.parsePublicDetails(response.text, seriesId: seriesId)
        await detailsCache.set(seriesId, details, ttl: 30)
        return details
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

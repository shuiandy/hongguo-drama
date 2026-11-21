import Foundation

/// Episode lists, play URLs, public details and share-link resolution for Hongguo series.
/// One source for each, no fallbacks: play URLs come only from the official iOS client's play
/// request (`AuthenticatedPlaybackSource`); the episode list and the series facts only from the
/// official app's series detail read (`OfficialSeriesDetail`, GET video_tab/multi_video_detail);
/// the score and written reviews only from the App comment list (`OfficialSeriesReviews`); the
/// first-shown date only from the App's book_pack_fields read (`OfficialSeriesStats`).
/// No website pages: the website is only the target of share links and "open the source page".
public final class SeriesService: Sendable {
    private let http: HTTPClient
    private let episodeCache = TTLCache<SeriesEpisodes>(limit: 64)
    private let detailsCache = TTLCache<PublicDetails>(limit: 64)

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: Episodes

    public func episodes(seriesId: String, force: Bool = false) async throws -> SeriesEpisodes {
        guard seriesId.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "无效的剧集编号") }
        if !force, let cached = await episodeCache.get(seriesId) { return cached }
        let result = Self.episodes(from: try await OfficialSeriesDetail.load(seriesId, force: force, http: http))
        await episodeCache.set(seriesId, result, ttl: 60)
        return result
    }

    /// Every listed episode plays through the App source, so `webAvailable` stays unset.
    static func episodes(from detail: OfficialSeriesDetail) -> SeriesEpisodes {
        let episodes = detail.episodes.map { Episode(vid: $0.vid, index: $0.index, title: $0.title, seriesId: detail.seriesId, webAvailable: nil) }
        return SeriesEpisodes(seriesId: detail.seriesId, title: detail.title.isEmpty ? "未命名短剧" : detail.title, cover: detail.cover,
                              episodes: episodes, webAccessibleEpisodes: nil, source: .api)
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
        // Synopsis, cover, episode label, completion, collect and like counts from the App detail
        // (required); score and reviews from the App comment list, the first-shown date from the App's
        // book_pack_fields read, each left empty when it did not answer.
        async let stats = try? OfficialSeriesStats.load(seriesId, http: http)
        async let reviews = try? OfficialSeriesReviews.load(seriesId, http: http)
        let detail = try await OfficialSeriesDetail.load(seriesId, http: http)
        let details = Self.publicDetails(detail: detail, stats: await stats, reviews: await reviews)
        await detailsCache.set(seriesId, details, ttl: 30)
        return details
    }

    static func publicDetails(detail: OfficialSeriesDetail, stats: OfficialSeriesStats?, reviews: OfficialSeriesReviews?) -> PublicDetails {
        let list = (reviews?.page.comments ?? []).map {
            Review(author: $0.author, avatar: $0.avatar, content: $0.content, createdAt: $0.createdAt,
                   likes: $0.likes, rating: $0.rating.map(Double.init))
        }
        // A first-shown time in the future is a scheduled release, not a publish date.
        let published = stats?.publishedAt.flatMap { $0 <= Date() ? $0 : nil }
        return PublicDetails(seriesId: detail.seriesId, description: detail.intro, cover: detail.cover,
                             episodeLabel: detail.episodeLabel, completionStatus: detail.completion,
                             rating: reviews?.rating, ratingCount: reviews?.ratingCount,
                             likeCount: detail.likeCount, favoriteCount: detail.favoriteCount,
                             reviewTotal: reviews?.page.total, reviews: list, publishedAt: published,
                             cast: detail.cast, tags: detail.tags)
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

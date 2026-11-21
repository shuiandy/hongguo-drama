import Foundation
import HongguoCore
import HongguoPlayback

/// One episode as the app needs it. The core's `Episode` has no public initialiser, so the
/// offline sample data cannot build one; this type can be made from either.
public struct DramaEpisode: Identifiable, Hashable, Sendable {
    public var vid: String
    /// 1-based.
    public var index: Int
    public var title: String
    public var disabled: Bool = false
    public var id: String { vid == "0" ? "offline-gap-\(index)" : vid }

    public init(vid: String, index: Int, title: String, disabled: Bool = false) {
        self.vid = vid
        self.index = index
        self.title = title
        self.disabled = disabled
    }
}

public struct DramaSeries: Sendable {
    public var seriesId: String
    public var title: String
    public var cover: String
    public var episodes: [DramaEpisode]
    public var total: Int { episodes.count }

    public init(seriesId: String, title: String, cover: String, episodes: [DramaEpisode]) {
        self.seriesId = seriesId
        self.title = title
        self.cover = cover
        self.episodes = episodes
    }
}

public struct GenreChoice: Identifiable, Hashable, Sendable {
    public var slug: String
    public var label: String
    public var id: String { slug }

    public init(slug: String, label: String) {
        self.slug = slug
        self.label = label
    }
}

public struct CatalogResult: Sendable {
    public var items: [SeriesSummary]
    public var genres: [GenreChoice]
    public var page: Int = 1
    public var totalPages: Int

    public init(items: [SeriesSummary], genres: [GenreChoice], page: Int = 1, totalPages: Int) {
        self.items = items
        self.genres = genres
        self.page = page
        self.totalPages = totalPages
    }
}

public struct SearchPageResult: Sendable {
    public var items: [SeriesSummary]
    public var hasMore: Bool
    public var cursor: AppSearchCursor?

    public init(items: [SeriesSummary], hasMore: Bool, cursor: AppSearchCursor? = nil) {
        self.items = items
        self.hasMore = hasMore
        self.cursor = cursor
    }
}

/// Every read the app makes. `LiveBackend` talks to the service through HongguoCore;
/// `FixtureBackend` returns built-in rows and never touches the network.
/// There are no write calls here on purpose: favourites and history stay on the device.
public protocol DramaBackend: Sendable {
    var isOffline: Bool { get }
    func catalog(kind: CatalogKind, genre: String?, page: Int, forceRefresh: Bool) async throws -> CatalogResult
    func search(_ keyword: String) async throws -> [SeriesSummary]
    func searchPage(_ keyword: String, page: Int, cursor: AppSearchCursor?) async throws -> SearchPageResult
    func newReleases() async throws -> [SeriesSummary]
    func series(seriesId: String) async throws -> DramaSeries
    func synopsis(seriesId: String) async throws -> String
    func danmaku(seriesId: String, vid: String) async -> [DanmakuItem]
    /// Public comments of one episode (read-only; the site offers only the first batch).
    /// The episode's public comments (author, date, likes) and the series' public figures. Read-only.
    func social(seriesId: String, vid: String) async throws -> EpisodeSocial
    /// Additional pages of episode comments. Read-only.
    func commentsPage(seriesId: String, vid: String, cursor: String) async throws -> EpisodeSocialService.CommentPage
    /// One page of replies under an episode comment. Read-only.
    func commentReplies(seriesId: String, vid: String, commentId: String, cursor: String, count: Int) async throws -> EpisodeSocialService.ReplyPage
    /// Publishes an episode comment (optionally with uploaded JPEG images) under the signed-in account.
    func postComment(
        seriesId: String,
        vid: String,
        text: String,
        images: [EpisodeSocialService.CommentImageAttachment],
        offsetMs: Int64,
        accountId: String?
    ) async throws -> EpisodeSocial.Comment
    /// Replies to an episode comment under the signed-in account.
    func postReply(seriesId: String, vid: String, commentId: String, text: String,
                   offsetMs: Int64, accountId: String?) async throws -> EpisodeSocial.Reply
    /// The series' public score and first reviews. Read-only.
    func reviews(seriesId: String) async throws -> SeriesReviews
}

extension DramaBackend {
    public func catalog(kind: CatalogKind, genre: String?, page: Int) async throws -> CatalogResult {
        try await catalog(kind: kind, genre: genre, page: page, forceRefresh: false)
    }
}

public struct LiveBackend: DramaBackend {
    public var isOffline: Bool { false }
    private let catalogService = CatalogService()
    private let searchService = AppSearchService()

    public func catalog(kind: CatalogKind, genre: String?, page: Int, forceRefresh: Bool) async throws -> CatalogResult {
        let result = try await catalogService.browse(kind: kind, genre: genre, page: page, forceRefresh: forceRefresh)
        if let message = result.unsupportedMessage { throw HongguoError(.unavailable, message) }
        return CatalogResult(items: result.results,
                             genres: result.genres.map { GenreChoice(slug: $0.slug, label: $0.label) },
                             page: result.page,
                             totalPages: result.totalPages)
    }

    public func search(_ keyword: String) async throws -> [SeriesSummary] {
        try await searchService.search(keyword).results
    }

    public func searchPage(_ keyword: String, page: Int, cursor: AppSearchCursor?) async throws -> SearchPageResult {
        let res = try await searchService.search(keyword, page: page, cursor: cursor)
        return SearchPageResult(items: res.results, hasMore: res.hasMore, cursor: res.cursor)
    }

    public func newReleases() async throws -> [SeriesSummary] {
        try await NewReleaseService.shared.list(pages: 1).items.map(\.series)
    }

    public func series(seriesId: String) async throws -> DramaSeries {
        let list = try await EpisodeResolver.shared.episodes(seriesId: seriesId)
        return DramaSeries(seriesId: list.seriesId, title: list.title, cover: list.cover,
                           episodes: list.episodes.map {
                               DramaEpisode(vid: $0.vid, index: $0.index, title: $0.title, disabled: $0.disabled == true)
                           })
    }

    public func synopsis(seriesId: String) async throws -> String {
        try await EpisodeResolver.shared.details(seriesId: seriesId).description
    }

    public func danmaku(seriesId: String, vid: String) async -> [DanmakuItem] {
        await DanmakuService.shared.fetch(seriesId: seriesId, vid: vid).items
    }

    public func social(seriesId: String, vid: String) async throws -> EpisodeSocial {
        try await EpisodeSocialService.load(seriesId: seriesId, vid: vid)
    }

    public func commentsPage(seriesId: String, vid: String, cursor: String) async throws -> EpisodeSocialService.CommentPage {
        try await EpisodeSocialService.commentsPage(seriesId: seriesId, vid: vid, cursor: cursor)
    }

    public func commentReplies(seriesId: String, vid: String, commentId: String, cursor: String, count: Int) async throws -> EpisodeSocialService.ReplyPage {
        try await EpisodeSocialService.repliesPage(seriesId: seriesId, vid: vid, commentId: commentId, cursor: cursor, count: count)
    }

    public func postComment(
        seriesId: String,
        vid: String,
        text: String,
        images: [EpisodeSocialService.CommentImageAttachment],
        offsetMs: Int64,
        accountId: String?
    ) async throws -> EpisodeSocial.Comment {
        try await EpisodeSocialService.postComment(
            seriesId: seriesId,
            vid: vid,
            text: text,
            images: images,
            offsetMs: offsetMs,
            accountId: accountId
        )
    }

    public func postReply(seriesId: String, vid: String, commentId: String, text: String,
                          offsetMs: Int64, accountId: String?) async throws -> EpisodeSocial.Reply {
        try await EpisodeSocialService.postReply(seriesId: seriesId, vid: vid, commentId: commentId, text: text,
                                                 offsetMs: offsetMs, accountId: accountId)
    }

    public func reviews(seriesId: String) async throws -> SeriesReviews {
        try await EpisodeSocialService.reviews(seriesId: seriesId)
    }

    public init() {}
}

/// Sample rows for screenshots and UI work. Used with `-HongguoOfflineFixtures YES`.
public struct FixtureBackend: DramaBackend {
    public var isOffline: Bool { true }

    public static let titles = ["重生之我在豪门当保姆", "闪婚后发现老公是总裁", "离婚后她惊艳了全世界", "我的师父是剑仙",
                         "千金归来", "逆袭从退婚开始", "深宫谋", "都市最强赘婿", "她的秘密花园", "龙王殿",
                         "萌宝助攻：爹地快追妈咪", "星辰大海与你", "无双战神", "裁员后我继承了公司", "穿书后我成了反派亲妈",
                         "江山为聘", "夜色温柔", "回到九零当首富"]
    public static let tags = [["逆袭", "都市"], ["甜宠", "闪婚"], ["大女主", "虐恋"], ["玄幻", "热血"], ["豪门", "复仇"], ["古装", "权谋"]]

    public static func summary(_ index: Int, prefix: String = "fixture") -> SeriesSummary {
        let n = (index - 1) % titles.count
        return SeriesSummary(seriesId: "\(prefix)-\(index)", title: titles[n], episodeCount: 60 + n * 5,
                             tags: tags[n % tags.count],
                             description: "示例简介：这是一段用于离线演示的剧情介绍，讲述主角在逆境中一步步走出来的故事。",
                             rank: index, heat: "\(980 - n * 37).\(n % 10)万热度", episodeLabel: "全\(60 + n * 5)集",
                             completionStatus: .completed)
    }

    public func catalog(kind: CatalogKind, genre: String?, page: Int, forceRefresh: Bool) async throws -> CatalogResult {
        CatalogResult(items: (1...18).map { Self.summary($0 + (page - 1) * 18, prefix: "fixture-\(kind.rawValue)") },
                      genres: [GenreChoice(slug: "tianchong", label: "甜宠"), GenreChoice(slug: "nixi", label: "逆袭"),
                               GenreChoice(slug: "guzhuang", label: "古装")],
                      page: page,
                      totalPages: 2)
    }

    public func search(_ keyword: String) async throws -> [SeriesSummary] {
        (1...6).map { Self.summary($0, prefix: "fixture-search") }
    }

    public func searchPage(_ keyword: String, page: Int, cursor: AppSearchCursor?) async throws -> SearchPageResult {
        SearchPageResult(
            items: (1...6).map { Self.summary($0 + (page - 1) * 6, prefix: "fixture-search") },
            hasMore: false,
            cursor: nil
        )
    }

    public func commentsPage(seriesId: String, vid: String, cursor: String) async throws -> EpisodeSocialService.CommentPage {
        EpisodeSocialService.CommentPage(comments: [], total: 0, cursor: "", hasMore: false)
    }

    public func newReleases() async throws -> [SeriesSummary] {
        (1...10).map { Self.summary($0 + 6, prefix: "fixture-new") }
    }

    public func series(seriesId: String) async throws -> DramaSeries {
        let number = Int(seriesId.split(separator: "-").last ?? "1") ?? 1
        let summary = Self.summary(number)
        return DramaSeries(seriesId: seriesId, title: summary.title, cover: "",
                           episodes: (1...summary.episodeCount).map {
                               DramaEpisode(vid: "\(seriesId)-ep\($0)", index: $0, title: "第\($0)集")
                           })
    }

    public func synopsis(seriesId: String) async throws -> String {
        "示例简介：这是一段用于离线演示的剧情介绍，讲述主角在逆境中一步步走出来的故事。真实数据会显示官网的剧情简介。"
    }

    public func danmaku(seriesId: String, vid: String) async -> [DanmakuItem] {
        ["开头就这么刺激", "女主好飒", "前方高能", "这集必看", "哈哈哈哈", "男主终于来了", "太解气了"].enumerated().map {
            DanmakuItem(time: Double($0.offset) * 1.5, text: $0.element)
        }
    }

    public func reviews(seriesId: String) async throws -> SeriesReviews {
        let reviews = ["节奏很快，一口气看完", "反转不少，值得一看", "中段有点拖"].enumerated().map { offset, text in
            EpisodeSocial.Comment(id: "r\(offset)", author: "示例用户\(offset + 1)", avatar: "", content: text,
                                  createdAt: Date(timeIntervalSince1970: 1_794_000_000), likes: 16 - offset * 5, rating: 10 - offset * 2)
        }
        return SeriesReviews(rating: 8.6, ratingCount: 1920, heatText: "906万热度", favoriteCount: 146_000, reviews: reviews, reviewTotal: 212)
    }

    public func social(seriesId: String, vid: String) async throws -> EpisodeSocial {
        let texts = ["开头就这么刺激，一口气看了十集", "女主太飒了，这才是大女主", "男主什么时候出场啊", "编剧会写，反转一个接一个",
                     "这集信息量好大", "求更新快一点", "配角演技都在线", "看得我血压都上来了，还好后面解气"]
        let names = ["示例用户甲", "示例用户乙", "示例用户丙", "示例用户丁"]
        let comments = texts.enumerated().map { offset, text in
            EpisodeSocial.Comment(id: "\(offset)", author: names[offset % names.count], avatar: "", content: text,
                                  createdAt: Date(timeIntervalSince1970: 1_794_000_000 - Double(offset) * 86_400),
                                  likes: (offset * 37 + 8) % 300,
                                  replyCount: offset == 0 ? 3 : (offset == 1 ? 1 : 0))
        }
        return EpisodeSocial(seriesId: seriesId, vid: vid, title: "示例剧", cover: "", intro: "这是一段用于离线演示的简介。",
                             episodeCount: 95, tags: ["都市", "逆袭"], cast: [], firstShown: Date(timeIntervalSince1970: 1_793_000_000),
                             favoriteCount: 146_000, comments: comments, commentTotal: 422, episodeLikes: 9_800)
    }

    public func commentReplies(seriesId: String, vid: String, commentId: String, cursor: String, count: Int) async throws -> EpisodeSocialService.ReplyPage {
        let baseTime: TimeInterval = 1_794_000_000
        if commentId == "0" {
            let all: [EpisodeSocial.Reply] = [
                .init(id: "f-r1", author: "示例回复甲", avatar: "", content: "同感，根本停不下来[笑哭]",
                      createdAt: Date(timeIntervalSince1970: baseTime - 3_600), likes: 12),
                .init(id: "f-r2", author: "示例回复乙", avatar: "", content: "我也一口气刷完的",
                      createdAt: Date(timeIntervalSince1970: baseTime - 1_800), likes: 4, replyToAuthor: "示例回复甲"),
                .init(id: "f-r3", author: "示例回复丙", avatar: "", content: "后面几集更爽",
                      createdAt: Date(timeIntervalSince1970: baseTime - 600), likes: 1),
            ]
            return EpisodeSocialService.ReplyPage(replies: all, total: all.count, cursor: "3", hasMore: false)
        }
        return EpisodeSocialService.ReplyPage(
            replies: [
                .init(id: "f-\(commentId)-1", author: "示例回复丁", avatar: "", content: "确实太飒了",
                      createdAt: Date(timeIntervalSince1970: baseTime - 1_200), likes: 2)
            ],
            total: 1,
            cursor: "1",
            hasMore: false
        )
    }

    public func postComment(
        seriesId: String,
        vid: String,
        text: String,
        images: [EpisodeSocialService.CommentImageAttachment],
        offsetMs: Int64,
        accountId: String?
    ) async throws -> EpisodeSocial.Comment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { throw HongguoError(.input, "请输入评论内容或选择图片") }
        let fixtureImages: [EpisodeSocial.CommentImage] = images.enumerated().compactMap { index, item in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-comment-\(UUID().uuidString)-\(index).jpg")
            try? item.jpegData.write(to: url)
            return EpisodeSocial.CommentImage(url: url.absoluteString, width: item.width, height: item.height, format: item.format)
        }
        return EpisodeSocial.Comment(
            id: "fixture-post-\(UUID().uuidString)",
            author: "我",
            avatar: "",
            content: trimmed,
            createdAt: Date(),
            likes: 0,
            images: fixtureImages
        )
    }

    public func postReply(seriesId: String, vid: String, commentId: String, text: String,
                          offsetMs: Int64, accountId: String?) async throws -> EpisodeSocial.Reply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HongguoError(.input, "请输入回复内容") }
        return EpisodeSocial.Reply(id: "fixture-reply-\(UUID().uuidString)", author: "我", avatar: "",
                                   content: trimmed, createdAt: Date(), likes: 0)
    }

    public init() {}
}

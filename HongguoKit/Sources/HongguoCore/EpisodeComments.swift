import Foundation

/// Comments of one episode ("本集评论"), the stand-in when timed danmaku is unavailable. From the
/// App comment list (`EpisodeSocialService.commentsPage`), nothing else.
public struct EpisodeComments: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String
        public var content: String
    }
    public var seriesId: String
    public var vid: String
    public var items: [Item]
    public var total: Int?
    public var likeCount: Int?
    public var notice: String
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
        let page = try await EpisodeSocialService.commentsPage(seriesId: seriesId, vid: vid, count: limit, http: http)
        let result = EpisodeComments(seriesId: seriesId, vid: vid,
                                     items: page.comments.prefix(limit).map { .init(id: $0.id, content: $0.content) },
                                     total: page.total, likeCount: nil, notice: "")
        await cache.set(key, result, ttl: 30)
        return result
    }
}

extension EpisodeComments {
    /// The comments as scrolling danmaku ("本集评论（备用）"). The page has no timestamps, so the
    /// comments are spread evenly over the episode (every 3 s when the length is unknown).
    public func danmakuItems(duration: Double? = nil) -> [DanmakuItem] {
        let texts = items.map { $0.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.count > 60 ? String($0.prefix(58)) + "…" : $0 }
        guard !texts.isEmpty else { return [] }
        let spacing: Double
        if let duration, duration.isFinite, duration > 10 {
            spacing = min(8, max(1.5, (duration - 4) / Double(texts.count)))
        } else {
            spacing = 3
        }
        return texts.enumerated().map { index, text in DanmakuItem(time: 1 + Double(index) * spacing, text: text) }
    }
}

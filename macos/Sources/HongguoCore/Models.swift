import Foundation

public enum CompletionStatus: String, Codable, Sendable {
    case completed, ongoing, unknown
}

/// One card in search results, category pages and rankings.
public struct SeriesSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String { seriesId }
    public var seriesId: String
    public var title: String
    public var cover: String
    public var episodeCount: Int
    public var tags: [String]
    public var description: String
    public var rank: Int?
    public var heat: String
    public var episodeLabel: String
    public var completionStatus: CompletionStatus
    public var publishedAt: Date?

    public init(seriesId: String, title: String, cover: String = "", episodeCount: Int = 0, tags: [String] = [],
                description: String = "", rank: Int? = nil, heat: String = "", episodeLabel: String = "",
                completionStatus: CompletionStatus = .unknown, publishedAt: Date? = nil) {
        self.seriesId = seriesId
        self.title = title
        self.cover = cover
        self.episodeCount = episodeCount
        self.tags = tags
        self.description = description
        self.rank = rank
        self.heat = heat
        self.episodeLabel = episodeLabel
        self.completionStatus = completionStatus
        self.publishedAt = publishedAt
    }
}

public struct SearchPage: Sendable {
    public var keyword: String
    public var results: [SeriesSummary]
    public var total: Int
    public var totalPages: Int
    public var page: Int
    public var hasMore: Bool
}

public struct Genre: Hashable, Identifiable, Sendable {
    public var id: String { slug }
    public var slug: String
    public var label: String
}

public struct CatalogPage: Sendable {
    public var results: [SeriesSummary]
    public var page: Int
    public var total: Int
    public var totalPages: Int
    public var genres: [Genre]
    public var pageTitle: String
    public var sourceURL: URL
    /// Set for categories that exist on the site but are not video (comics).
    public var unsupportedMessage: String?
}

public struct Episode: Identifiable, Hashable, Codable, Sendable {
    public var id: String { vid }
    public var vid: String
    /// 1-based episode number.
    public var index: Int
    public var title: String
    public var seriesId: String
    /// nil when the website did not say how many episodes are publicly available.
    public var webAvailable: Bool?
    /// Set by 西饭/河马 lists: the source marks this episode as paid or locked. nil for Hongguo.
    public var locked: Bool? = nil
}

public enum EpisodeListSource: String, Codable, Sendable { case web, api }

public struct SeriesEpisodes: Sendable {
    public var seriesId: String
    public var title: String
    public var cover: String
    public var episodes: [Episode]
    public var webAccessibleEpisodes: Int?
    public var source: EpisodeListSource
    public var total: Int { episodes.count }
}

public struct Review: Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var author: String
    public var avatar: String
    public var content: String
    public var createdAt: Date?
    public var likes: Int?
    public var rating: Double?
}

public struct PublicDetails: Sendable {
    public var seriesId: String
    public var description: String
    public var cover: String
    public var episodeLabel: String
    public var completionStatus: CompletionStatus
    public var rating: Double?
    public var ratingCount: Int?
    public var likeCount: Int?
    public var favoriteCount: Int?
    public var reviewTotal: Int?
    public var reviews: [Review]
}

public enum PlaySource: String, Sendable { case web, api, app }

/// One resolution tier of an episode, identified by the video's short side in pixels.
public struct QualityOption: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { shortSide }
    /// Short side in pixels (1080 for a 1080x1920 portrait video).
    public var shortSide: Int
    public var label: String

    public init(shortSide: Int) {
        self.shortSide = shortSide
        switch shortSide {
        case 2160...: label = "4K"
        case 1440..<2160: label = "2K"
        default: label = "\(shortSide)P"
        }
    }
}

/// A resolved media URL for one episode.
public struct PlayInfo: Sendable, Equatable {
    public var url: URL
    /// Base64 key material for CENC-encrypted MP4 (App/API sources). nil for plain media.
    public var spadeA: String?
    public var codec: String
    public var source: PlaySource
    public var vid: String
    public var userAgent: String
    public var referer: String?
    /// 16-byte CENC content key already derived by the App source (`spade_a` of player/v1 models).
    public var contentKey: [UInt8]? = nil
    /// Resolution tier of this stream; nil when the source does not say (web).
    public var quality: QualityOption? = nil
    /// The same episode at other resolution tiers, highest first. Empty for single-stream sources.
    public var variants: [PlayInfo] = []

    /// Every tier of this episode, highest first (empty for single-stream sources).
    public var qualityOptions: [QualityOption] {
        guard !variants.isEmpty else { return [] }
        return ([quality] + variants.map(\.quality)).compactMap { $0 }.sorted { $0.shortSide > $1.shortSide }
    }

    /// The stream for a preferred short side: exact tier, else the best tier below it, else the lowest.
    /// nil keeps the default ("auto") choice. The result carries the full `variants` list again.
    public func selecting(shortSide preferred: Int?) -> PlayInfo {
        guard let preferred, !variants.isEmpty else { return self }
        var base = self
        base.variants = []
        let all = ([base] + variants).sorted { ($0.quality?.shortSide ?? 0) > ($1.quality?.shortSide ?? 0) }
        guard var chosen = all.first(where: { ($0.quality?.shortSide ?? 0) <= preferred }) ?? all.last else { return self }
        chosen.variants = all.filter { $0.url != chosen.url }
        return chosen
    }

    public var isEncrypted: Bool { spadeA != nil || contentKey != nil }
    /// Only playable after 兼容转换 to H.264 (see `ByteVC2Converter`).
    public var isByteVC2: Bool { codec == "bytevc2" }
    /// Needs a local file before AVPlayer can play it (decryption or conversion).
    public var needsLocalFile: Bool { isEncrypted || isByteVC2 }

    public var httpHeaders: [String: String] {
        var headers = ["User-Agent": userAgent]
        if let referer { headers["Referer"] = referer }
        return headers
    }
}

public struct HongguoError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case input, timeout, network, upstream, format, security, unavailable, previewOnly, cancelled, decrypt
    }
    public var kind: Kind
    public var message: String
    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
    public var errorDescription: String? { message }
}

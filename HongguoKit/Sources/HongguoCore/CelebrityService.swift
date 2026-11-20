import Foundation

/// One actor's works as the official app's actor panel reads them: GET
/// `/reading/user/celebrity/works/v1/` (`SSGetCelebrityWorksRequest`: `encrypted_celebrity_ids`
/// comma-joined, `offset`, `count`, `req_scene` 0), legacy query signature, signed out. The reply
/// keys each actor's `{has_more, total_count, video_list}` by the encrypted id. The actor's own
/// name, picture and introduction come from the series detail's `celebrities`.
public struct CelebrityWorks: Sendable, Equatable {
    public var items: [SeriesSummary]
    public var total: Int?
    public var hasMore: Bool
    /// The offset of the next page.
    public var nextOffset: Int

    public init(items: [SeriesSummary], total: Int?, hasMore: Bool, nextOffset: Int) {
        self.items = items; self.total = total; self.hasMore = hasMore; self.nextOffset = nextOffset
    }
}

public enum CelebrityService {
    static let path = "/reading/user/celebrity/works/v1/"
    private static let cache = TTLCache<CelebrityWorks>(limit: 64)

    /// One page of `member`'s works, newest first as the server orders them.
    public static func works(of member: EpisodeSocial.CastMember, offset: Int = 0, count: Int = 20,
                             http: HTTPClient = .shared) async throws -> CelebrityWorks {
        guard !member.encryptedId.isEmpty else { throw HongguoError(.unavailable, "这位演员暂时没有作品信息") }
        let key = "\(member.encryptedId):\(offset):\(count)"
        if let cached = await cache.get(key) { return cached }
        let reply = try await request(encryptedIds: [member.encryptedId], offset: offset, count: count, http: http)
        guard let works = try parse(reply)[member.encryptedId] else { throw HongguoError(.upstream, "红果没有返回这位演员的作品") }
        var page = works
        page.nextOffset = offset + max(count, works.items.count)
        await cache.set(key, page, ttl: 300)
        return page
    }

    static func request(encryptedIds: [String], offset: Int, count: Int, http: HTTPClient = .shared) async throws -> JSONValue {
        let ids = encryptedIds.filter { !$0.isEmpty && $0.count <= 200 && !$0.contains(",") }
        guard !ids.isEmpty, ids.count <= 50, (0...10_000).contains(offset), (1...50).contains(count) else {
            throw HongguoError(.input, "演员作品请求参数无效")
        }
        let transport = AppTransport(http: http)
        let (identity, dToken) = try await PersistentAppDevice.dataIdentity(transport: transport)
        let signed = try AppLegacySigner.shared.videoTab(
            path: path,
            values: [("encrypted_celebrity_ids", ids.joined(separator: ",")), ("offset", String(offset)),
                     ("count", String(count)), ("req_scene", "0")],
            identity: identity, dToken: dToken, nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
        do {
            return try await transport.requestJSON(signed.url, headers: signed.headers, deadline: Date().addingTimeInterval(8))
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
    }

    /// `data.works`, keyed by encrypted actor id.
    static func parse(_ json: JSONValue) throws -> [String: CelebrityWorks] {
        let code = Int(json["code"].number ?? -1)
        guard code == 0 else { throw HongguoError(.upstream, "红果演员作品接口暂时不可用（\(code)）") }
        var result: [String: CelebrityWorks] = [:]
        for (id, info) in json["data"]["works"].object ?? [:] {
            var seen = Set<String>()
            let items = (info["video_list"].array ?? []).compactMap { summary($0, seen: &seen) }
            result[id] = CelebrityWorks(items: items, total: EpisodeSocialService.integer(info["total_count"]),
                                        hasMore: info["has_more"].bool == true && !items.isEmpty, nextOffset: items.count)
        }
        return result
    }

    /// An `SSVideoData` card.
    static func summary(_ video: JSONValue, seen: inout Set<String>) -> SeriesSummary? {
        let detail = video["video_detail"]
        let id = (video["series_id"].idString ?? detail["series_id_str"].idString ?? detail["series_id"].idString ?? "")
            .trimmingCharacters(in: .whitespaces)
        let title = AccountService.cleanText(video["title"].string ?? video["series_title"].string ?? detail["series_title"].string)
        guard id.matchesDigits(min: 6, max: 30), !title.isEmpty, seen.insert(id).inserted else { return nil }
        let subs = video["sub_title_list"].array ?? []
        let heat = AccountService.cleanText(
            subs.first(where: { Int($0["data_type"].number ?? 0) == 27 })?["content"].string
            ?? subs.first(where: { ($0["content"].string ?? "").contains("热度") })?["content"].string)
        let count = EpisodeSocialService.integer(video["episode_cnt"]) ?? EpisodeSocialService.integer(detail["episode_cnt"]) ?? 0
        let label = String((video["episode_right_text"].string ?? detail["episode_right_text"].string ?? "")
            .trimmingCharacters(in: .whitespaces).prefix(40))
        let rawCover = video["cover"].string ?? detail["series_cover"].string ?? ""
        let cleanedCover = AccountService.cleanCover(rawCover)
        return SeriesSummary(
            seriesId: id, title: title,
            cover: AccountDataAccess.normalizeHTTPSURL(cleanedCover.isEmpty ? rawCover : cleanedCover),
            episodeCount: count, heat: heat, episodeLabel: label,
            completionStatus: CatalogService.metadata(video).status)
    }
}

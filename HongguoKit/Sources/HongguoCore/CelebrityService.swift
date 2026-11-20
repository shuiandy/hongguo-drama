import Foundation

/// One actor's works as the official app's actor panel reads them: GET
/// `/reading/user/celebrity/works/v1/` (`SSGetCelebrityWorksRequest`: `encrypted_celebrity_ids`
/// comma-joined, `offset`, `count`, `req_scene` 0), legacy query signature, signed out. The reply
/// keys each actor's `{has_more, total_count, video_list}` by the encrypted id. The actor's own
/// name, picture and introduction come from the series detail's `celebrities`.
///
/// The server ignores `offset` (a second page repeats the first), and the official panel does not
/// page either: it shows one batch and the total. `count` is honoured (50 returned all 45 works of
/// one actor; the panel's 10 returns 11), so there is one read per actor with `count` 50. A read
/// for three actors keys each one correctly; one for twenty returned totals of 0.
public struct CelebrityWorks: Sendable, Equatable {
    public var items: [SeriesSummary]
    /// `total_count`: all of the actor's works, often more than `items`.
    public var total: Int?

    public init(items: [SeriesSummary], total: Int?) {
        self.items = items; self.total = total
    }
}

public enum CelebrityService {
    static let path = "/reading/user/celebrity/works/v1/"
    private static let cache = TTLCache<CelebrityWorks>(limit: 64)

    /// `member`'s works as the server lists them (one read, cached for five minutes).
    public static func works(of member: EpisodeSocial.CastMember, count: Int = 50,
                             http: HTTPClient = .shared) async throws -> CelebrityWorks {
        guard !member.encryptedId.isEmpty else { throw HongguoError(.unavailable, "这位演员暂时没有作品信息") }
        let key = "\(member.encryptedId):\(count)"
        if let cached = await cache.get(key) { return cached }
        let reply = try await request(encryptedIds: [member.encryptedId], offset: 0, count: count, http: http)
        guard let works = try parse(reply)[member.encryptedId] else { throw HongguoError(.upstream, "红果没有返回这位演员的作品") }
        await cache.set(key, works, ttl: 300)
        return works
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
            result[id] = CelebrityWorks(items: items, total: EpisodeSocialService.integer(info["total_count"]))
        }
        return result
    }

    /// A work card. Live cards (2026-11-20) carry `series_id`, `title`, `cover`, `sub_title` (genre
    /// and episode count, e.g. 时空之旅·102集), `play_cnt` and `score`; their `episode_cnt` is 0 and
    /// they have no heat text, `video_detail`, `sub_title_list` or completion state. So the episode
    /// count and genre are read from `sub_title` and the play count stands in for heat.
    static func summary(_ video: JSONValue, seen: inout Set<String>) -> SeriesSummary? {
        let id = (video["series_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
        let title = AccountService.cleanText(video["title"].string)
        guard id.matchesDigits(min: 6, max: 30), !title.isEmpty, seen.insert(id).inserted else { return nil }
        let (genre, episodes) = subtitle(video["sub_title"].string)
        let rawCover = video["cover"].string ?? ""
        let cleanedCover = AccountService.cleanCover(rawCover)
        return SeriesSummary(
            seriesId: id, title: title,
            cover: AccountDataAccess.normalizeHTTPSURL(cleanedCover.isEmpty ? rawCover : cleanedCover),
            episodeCount: EpisodeSocialService.integer(video["episode_cnt"]).flatMap { $0 > 0 ? $0 : nil } ?? episodes ?? 0,
            tags: genre.isEmpty ? [] : [genre],
            heat: plays(EpisodeSocialService.integer(video["play_cnt"])))
    }

    /// `时空之旅·102集` → ("时空之旅", 102); a part that is not an episode count is the genre.
    static func subtitle(_ text: String?) -> (genre: String, episodes: Int?) {
        let parts = AccountService.cleanText(text).split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        var genre = ""
        var episodes: Int?
        for part in parts where !part.isEmpty {
            if episodes == nil, part.hasSuffix("集"), let n = Int(part.dropLast().filter(\.isNumber)), n > 0 {
                episodes = n
            } else if genre.isEmpty, part.count <= 12 {
                genre = part
            }
        }
        return (genre, episodes)
    }

    /// 60814291 → 6081万播放; nil or 0 → "".
    static func plays(_ count: Int?) -> String {
        guard let count, count > 0 else { return "" }
        if count >= 100_000_000 { return String(format: "%.1f亿播放", Double(count) / 100_000_000) }
        if count >= 10_000 { return "\(count / 10_000)万播放" }
        return "\(count)播放"
    }
}

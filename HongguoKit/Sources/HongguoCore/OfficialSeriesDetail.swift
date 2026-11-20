import Foundation

/// A series as the official app reads it with GET `/reading/bookapi/video_tab/multi_video_detail/v1/`
/// (request class `SSVideoDetailRequest` in the 7.4.3 binary: `video_series_id`, `vs_id_type`,
/// `source`): the whole episode list with each episode's like count, plus the series title, cover,
/// synopsis, episode label, completion, collect and play counts and filing number. Signed out, with
/// the persistent device and its token. The only source of the episode list and these facts.
struct OfficialSeriesDetail: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var vid: String
        /// 1-based.
        var index: Int
        /// `digged_count`: how many liked this episode.
        var likes: Int?
        /// `disable_play`: the server marks the episode as not playable.
        var disabled: Bool
    }

    var seriesId: String
    var title: String
    var cover: String
    var intro: String
    /// `episode_right_text`, e.g. 全173集.
    var episodeLabel: String
    var episodeCount: Int
    var completion: CompletionStatus
    /// `followed_cnt`: how many collected the series.
    var favoriteCount: Int?
    /// `series_play_cnt`.
    var playCount: Int?
    /// `record_info.record_number`, "" when there is none.
    var recordNumber: String
    var episodes: [Entry]

    static let path = "/reading/bookapi/video_tab/multi_video_detail/v1/"
    private static let cache = TTLCache<OfficialSeriesDetail>(limit: 64)

    static func load(_ seriesId: String, force: Bool = false, http: HTTPClient = .shared) async throws -> OfficialSeriesDetail {
        guard seriesId.matchesDigits(min: 6, max: 30) else { throw HongguoError(.input, "无效的剧集编号") }
        if !force, let cached = await cache.get(seriesId) { return cached }
        let transport = AppTransport(http: http)
        let (identity, dToken) = try await PersistentAppDevice.dataIdentity(transport: transport)
        let signed = try AppLegacySigner.shared.videoTab(
            path: path, values: [("video_series_id", seriesId), ("vs_id_type", "0"), ("source", "0")],
            identity: identity, dToken: dToken, nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
        let json: JSONValue
        do {
            json = try await transport.requestJSON(signed.url, headers: signed.headers, deadline: Date().addingTimeInterval(8))
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
        let detail = try parse(json, seriesId: seriesId)
        await cache.set(seriesId, detail, ttl: 60)
        return detail
    }

    static func parse(_ json: JSONValue, seriesId: String) throws -> OfficialSeriesDetail {
        let code = Int(json["code"].number ?? -1)
        guard code == 0 else { throw HongguoError(.upstream, "红果剧集接口暂时不可用（\(code)）") }
        let data = json["data"]["video_detail_data"][seriesId]["video_data"]
        guard let list = data["video_list"].array else { throw HongguoError(.upstream, "红果剧集接口没有返回分集列表") }
        if let id = data["series_id_str"].idString ?? data["series_id"].idString, id != seriesId {
            throw HongguoError(.format, "红果返回的剧集与请求不一致")
        }
        func count(_ value: JSONValue) -> Int? { value.number.flatMap { $0 >= 0 && $0 < 1e15 ? Int($0) : nil } }
        var seen = Set<String>()
        var entries: [Entry] = []
        for (offset, item) in list.enumerated() {
            guard let vid = item["vid"].idString, vid.matchesDigits(min: 1, max: 30), seen.insert(vid).inserted else { continue }
            let index = count(item["vid_index"]) ?? 0
            entries.append(Entry(vid: vid, index: index > 0 ? index : offset + 1, likes: count(item["digged_count"]),
                                 disabled: item["disable_play"].bool == true))
        }
        entries.sort { $0.index < $1.index }
        guard !entries.isEmpty else { throw HongguoError(.upstream, "红果剧集接口的分集列表为空") }
        let label = CatalogService.metadata(data).label
        var completion = CatalogService.metadata(data).status
        if completion == .unknown, count(data["series_status"]) == 1 { completion = .completed }
        let record = AccountService.cleanText(data["record_info"]["record_number"].string)
        let rawCover = data["series_cover"].string ?? ""
        let cleanedCover = AccountService.cleanCover(rawCover)
        return OfficialSeriesDetail(
            seriesId: seriesId,
            title: AccountService.cleanText(data["series_title"].string),
            cover: AccountDataAccess.normalizeHTTPSURL(cleanedCover.isEmpty ? rawCover : cleanedCover),
            intro: (data["series_intro"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            episodeLabel: label,
            episodeCount: max(count(data["episode_cnt"]) ?? 0, entries.count),
            completion: completion,
            favoriteCount: count(data["followed_cnt"]),
            playCount: count(data["series_play_cnt"]),
            recordNumber: record.count <= 80 ? record : "",
            episodes: entries)
    }

    func likes(vid: String) -> Int? { episodes.first { $0.vid == vid }?.likes }
}

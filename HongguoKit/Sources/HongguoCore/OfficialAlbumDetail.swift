import Foundation

/// Vids of creator-uploaded videos (`content_type` 1001), learned when a collection's episode list
/// loads (`OfficialAlbumDetail`). The play model asks for them under key 1001 instead of 1004, and
/// account history writes skip them (the official shape for collection history is not known).
enum UGCVideos {
    static let modelKey = "1001"
    /// Kept between launches, so a download or a resume of a collection video after a relaunch
    /// still asks under 1001 before the collection is opened again. The newest `limit` are kept.
    static let defaultsKey = "HongguoUGCVideoIds.v1"
    static let limit = 5000
    private static let lock = NSLock()
    nonisolated(unsafe) private static var vids: [String] = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    nonisolated(unsafe) private static var known = Set(vids)

    static func insert(_ list: [String]) {
        lock.lock(); defer { lock.unlock() }
        let fresh = list.filter { known.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        vids += fresh
        if vids.count > limit {
            vids.removeFirst(vids.count - limit)
            known = Set(vids)
        }
        UserDefaults.standard.set(vids, forKey: defaultsKey)
    }

    static func contains(_ vid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return known.contains(vid)
    }
}

/// A creator's collection (合集, `content_type` 1003), or one creator video on its own (1001), as the official app reads it with POST
/// `/novel/player/album_detail/v1/` (`FQVGetVideoAlbumDetailRequest` in the 7.4.3 binary:
/// `album_id`, `series_ids`, `need_video_detail_info`, `biz_param`). Search and history give the
/// collection's id where a series id would be; the series detail read answers it with no episode
/// list. Each episode is a single creator video whose own id is the item's `series_id`; asking again
/// with `series_ids` returns each one's `video_list` with its vid and like count.
enum OfficialAlbumDetail {
    static let url = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/album_detail/v1/"

    /// The collection as an `OfficialSeriesDetail`, or nil when `albumId` is not a collection with videos.
    static func load(_ albumId: String, http: HTTPClient = .shared) async throws -> OfficialSeriesDetail? {
        let listing = try? await request(albumId, items: nil, http: http)
        let albumList = listing?["data"]["album_data"]["video_detail_list"].array ?? []
        guard let listing, !albumList.isEmpty else {
            // Not a collection (or album listing rejected a lone video id): try as a single creator
            // video (`content_type` 1001), which the same read answers when asked for its own id.
            guard let reply = try? await request(albumId, items: [albumId], http: http),
                  let lone = parseLone(reply["data"]["video_detail_data"][albumId]["video_data"], id: albumId) else { return nil }
            UGCVideos.insert(lone.episodes.map(\.vid))
            return lone
        }
        let items = itemIds(listing)
        guard !items.isEmpty else { return nil }
        // Up to 50 items per request, as the listing returns them.
        var details: [String: JSONValue] = [:]
        for start in stride(from: 0, to: items.count, by: 50) {
            let chunk = Array(items[start..<min(start + 50, items.count)])
            if let reply = try? await request(albumId, items: chunk, http: http), let map = reply["data"]["video_detail_data"].object {
                details.merge(map) { first, _ in first }
            }
        }
        let detail = try parse(listing, details: details, albumId: albumId)
        UGCVideos.insert(detail.episodes.map(\.vid))
        return detail
    }

    static func request(_ albumId: String, items: [String]?, http: HTTPClient) async throws -> JSONValue {
        let transport = AppTransport(http: http)
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
        var object: [String: Any] = [
            "album_id": albumId,
            "biz_param": ["detail_page_version": 0, "device_level": 3, "disable_digg_stat": false, "need_all_video_definition": false,
                          "need_mp4_align": false, "use_os_player": false, "use_server_dns": false, "video_platform": 1024],
        ]
        if let items {
            object["series_ids"] = items.compactMap { Int64($0).map { NSNumber(value: $0) } }
            object["need_video_detail_info"] = true
        }
        let payload = Array(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        let reply: JSONValue
        do {
            reply = try await TransientReadRetry.run {
                let signed = try AppSource.modelRequest(base: url, payload: payload, identity: identity)
                return try await transport.requestJSON(signed.url, method: "POST", headers: signed.headers + dToken, body: signed.body,
                                                       deadline: Date().addingTimeInterval(10))
            }
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
        guard Int(reply["code"].number ?? -1) == 0 else {
            throw HongguoError(.upstream, "红果合集接口暂时不可用（\(Int(reply["code"].number ?? -1))）")
        }
        return reply
    }

    /// A single creator video (`content_type` 1001) as a one-episode series, or nil.
    static func parseLone(_ video: JSONValue, id: String) -> OfficialSeriesDetail? {
        guard Int(video["content_type"].number ?? 0) == 1001,
              (video["series_id_str"].nonZeroIdString ?? video["series_id"].nonZeroIdString) == id else { return nil }
        let item = video["video_list"][0]
        let vid = item["vid"].nonZeroIdString.flatMap { $0.matchesDigits(min: 1, max: 30) ? $0 : nil } ?? id
        func count(_ value: JSONValue) -> Int? { value.number.flatMap { $0 >= 0 && $0 < 1e15 ? Int($0) : nil } }
        let title = AccountService.cleanText(video["series_title"].string)
        let rawCover = video["series_cover"].string ?? ""
        let cleanedCover = AccountService.cleanCover(rawCover)
        return OfficialSeriesDetail(
            seriesId: id, title: title,
            cover: AccountDataAccess.normalizeHTTPSURL(cleanedCover.isEmpty ? rawCover : cleanedCover),
            intro: (video["series_intro"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            episodeLabel: "共1集", episodeCount: 1, completion: .completed,
            favoriteCount: count(video["followed_cnt"]), playCount: count(video["series_play_cnt"]), recordNumber: "",
            episodes: [OfficialSeriesDetail.Entry(vid: vid, index: 1, likes: count(item["digged_count"]) ?? count(video["digg_cnt"]),
                                                  disabled: video["disable_play"].bool == true || item["disable_play"].bool == true, title: title)])
    }

    static func itemIds(_ listing: JSONValue) -> [String] {
        var seen = Set<String>()
        return (listing["data"]["album_data"]["video_detail_list"].array ?? []).compactMap { item in
            guard let id = item["series_id_str"].nonZeroIdString ?? item["series_id"].nonZeroIdString, id.matchesDigits(min: 1, max: 30),
                  seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// Episodes in list order (two items may share a title). A video's vid is the one its detail
    /// gives, else the item id, which the detail has always matched.
    static func parse(_ listing: JSONValue, details: [String: JSONValue], albumId: String) throws -> OfficialSeriesDetail {
        let album = listing["data"]["album_data"]
        if let id = album["album_id_str"].nonZeroIdString ?? album["album_id"].nonZeroIdString, id != albumId {
            throw HongguoError(.format, "红果返回的合集与请求不一致")
        }
        func count(_ value: JSONValue) -> Int? { value.number.flatMap { $0 >= 0 && $0 < 1e15 ? Int($0) : nil } }
        var seen = Set<String>()
        var entries: [OfficialSeriesDetail.Entry] = []
        for item in album["video_detail_list"].array ?? [] {
            guard let id = item["series_id_str"].nonZeroIdString ?? item["series_id"].nonZeroIdString, id.matchesDigits(min: 1, max: 30) else { continue }
            let video = details[id]?["video_data"]["video_list"][0] ?? .null
            let vid = video["vid"].nonZeroIdString.flatMap { $0.matchesDigits(min: 1, max: 30) ? $0 : nil } ?? id
            guard seen.insert(vid).inserted else { continue }
            entries.append(OfficialSeriesDetail.Entry(
                vid: vid, index: entries.count + 1, likes: count(video["digged_count"]),
                disabled: video["disable_play"].bool == true || item["video_list"][0]["disable_play"].bool == true,
                title: AccountService.cleanText(item["series_title"].string)))
        }
        guard !entries.isEmpty else { throw HongguoError(.upstream, "红果合集的分集列表为空") }
        let label = (album["sub_title_list"].array ?? []).compactMap(\.string).first { $0.hasSuffix("集") } ?? "共\(entries.count)集"
        let rawCover = album["cover"].string ?? ""
        let cleanedCover = AccountService.cleanCover(rawCover)
        return OfficialSeriesDetail(
            seriesId: albumId,
            title: AccountService.cleanText(album["title"].string),
            cover: AccountDataAccess.normalizeHTTPSURL(cleanedCover.isEmpty ? rawCover : cleanedCover),
            intro: (album["intro"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            episodeLabel: label,
            episodeCount: max(count(album["episode_cnt"]) ?? 0, entries.count),
            completion: label.hasPrefix("全") ? .completed : (label.hasPrefix("更新") ? .ongoing : .unknown),
            favoriteCount: count(album["followed_cnt"]),
            playCount: nil,
            recordNumber: "",
            episodes: entries)
    }
}

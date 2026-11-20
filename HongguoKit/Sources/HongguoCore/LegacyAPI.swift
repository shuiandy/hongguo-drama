import Foundation

/// The unsigned legacy App endpoints that `hongguo.js` keeps as a fallback.
/// Media from here is CENC encrypted; `PlayInfo.spadeA` carries the key material.
final class LegacyAPI: Sendable {
    static let base = "https://api5-normal-sinfonlineb.fqnovel.com"
    static let commonQuery: [(String, String)] = [
        ("ac", "wifi"), ("channel", "oppo_8662_64"), ("aid", "8662"), ("app_name", "novelread"),
        ("version_code", "71532"), ("version_name", "7.1.5.32"), ("device_platform", "android"), ("os", "android"),
        ("ssmix", "a"), ("device_type", "SM-N9860"), ("device_brand", "Samsung"), ("language", "zh"),
        ("os_api", "28"), ("os_version", "9"), ("manifest_version_code", "71532"), ("resolution", "900*1600"),
        ("dpi", "320"), ("update_version_code", "71532"), ("host_abi", "arm64-v8a"), ("dragon_device_type", "pad"),
        ("pv_player", "71532"), ("compliance_status", "0"), ("need_personal_recommend", "1"), ("player_so_load", "1"),
        ("is_android_pad_screen", "0"), ("rom_version", "PQ3A.190705.10241111+release-keys"),
    ]

    private let http: HTTPClient
    init(http: HTTPClient) { self.http = http }

    func call(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> JSONValue {
        var components = URLComponents(string: Self.base + path)!
        components.queryItems = (Self.commonQuery + [("_rticket", String(Int(Date().timeIntervalSince1970 * 1000)))])
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        var options = HTTPClient.Options()
        options.timeout = timeout
        options.headers = [
            "User-Agent": UserAgents.api,
            "Accept": "application/json; charset=utf-8,application/x-protobuf",
            "Content-Type": "application/json; charset=utf-8",
        ]
        let json = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.post(components.url!, json: json, options: options)
        guard !response.data.isEmpty else {
            let logid = response.header("x-tt-logid").map { " logid=\($0)" } ?? ""
            throw HongguoError(.upstream, "接口返回空响应（HTTP 200，0 字节）\(logid)")
        }
        guard let value = try? JSONValue.parse(response.data) else {
            throw HongguoError(.format, "响应不是合法 JSON（\(response.data.count) 字节）")
        }
        return value
    }

    func episodes(seriesId: String) async throws -> SeriesEpisodes {
        let body: [String: Any] = [
            "biz_param": [
                "detail_page_version": 0, "disable_digg_stat": false,
                "image_shrink_datas_str": "W3siaW1hZ2VfdHlwZSI6MywiaW1hZ2Vfd2lkdGgiOjkwMCwic2hyaW5rX3R5cGUiOjN9LHsiaW1hZ2VfdHlwZSI6NCwiaW1hZ2Vfd2lkdGgiOjcyLCJzaHJpbmtfdHlwZSI6NH1d\n",
                "need_all_video_definition": false, "need_mp4_align": false, "screen_width_px": "900",
                "source": 7, "use_os_player": false, "use_server_dns": false,
            ],
            "dr_scene": "preload",
            "series_id": seriesId,
        ]
        let j = try await call("/novel/player/multi_video_detail/preload/v1", body: body, timeout: 15)
        guard j["code"].number == 0 else { throw HongguoError(.upstream, "detail API 失败") }
        // Never take "the first key": a mismatched response must fail closed.
        let entry = j["data"][seriesId]
        guard !entry.isNull else { throw HongguoError(.format, "备用接口返回的剧集与请求不一致") }
        let vd = entry["video_data"]
        if let sid = vd["series_id"].idString, sid != seriesId { throw HongguoError(.format, "备用接口返回的剧集与请求不一致") }
        let list = vd["video_list"].array ?? []
        if list.contains(where: { $0["series_id"].idString.map { $0 != seriesId } ?? false }) {
            throw HongguoError(.format, "备用接口返回了其他剧集的分集")
        }
        var episodes = list.compactMap { item -> Episode? in
            guard let vid = item["vid"].idString, vid.isDigitsOnly else { return nil }
            return Episode(vid: vid, index: Int(item["vid_index"].number ?? 0), title: item["title"].string ?? "",
                           seriesId: seriesId, webAvailable: nil)
        }
        guard !episodes.isEmpty else { throw HongguoError(.format, "备用接口分集列表为空") }
        episodes.sort { $0.index < $1.index }
        let cover = vd["series_cover"].string ?? vd["cover_url"].string ?? ""
        return SeriesEpisodes(seriesId: seriesId, title: vd["series_title"].string ?? "未命名短剧",
                              cover: HTMLData.safeCover(cover), episodes: episodes, webAccessibleEpisodes: nil, source: .api)
    }

    func playInfo(vid: String) async throws -> PlayInfo {
        let body: [String: Any] = [
            "biz_param": [
                "detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
                "need_all_video_definition": true, "need_mp4_align": false, "use_os_player": false,
                "use_server_dns": false, "video_platform": 1024,
            ],
            "dr_scene": "preload",
            "mixed_video_id_map": ["1004": [vid]],
        ]
        let j = try await call("/novel/player/multi_video_model/preload/v1", body: body, timeout: 6)
        guard let model = j["data"][vid]["video_model"].string, let best = Self.bestStream(model) else {
            throw HongguoError(.unavailable, "暂未取得有效片源")
        }
        return PlayInfo(url: SeriesService.upgradeToHTTPS(best.url), spadeA: best.spadeA, codec: best.codec,
                        source: .api, vid: vid, userAgent: UserAgents.api, referer: nil)
    }

    struct Stream { var url: URL; var spadeA: String?; var codec: String }

    static let definitionLabels: [String: Int] = ["4k": 2160, "2k": 1440, "fhd": 1080, "fullhd": 1080, "hd": 720, "sd": 480, "ld": 360]

    /// Stream choice: H.264 > HEVC > other, then short side, pixels, bitrate.
    static func bestStream(_ model: String) -> Stream? {
        guard let json = try? JSONValue.parse(model) else { return nil }
        let list: [JSONValue]
        switch json["video_list"] {
        case .array(let items): list = items
        case .object(let dict): list = Array(dict.values)
        default: list = []
        }
        func rank(_ codec: String) -> Int {
            if ["h264", "avc", "avc1"].contains(codec) { return 0 }
            if ["h265", "h265_hvc1", "hevc", "hvc1", "hev1", "bytevc1"].contains(codec) { return 1 }
            return 2
        }
        typealias Score = (rank: Int, def: Int, pixels: Int, bitrate: Int)
        func better(_ a: Score, _ b: Score) -> Bool {
            if a.rank != b.rank { return a.rank < b.rank }
            if a.def != b.def { return a.def > b.def }
            if a.pixels != b.pixels { return a.pixels > b.pixels }
            return a.bitrate > b.bitrate
        }
        var best: (Stream, Score)?
        for v in list {
            var url: URL?
            for raw in [v["main_url"].string, v["backup_url"].string].compactMap({ $0 }) {
                if let candidate = URL(string: SeriesService.normalizeVideoURL(raw)), URLGuard.isPublicURL(candidate) {
                    url = candidate
                    break
                }
            }
            guard let url else { continue }
            let meta = v["video_meta"]
            let codec = (meta["codec_type"].string ?? "").lowercased()
            // VideoToolbox cannot decode ByteVC2; skip it instead of failing at playback.
            if codec == "bytevc2" { continue }
            let defString = meta["definition"].string ?? ""
            let labelled: Int? = HTMLData.firstMatch("(\\d+)\\s*p", in: defString).flatMap { Int($0[1]) }
            var def: Int = labelled ?? definitionLabels[defString.lowercased()] ?? 0
            let w = Int(meta["vwidth"].number ?? 0), h = Int(meta["vheight"].number ?? 0)
            if w > 0 && h > 0 { def = min(w, h) }
            let bitrate = Int(meta["bitrate"].number ?? meta["real_bitrate"].number ?? 0)
            let score: Score = (rank(codec), def, w * h, bitrate)
            if best == nil || better(score, best!.1) {
                best = (Stream(url: url, spadeA: v["encrypt_info"]["spade_a"].string, codec: codec), score)
            }
        }
        return best?.0
    }
}

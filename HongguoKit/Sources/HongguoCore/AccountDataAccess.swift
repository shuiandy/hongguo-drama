// SPDX-License-Identifier: GPL-3.0-only
// Account read and write requests using the same host, device identity, signing and login cookie
// as `AccountService.history`: profile, watch history, video bookshelf (collect), likes (digg),
// and reservations (subscribe / remind). No cookie, user id or address is ever logged.
import Foundation

public enum AccountDataAccess {
    /// Read paths beyond the core signer's own list.
    static let extraPaths = [
        "/reading/bookapi/bookshelf/video/list/v1/",
        "/reading/bookapi/bookshelf/video/info/v1/",
        "/reading/bookapi/bookmall/tab/v/",
        "/reading/bookapi/bookmall/cell/change/v",
        "/reading/user/subscribe/list/v1/",
        "/reading/ugc/action/mget/v1/",
    ]

    /// Write paths for two-way sync of bookshelf (favorites), episode likes (digg),
    /// reservations (subscribe / remind), and watch history.
    static let writePaths = [
        "/reading/bookapi/bookshelf/video/update/v1/",
        "/novel/articleapi/do_action/v1/",
        "/reading/bookapi/search/uncover_subscribe/v1/",
        "/reading/user/remind/op/v1/",
        "/reading/user/subscribe/delete/v1/",
        "/reading/bookapi/read_history/update/v1/",
        "/reading/user/event/report",
    ]

    /// Whether a login is saved on this device (the core checks it with the website separately).
    public static var hasSavedLogin: Bool {
        guard !MacTestRunner.isActive else { return false }
        return !PersistentAppDevice.authHeaders().isEmpty
    }

    public struct Profile: Equatable, Sendable {
        public var name: String
        public var avatar: String
    }

    public struct BookshelfVideo: Equatable, Sendable {
        public var seriesId: String
        public var title: String
        public var cover: String
        public var episodeCount: Int
        public var watchedEpisode: Int
        public var collectTime: Double
        public var category: String
    }

    public struct Reservation: Equatable, Sendable {
        public var seriesId: String
        /// Top-level `item_id` from `subscribe_items`, used by `subscribe/delete` and `remind/op`.
        public var subscribeItemId: String
        public var title: String
        public var cover: String
        public var isOnline: Bool
        public var releaseText: String
        public var subtitle: String
        public var heatText: String
        public var category: String
        public var description: String
    }

    public struct LikedVideo: Equatable, Sendable {
        public var seriesId: String
        public var vid: String
        public var title: String
        public var cover: String
        public var episodeIndex: Int
        public var episodeCount: Int
        public var diggedCount: Int
        public var category: String
        public var detail: String
    }

    public struct CategorizedHistory: Equatable, Sendable {
        public var item: AccountHistoryItem
        public var category: String
    }

    static func categoryLabel(contentType: Int, aiUsageType: Int = 0, genre: String = "") -> String {
        if aiUsageType > 0 || genre.localizedCaseInsensitiveContains("ai剧") { return "AI剧" }
        switch contentType {
        case 5: return "高光"
        case 1004: return "漫剧"
        case 1: return "真人剧"
        default: return ""
        }
    }

    /// The account's name and picture inside the app (`/reading/user/info/v1/`).
    public static func profile() async throws -> Profile {
        let data = try checked(try await get(path: "/reading/user/info/v1/"))
        let rawAvatar = [data["avatar_url"].string, data["expand_avatar_url"].string]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return Profile(name: data["user_name"].string ?? "", avatar: normalizeHTTPSURL(rawAvatar))
    }

    /// The account's watch history with each row's shelf category: the same reader as
    /// `AccountService.history` (every page, latest row per series, newest first, device token
    /// sent), so the iOS and Mac apps share one history path and one in-memory copy. Throws when
    /// signed out, so a caller never mistakes that for an empty history.
    public static func historyWithCategories() async throws -> [CategorizedHistory] {
        try await history().map { CategorizedHistory(item: $0, category: $0.category) }
    }

    public static func history() async throws -> [AccountHistoryItem] {
        guard await AccountService.shared.status().profile != nil else { throw HongguoError(.input, "未登录") }
        return try await AccountService.shared.history(refresh: true)
    }

    static func normalizeHTTPSURL(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("//") {
            text = "https:" + text
        } else if text.lowercased().hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        guard text.lowercased().hasPrefix("https://"), URL(string: text) != nil else { return "" }
        return text
    }

    /// Series on the account's video bookshelf, most recently collected first
    /// (`/reading/bookapi/bookshelf/video/list/v1/`). The reply carries ids only.
    public static func bookshelfSeriesIds() async throws -> [String] {
        let data = try checked(try await get(path: "/reading/bookapi/bookshelf/video/list/v1/"))
        let rows = (data["video_shelf_info"].array ?? []).compactMap { row -> (String, Double)? in
            guard let id = row["series_id"].string ?? row["series_id"].idString, !id.isEmpty else { return nil }
            return (id, row["collect_time"].number ?? 0)
        }
        return rows.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Detailed video bookshelf (`/reading/bookapi/bookshelf/video/info/v1/`): returns titles,
    /// covers, episode counts and last watched episode in a single paginated request.
    public static func bookshelfVideos() async throws -> [BookshelfVideo] {
        var all: [BookshelfVideo] = []
        var offset = 0
        for _ in 0..<12 {
            let data = try checked(try await get(path: "/reading/bookapi/bookshelf/video/info/v1/", values: [
                ("offset", String(offset)), ("count", "60"),
            ]))
            let rows = data["video_shelf_info"].array ?? []
            for row in rows {
                let video = row["video_data"]
                let id = video["series_id"].nonZeroIdString ?? row["series_id"].nonZeroIdString ?? ""
                guard id.matchesDigits(min: 1, max: 30) else { continue }
                let title = AccountService.cleanText(
                    row["series_title"].nonEmptyString ?? row["book_name"].nonEmptyString
                    ?? video["series_title"].nonEmptyString ?? video["title"].nonEmptyString
                )
                let rawCover = row["series_cover_url"].nonEmptyString ?? video["cover"].nonEmptyString ?? row["cover"].nonEmptyString ?? ""
                let cleaned = AccountService.cleanCover(rawCover)
                let cover = cleaned.isEmpty ? normalizeHTTPSURL(rawCover) : cleaned
                let total = max(0, video["episode_cnt"].signedInt ?? row["episode_cnt"].signedInt ?? 0)
                let watched = max(0, video["vid_index"].signedInt ?? row["vid_index"].signedInt ?? 0)
                let collectTime = row["collect_time"].number ?? row["last_operate_time"].number ?? 0
                let ct = row["content_type"].signedInt.flatMap { $0 > 0 ? $0 : nil } ?? video["content_type"].signedInt ?? 0
                let aiUsage = max(row["ai_usage_type"].signedInt ?? 0, video["ai_usage_type"].signedInt ?? 0)
                all.append(BookshelfVideo(seriesId: id, title: title.isEmpty ? "剧集 \(id)" : title,
                                          cover: cover, episodeCount: total, watchedEpisode: watched,
                                          collectTime: collectTime, category: categoryLabel(contentType: ct, aiUsageType: aiUsage)))
            }
            let hasMore = data["has_more"].bool == true
            let nextOffset = data["next_offset"].signedInt ?? 0
            guard hasMore, !rows.isEmpty, nextOffset > offset else { break }
            offset = nextOffset
        }
        var seen = Set<String>()
        return all.sorted { $0.collectTime > $1.collectTime }.filter { seen.insert($0.seriesId).inserted }
    }

    /// Both online (`已上线`) and upcoming (`待上线`) series reserved by the account
    /// (`/reading/user/subscribe/list/v1/`). Throws when either list fails, so a caller keeps the
    /// reservations it has instead of replacing them with a partial or empty list.
    public static func reservations() async throws -> [Reservation] {
        async let onlineTask = fetchReservations(isOnline: true)
        async let offlineTask = fetchReservations(isOnline: false)
        let online = try await onlineTask
        let offline = try await offlineTask
        var seen = Set<String>()
        return (online + offline).filter { seen.insert($0.seriesId).inserted }
    }

    private static func fetchReservations(isOnline: Bool) async throws -> [Reservation] {
        var all: [Reservation] = []
        var offset = 0
        var sessionId = ""
        var shanghaiCalendar = Calendar(identifier: .gregorian)
        shanghaiCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        for _ in 0..<12 {
            var values: [(String, String)] = [
                ("offset", String(offset)), ("limit", "50"), ("is_online", isOnline ? "true" : "false"),
            ]
            if !sessionId.isEmpty { values.append(("session_id", sessionId)) }
            let data = try checked(try await get(path: "/reading/user/subscribe/list/v1/", values: values))
            let rows = data["subscribe_items"].array ?? []
            for row in rows {
                let subData = row["subscribe_data"]
                let subDetail = subData["video_detail"]
                let id = subData["series_id"].nonZeroIdString
                    ?? subDetail["series_id_str"].nonZeroIdString
                    ?? subDetail["series_id"].nonZeroIdString
                    ?? row["series_id"].nonZeroIdString
                    ?? row["item_id"].nonZeroIdString
                    ?? row["book_id"].nonZeroIdString ?? ""
                guard id.matchesDigits(min: 1, max: 30) else { continue }
                let title = AccountService.cleanText(
                    subDetail["series_title"].nonEmptyString
                    ?? subData["title"].nonEmptyString
                    ?? row["name"].nonEmptyString
                    ?? row["series_title"].nonEmptyString
                    ?? row["book_name"].nonEmptyString
                )
                let rawCover = [
                    subDetail["series_cover"].string,
                    subData["cover"].string,
                    row["cover"].string,
                    row["series_cover_url"].string,
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                let cleaned = AccountService.cleanCover(rawCover)
                let cover = cleaned.isEmpty ? normalizeHTTPSURL(rawCover) : cleaned
                let rowOnline = row["is_online"].bool ?? isOnline
                let tagText = AccountService.cleanText(row["tag_info"]["text"].string)
                let recText = AccountService.cleanText(row["expected_rec_text"].nonEmptyString ?? row["recommend_info"].nonEmptyString)
                let cats = (row["categories"].array ?? []).compactMap(\.nonEmptyString)
                let catLine = cats.isEmpty ? AccountService.cleanText(row["category"].string) : cats.prefix(2).joined(separator: "·")
                let releaseText: String
                if !recText.isEmpty {
                    releaseText = recText
                } else if !tagText.isEmpty {
                    releaseText = tagText
                } else if rowOnline {
                    releaseText = "已上线"
                } else if let ts = row["schedule_publish_time"].number ?? row["expected_publish_time"].number, ts > 1_000_000_000 {
                    let date = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
                    let comps = shanghaiCalendar.dateComponents([.month, .day], from: date)
                    releaseText = "\(comps.month ?? 1)月\(comps.day ?? 1)日上线"
                } else {
                    releaseText = "待上线"
                }
                let subtitle = rowOnline ? (catLine.isEmpty ? releaseText : catLine) : releaseText
                let heatText: String = {
                    let infos = subDetail["secondary_infos"].array ?? []
                    if let hit = infos.first(where: { $0["data_type"].signedInt == 27 })?["content"].string
                        ?? infos.first(where: { ($0["content"].string ?? "").contains("热度") })?["content"].string {
                        return AccountService.cleanText(hit)
                    }
                    return ""
                }()
                let ct = subData["content_type"].signedInt.flatMap { $0 > 0 ? $0 : nil }
                    ?? subDetail["content_type"].signedInt.flatMap { $0 > 0 ? $0 : nil }
                    ?? row["content_type"].signedInt ?? 0
                let aiUsage = max(subData["ai_usage_type"].signedInt ?? 0, subDetail["ai_usage_type"].signedInt ?? 0)
                let desc = AccountService.cleanText(subDetail["series_intro"].nonEmptyString ?? subData["video_desc"].nonEmptyString ?? row["item_desc"].nonEmptyString)
                let subItemId = row["item_id"].nonZeroIdString ?? id
                all.append(Reservation(seriesId: id, subscribeItemId: subItemId,
                                       title: title.isEmpty ? "剧集 \(id)" : title,
                                       cover: cover, isOnline: rowOnline, releaseText: releaseText,
                                       subtitle: subtitle, heatText: heatText,
                                       category: categoryLabel(contentType: ct, aiUsageType: aiUsage), description: desc))
            }
            let hasMore = data["has_more"].bool == true
            let nextOffset = data["next_offset"].signedInt ?? 0
            if let sid = data["session_id"].nonEmptyString { sessionId = sid }
            guard hasMore, !rows.isEmpty, nextOffset > offset else { break }
            offset = nextOffset
        }
        return all
    }

    /// Liked series/videos on the account (`/reading/ugc/action/mget/v1/` with `action_type=3`).
    public static func likedVideos(userId: String) async throws -> [LikedVideo] {
        var all: [LikedVideo] = []
        var offset = 0
        let objectTypes = (1...35).map(String.init).joined(separator: ",")
        for _ in 0..<12 {
            var values: [(String, String)] = [
                ("offset", String(offset)), ("count", "50"), ("action_type", "3"),
                ("object_type_list", objectTypes),
            ]
            if !userId.isEmpty { values.append(("target_user_id", userId)) }
            let data = try checked(try await get(path: "/reading/ugc/action/mget/v1/", values: values))
            let rows = data["mixed_data_list"].array ?? []
            for row in rows {
                let video = row["video_data"]
                let detailObj = video["video_detail"]
                let id = video["series_id"].nonZeroIdString ?? detailObj["series_id_str"].nonZeroIdString ?? detailObj["series_id"].nonZeroIdString ?? ""
                guard id.matchesDigits(min: 1, max: 30) else { continue }
                let vid = video["vid"].nonZeroIdString ?? ""
                let title = AccountService.cleanText(detailObj["series_title"].nonEmptyString ?? video["title"].nonEmptyString)
                let rawCover = [detailObj["series_cover"].string, video["cover"].string, video["scene_cover"].string]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                let cleaned = AccountService.cleanCover(rawCover)
                let cover = cleaned.isEmpty ? normalizeHTTPSURL(rawCover) : cleaned
                let total = max(0, video["episode_cnt"].signedInt ?? detailObj["episode_cnt"].signedInt ?? 0)
                let ep = max(0, video["vid_index"].signedInt ?? 0)
                let diggs = max(0, video["digged_count"].signedInt ?? 0)
                let ct = video["content_type"].signedInt.flatMap { $0 > 0 ? $0 : nil } ?? detailObj["content_type"].signedInt ?? 0
                let aiUsage = max(video["ai_usage_type"].signedInt ?? 0, detailObj["ai_usage_type"].signedInt ?? 0)
                let detail = ep > 0 ? "第\(ep)集" : (total > 0 ? "全\(total)集" : "已赞")
                all.append(LikedVideo(seriesId: id, vid: vid, title: title.isEmpty ? "剧集 \(id)" : title,
                                      cover: cover, episodeIndex: ep, episodeCount: total,
                                      diggedCount: diggs,
                                      category: categoryLabel(contentType: ct, aiUsageType: aiUsage),
                                      detail: detail))
            }
            let hasMore = data["has_more"].bool == true
            let nextOffset = data["next_offset"].signedInt ?? 0
            guard hasMore, !rows.isEmpty, nextOffset > offset else { break }
            offset = nextOffset
        }
        var seen = Set<String>()
        return all.filter { seen.insert("\($0.seriesId):\($0.vid.isEmpty ? String($0.episodeIndex) : $0.vid)").inserted }
    }

    /// Optional diagnostic logger for write sync responses (status/code/message only; never PII).
    public static var onWriteLog: (@Sendable (String) -> Void)?

    // MARK: - Account Writes (Two-Way Sync)

    /// Adds (`video_shelf_operate_type=0`) or removes (`video_shelf_operate_type=1`) a series on
    /// the account's video bookshelf (`/reading/bookapi/bookshelf/video/update/v1/`).
    public static func setBookshelfVideo(accountId: String? = nil, seriesId: String, collected: Bool) async throws {
        guard seriesId.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "剧集 ID 无效") }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let body: [String: Any] = [
            "update_bookshelf_video_list": [[
                "book_id": seriesId,
                "modify_time": nowMs,
                "video_shelf_operate_type": collected ? 0 : 1,
                "book_type": 2,
            ]],
        ]
        _ = try checkedWrite(path: "/reading/bookapi/bookshelf/video/update/v1/",
                             try await post(accountId: accountId, path: "/reading/bookapi/bookshelf/video/update/v1/", body: body))
    }

    /// Likes (`action_type=3`) or unlikes (`action_type=4`) an episode (`/novel/articleapi/do_action/v1/`).
    public static func setEpisodeDigg(accountId: String? = nil, vid: String, seriesId: String, liked: Bool) async throws {
        guard vid.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "分集 ID 无效") }
        var businessParam: [String: Any] = ["video_id": vid]
        if let bookIdNum = Int64(seriesId), seriesId.matchesDigits(min: 1, max: 30) {
            businessParam["book_id"] = bookIdNum
        }
        let body: [String: Any] = [
            "object_id": vid,
            "object_type": 6,
            "action_type": liked ? 3 : 4,
            "action_category": 1,
            "action_reason_remark": "like_click",
            "business_param": businessParam,
        ]
        _ = try checkedWrite(path: "/novel/articleapi/do_action/v1/",
                             try await post(accountId: accountId, path: "/novel/articleapi/do_action/v1/", body: body))
    }

    /// Reserves (`op_type=1`) or cancels (`op_type=2`) an upcoming series
    /// (`/reading/bookapi/search/uncover_subscribe/v1/`).
    public static func setReservation(accountId: String? = nil, itemId: String, reserved: Bool) async throws {
        guard itemId.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "预约 ID 无效") }
        let body: [String: Any] = [
            "item_id": 0,
            "item_id_str": itemId,
            "item_type": 1,
            "op_type": reserved ? 1 : 2,
        ]
        _ = try checkedWrite(path: "/reading/bookapi/search/uncover_subscribe/v1/",
                             try await post(accountId: accountId, path: "/reading/bookapi/search/uncover_subscribe/v1/", body: body))
    }

    /// Adds (`op_type=1`) or cancels (`op_type=2`) an upcoming release reminder (`/reading/user/remind/op/v1/`).
    public static func setReservationRemind(accountId: String? = nil, itemId: String, reserved: Bool) async throws {
        guard itemId.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "预约 ID 无效") }
        let body: [String: Any] = [
            "remind_item_type": "online",
            "remind_item_list": [itemId],
            "op_type": reserved ? 1 : 2,
        ]
        _ = try checkedWrite(path: "/reading/user/remind/op/v1/",
                             try await post(accountId: accountId, path: "/reading/user/remind/op/v1/", body: body))
    }

    /// Deletes an entry from the user's reservation list (`/reading/user/subscribe/delete/v1/`).
    public static func deleteReservation(accountId: String? = nil, itemId: String, isOnline: Bool) async throws {
        guard itemId.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "预约 ID 无效") }
        let body: [String: Any] = [
            "item_id": [itemId],
            "all_select": false,
            "not_del_item_id": [String](),
            "is_online": isOnline,
        ]
        _ = try checkedWrite(path: "/reading/user/subscribe/delete/v1/",
                             try await post(accountId: accountId, path: "/reading/user/subscribe/delete/v1/", body: body))
    }

    /// Reports negative recommendation feedback ("不感兴趣") or recall ("撤销") to the official
    /// user event endpoint (`/reading/user/event/report`). Best-effort when signed in.
    public static func reportNotInterested(accountId: String? = nil, seriesId: String, recall: Bool = false) async throws {
        guard seriesId.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "剧集 ID 无效") }
        let nowSec = Int64(Date().timeIntervalSince1970)
        let eventName = recall ? "dislike_recall" : "rt_dislike"
        let body: [String: Any] = [
            "event_type": eventName,
            "events": [
                [
                    "event_type": eventName,
                    "book_id": seriesId,
                    "book_type": 2,
                    "scene": "video_feed",
                    "timestamp": nowSec,
                ]
            ],
        ]
        _ = try checkedWrite(path: "/reading/user/event/report",
                             try await post(accountId: accountId, path: "/reading/user/event/report", body: body))
    }

    /// Uploads or soft-deletes a watch history entry (`/reading/bookapi/read_history/update/v1/`).
    public static func uploadReadHistory(
        accountId: String? = nil,
        seriesId: String,
        vid: String,
        episodeIndex: Int,
        positionSeconds: Double,
        durationSeconds: Double = 0,
        delete: Bool = false
    ) async throws {
        guard let bookIdNum = Int64(seriesId), seriesId.matchesDigits(min: 1, max: 30) else {
            throw HongguoError(.input, "剧集 ID 无效")
        }
        // Collection videos: the official history shape for them is not known, so nothing is written.
        if UGCVideos.contains(vid) { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var entry: [String: Any] = [
            "book_id": bookIdNum,
            "book_id_str": seriesId,
            "book_type": 2,
            "vid_index": max(1, episodeIndex),
            "current_play_position": Int64(max(0, positionSeconds) * 1000),
            "read_timestamp_ms": nowMs,
            "update_timestamp_ms": nowMs,
            "is_delete": delete,
        ]
        if durationSeconds > 0 {
            entry["duration"] = Int64(durationSeconds * 1000)
        }
        if let vidNum = Int64(vid), vid.matchesDigits(min: 1, max: 30) {
            entry["vid"] = vidNum
        }
        let body: [String: Any] = ["update_datas": [entry]]
        _ = try checkedWrite(path: "/reading/bookapi/read_history/update/v1/",
                             try await post(accountId: accountId, path: "/reading/bookapi/read_history/update/v1/", body: body))
    }

    private static func checkedWrite(path: String, _ payload: JSONValue) throws -> JSONValue {
        let code = payload["code"].signedInt ?? payload["err_no"].signedInt ?? -1
        let msg = AccountService.cleanText(payload["message"].string ?? payload["err_tips"].string ?? payload["msg"].string)
        onWriteLog?("sync POST \(path) code=\(code) msg=\(msg.prefix(80))")
        guard code == 0 else {
            throw HongguoError(.upstream, msg.isEmpty ? "账号接口暂时不可用" : msg)
        }
        return payload["data"]
    }

    private static func checked(_ payload: JSONValue) throws -> JSONValue {
        let code = payload["code"].signedInt ?? payload["err_no"].signedInt ?? -1
        guard code == 0 else {
            let msg = AccountService.cleanText(payload["message"].string ?? payload["err_tips"].string)
            throw HongguoError(.upstream, msg.isEmpty ? "账号接口暂时不可用" : msg)
        }
        return payload["data"]
    }

    /// One signed GET with the saved login. Throws when signed out.
    public static func get(path: String, values: [(String, String)] = []) async throws -> JSONValue {
        guard !MacTestRunner.isActive, let saved = try KeychainCredentialStore().load() else { throw HongguoError(.input, "未登录") }
        let transport = AppTransport(http: .shared)
        let (identity, dToken) = try await PersistentAppDevice.dataIdentity(transport: transport)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let signed = AppLegacySigner.accountPaths.contains(path)
            ? try AppLegacySigner.shared.account(path: path, values: values, identity: identity, dToken: dToken, nowMillis: now)
            : try AppLegacySigner.shared.accountRead(path: path, values: values, identity: identity, dToken: dToken, nowMillis: now)
        do {
            return try await transport.requestJSON(signed.url, headers: signed.headers + [("Cookie", saved.cookie)],
                                                   deadline: Date().addingTimeInterval(12))
        } catch let error as AppSourceError {
            if error.status == 401 {
                Task { await AccountService.shared.notifyPossibleAuthFailure() }
            }
            throw error.hongguoError
        }
    }

    /// One signed POST with JSON body and the saved login. Throws when signed out.
    public static func post(accountId: String? = nil, path: String, values: [(String, String)] = [], body: [String: Any]) async throws -> JSONValue {
        guard !MacTestRunner.isActive, let saved = try KeychainCredentialStore().load() else { throw HongguoError(.input, "未登录") }
        if let accountId, saved.profile?.id != accountId { throw HongguoError(.cancelled, "账号已切换") }
        try Task.checkCancellation()
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let payload = Array(encoded)
        let transport = AppTransport(http: .shared)
        let (identity, dToken) = try await PersistentAppDevice.dataIdentity(transport: transport)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let signed = try AppLegacySigner.shared.accountWrite(path: path, values: values, payload: payload,
                                                             identity: identity, dToken: dToken, nowMillis: now)
        do {
            return try await transport.requestJSON(signed.url, method: "POST",
                                                   headers: signed.headers + [("Cookie", saved.cookie)],
                                                   body: payload,
                                                   deadline: Date().addingTimeInterval(12))
        } catch let error as AppSourceError {
            if error.status == 401 {
                Task { await AccountService.shared.notifyPossibleAuthFailure() }
            }
            onWriteLog?("sync POST \(path) error=\(error.message.prefix(100))")
            throw error.hongguoError
        }
    }

    /// The shape of a reply: field names, types and list lengths, never a value (except the
    /// top-level status code and message). For working out a parser without seeing the data.
    public static func shape(of value: JSONValue, depth: Int = 0, limit: Int = 6) -> String {
        let pad = String(repeating: "  ", count: depth)
        switch value {
        case .null: return "null"
        case .bool: return "bool"
        case .int, .double: return "number"
        case .string(let text): return text.isEmpty ? "string(empty)" : "string"
        case .array(let items):
            guard let first = items.first, depth < limit else { return "array[\(items.count)]" }
            return "array[\(items.count)] of " + shape(of: first, depth: depth, limit: limit)
        case .object(let fields):
            guard depth < limit else { return "object{\(fields.count)}" }
            let lines = fields.keys.sorted().map { key -> String in
                var text = "\(pad)  \(key): \(shape(of: fields[key] ?? .null, depth: depth + 1, limit: limit))"
                if depth <= 1, ["code", "message", "msg", "err_no", "err_tips", "debug_info", "StatusCode", "StatusMessage"].contains(key) {
                    switch fields[key] ?? .null {
                    case .int(let number): text += " = \(number)"
                    case .string(let string): text += " = \(string.prefix(120))"
                    default: break
                    }
                }
                return text
            }
            return "object{\n" + lines.joined(separator: "\n") + "\n\(pad)}"
        }
    }

    /// Asks each read-only account endpoint once and describes what came back.
    public static func probe() async -> String {
        let userId = (try? await get(path: "/reading/user/info/v1/"))?["data"]["user_id"].idString ?? ""
        let requests: [(String, String, [(String, String)])] = [
            ("profile", "/reading/user/info/v1/", []),
            ("read_history", "/reading/bookapi/read_history/list/v1/",
             [("book_type", "2"), ("limit", "0"), ("offset", "0"), ("last_min_read_timestamp_ms", "0"),
              ("full_field", "true"), ("is_first_load", "true"), ("query_soft_deleted", "false")]),
            ("bookshelf_info", "/reading/bookapi/bookshelf/video/info/v1/", [("offset", "0"), ("count", "60")]),
            ("subscribe_online", "/reading/user/subscribe/list/v1/", [("offset", "0"), ("limit", "50"), ("is_online", "true")]),
            ("subscribe_offline", "/reading/user/subscribe/list/v1/", [("offset", "0"), ("limit", "50"), ("is_online", "false")]),
            ("liked_videos", "/reading/ugc/action/mget/v1/",
             [("offset", "0"), ("count", "50"), ("action_type", "3"),
              ("object_type_list", (1...35).map(String.init).joined(separator: ",")), ("target_user_id", userId)]),
            ("feed tab 16", "/reading/bookapi/bookmall/tab/v/",
             [("tab_type", "16"), ("offset", "0"), ("client_req_type", "0"), ("bottom_tab_type", "7")]),
            ("feed tab 39", "/reading/bookapi/bookmall/tab/v/",
             [("tab_type", "39"), ("offset", "0"), ("client_req_type", "0"), ("bottom_tab_type", "7")]),
        ]
        var report = ""
        for (name, path, values) in requests {
            report += "== \(name)\n"
            do {
                report += shape(of: try await get(path: path, values: values)) + "\n"
            } catch {
                report += "failed: \((error as? HongguoError)?.message ?? "\(type(of: error))")\n"
            }
        }
        return report
    }
}

extension AppLegacySigner {
    /// `account(path:values:identity:nowMillis:)` for the read-only paths in
    /// `AccountDataAccess.extraPaths`: the same device fields, version (`currentVersionName`) and headers.
    func accountRead(path: String, values: [(String, String)], identity: PlaybackIdentity, dToken: String = "", nowMillis: Int64) throws -> Signed {
        guard AccountDataAccess.extraPaths.contains(path) else { throw HongguoError(.input, "不支持的账号接口") }
        return try signedRead(host: Self.accountHost, path: path, values: values, identity: identity, dToken: dToken, nowMillis: nowMillis)
    }

    /// The signed-out series detail read (`OfficialSeriesDetail`), on the host the probe verified.
    func videoTab(path: String, values: [(String, String)], identity: PlaybackIdentity, dToken: String, nowMillis: Int64) throws -> Signed {
        guard path == OfficialSeriesDetail.path else { throw HongguoError(.input, "不支持的剧集接口") }
        return try signedRead(host: "https://api5-normal-sinfonlineb.fqnovel.com", path: path, values: values,
                              identity: identity, dToken: dToken, nowMillis: nowMillis)
    }

    /// A GET with the legacy query signature, the registered device and its token.
    private func signedRead(host: String, path: String, values: [(String, String)], identity: PlaybackIdentity, dToken: String, nowMillis: Int64) throws -> Signed {
        let device = Self.merged(Self.versioned(Self.currentVersionCode, Self.currentVersionName),
                                 [("iid", identity.iid), ("device_id", identity.deviceId), ("cdid", identity.cdid)])
        let ts = UInt32(nowMillis / 1000)
        let fields = Self.merged(values, device)
        for n in 0..<128 {
            let ticket = String(nowMillis + Int64(n))
            let query = AppCrypto.encodeQuery(fields + [("ts", String(ts)), ("_rticket", ticket)])
            let url = "\(host)\(path)?\(query)"
            guard Self.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: [UInt8](repeating: 0, count: 16), ts: ts) == 0 else { continue }
            let headers: [(String, String)] = [
                ("User-Agent", Self.currentSearchUA), ("Accept", "application/json; charset=utf-8,application/x-protobuf"),
                ("x-ss-req-ticket", ticket), ("x-tt-request-tag", "t=0;n=0"), ("sdk-version", "2"),
                ("passport-sdk-version", "50561"), ("x-xs-from-web", "0"), ("x-khronos", String(ts)),
                ("x-ladon", AppCrypto.base64(AppCrypto.be32Bytes(ts))), ("x-argus", AppCrypto.base64(AppCrypto.le32(ts))),
                ("x-gorgon", Self.xGorgon(query: query, body: nil, ts: ts, random: random32() >> 16)), ("x-helios", helios(ts: ts)),
                ("x-medusa", try medusa(url: url, body: nil, ts: ts, deviceId: identity.deviceId, versionName: Self.currentVersionName, nowMillis: nowMillis)),
                ("x-tt-dt", dToken),
            ]
            return Signed(url: url, query: query, headers: headers, body: nil)
        }
        throw HongguoError(.format, "无法生成账号请求签名")
    }

    /// Signed POST with JSON body for the write paths in `AccountDataAccess.writePaths`.
    func accountWrite(path: String, values: [(String, String)], payload: [UInt8], identity: PlaybackIdentity, dToken: String = "", nowMillis: Int64) throws -> Signed {
        guard AccountDataAccess.writePaths.contains(path) else { throw HongguoError(.input, "不支持的账号写入接口") }
        let device = Self.merged(Self.versioned(Self.currentVersionCode, Self.currentVersionName),
                                 [("iid", identity.iid), ("device_id", identity.deviceId), ("cdid", identity.cdid)])
        let ts = UInt32(nowMillis / 1000)
        let bodyMd5 = AppCrypto.md5(payload)
        let fields = Self.merged(values, device)
        for n in 0..<128 {
            let ticket = String(nowMillis + Int64(n))
            let query = AppCrypto.encodeQuery(fields + [("ts", String(ts)), ("_rticket", ticket)])
            let url = "\(Self.accountHost)\(path)?\(query)"
            guard Self.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: bodyMd5, ts: ts) == 0 else { continue }
            let headers: [(String, String)] = [
                ("User-Agent", Self.currentSearchUA), ("Accept", "application/json"), ("Accept-Encoding", "identity"),
                ("Content-Type", "application/json; charset=utf-8"),
                ("x-ss-stub", AppCrypto.hex(bodyMd5, uppercase: true)),
                ("x-ss-dp", "8662"), ("x-tt-store-region", "cn"), ("x-tt-store-region-src", "did"),
                ("x-ss-req-ticket", ticket), ("x-tt-request-tag", "t=0;n=0"), ("sdk-version", "2"),
                ("passport-sdk-version", "50561"), ("x-xs-from-web", "0"), ("x-khronos", String(ts)),
                ("x-ladon", AppCrypto.base64(AppCrypto.be32Bytes(ts))), ("x-argus", AppCrypto.base64(AppCrypto.le32(ts))),
                ("x-gorgon", Self.xGorgon(query: query, body: payload, ts: ts, random: random32() >> 16)), ("x-helios", helios(ts: ts)),
                ("x-medusa", try medusa(url: url, body: payload, ts: ts, deviceId: identity.deviceId, versionName: Self.currentVersionName, nowMillis: nowMillis)),
                ("x-tt-dt", dToken),
            ]
            return Signed(url: url, query: query, headers: headers, body: payload)
        }
        throw HongguoError(.format, "无法生成账号写入请求签名")
    }
}

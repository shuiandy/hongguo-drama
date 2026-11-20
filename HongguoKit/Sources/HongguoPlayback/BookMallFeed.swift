import Foundation
import HongguoCore

/// Channel mapping to `BookstoreTabType` on `/reading/bookapi/bookmall/tab/v/`.
public enum BookMallFeedChannel: String, Sendable, CaseIterable {
    /// 找剧 / 全部推荐 (`BookstoreTabType.video_episode`)
    case recommend
    /// 真人剧 (`BookstoreTabType.real_person_series`)
    case liveAction
    /// 漫剧 (`BookstoreTabType.comic_series`)
    case comic

    public var tabType: Int {
        switch self {
        case .recommend: return 8
        case .liveAction: return 38
        case .comic: return 32
        }
    }
}

/// Session and client-side deduplication parameters forwarded to `/reading/bookapi/bookmall/tab/v/`
/// and `/reading/bookapi/bookmall/cell/change/v`, matching the official 7.4.3 iOS app.
public struct BookMallFeedContext: Sendable, Equatable {
    /// `0` = cold start / initial load, `1` = explicit pull/tap refresh.
    public var clientReqType: Int
    /// Session UUID rotated on launch and on explicit refresh.
    public var sessionUuid: String
    /// Most recently exposed series IDs (`recent_impr_gid`), comma-joined when sent.
    public var recentImprGids: [String]
    /// Series IDs to force-filter out (`force_filter_ids`, e.g. recently seen + disliked).
    public var forceFilterIds: [String]

    public static let initial = BookMallFeedContext(clientReqType: 0, sessionUuid: "", recentImprGids: [], forceFilterIds: [])

    public init(clientReqType: Int = 0, sessionUuid: String = "", recentImprGids: [String] = [], forceFilterIds: [String] = []) {
        self.clientReqType = clientReqType
        self.sessionUuid = sessionUuid
        self.recentImprGids = recentImprGids
        self.forceFilterIds = forceFilterIds
    }
}

/// Official home recommendation feed backed by `GET /reading/bookapi/bookmall/tab/v/`
/// for page 1 and `GET /reading/bookapi/bookmall/cell/change/v` for subsequent pages.
public enum BookMallFeed {
    public static let defaultHost = "https://reading.snssdk.com"

    public static func tabQuery(channel: BookMallFeedChannel, context: BookMallFeedContext = .initial) -> [(String, String)] {
        var values: [(String, String)] = [
            ("tab_type", String(channel.tabType)),
            ("offset", "0"),
            ("client_req_type", String(context.clientReqType)),
            ("bottom_tab_type", "4"),
        ]
        if !context.sessionUuid.isEmpty {
            values.append(("session_uuid", context.sessionUuid))
        }
        let recent = context.recentImprGids.prefix(30).joined(separator: ",")
        if !recent.isEmpty {
            values.append(("recent_impr_gid", recent))
        }
        let forceFilter = context.forceFilterIds.prefix(30).joined(separator: ",")
        if !forceFilter.isEmpty {
            values.append(("force_filter_ids", forceFilter))
        }
        return values
    }

    public static func cellChangeQuery(channel: BookMallFeedChannel, cursor: AppFeedCursor, context: BookMallFeedContext = .initial) -> [(String, String)] {
        var values: [(String, String)] = [
            ("cell_id", cursor.cellId),
            ("offset", String(cursor.offset)),
            ("tab_type", String(channel.tabType)),
            ("change_type", "1"),
        ]
        if !cursor.sessionId.isEmpty {
            values.append(("session_id", cursor.sessionId))
        }
        if !context.sessionUuid.isEmpty {
            values.append(("session_uuid", context.sessionUuid))
        }
        let forceFilter = context.forceFilterIds.prefix(30).joined(separator: ",")
        if !forceFilter.isEmpty {
            values.append(("force_filter_ids", forceFilter))
        }
        return values
    }

    /// The official app's own 推荐 page (the vertical video feed) is tab 16; signed out, the
    /// app shows 找剧 (tab 8) in its place.
    public static let accountRecommendTab = 16

    /// The feed as the signed-in account sees it: the same two requests, signed like the
    /// account's watch history and carrying its login. 推荐 asks for tab 16.
    public static func accountPage(
        channel: BookMallFeedChannel,
        cursor: AppFeedCursor = .first,
        context: BookMallFeedContext = .initial
    ) async throws -> AppFeedPage {
        let tabType = channel == .recommend ? accountRecommendTab : channel.tabType
        if cursor.cellId.isEmpty {
            var values = tabQuery(channel: channel, context: context)
            values[0] = ("tab_type", String(tabType))
            let payload = try await AccountDataAccess.get(path: "/reading/bookapi/bookmall/tab/v/", values: values)
            return try parseTab(payload, tabType: tabType)
        }
        var values = cellChangeQuery(channel: channel, cursor: cursor, context: context)
        if let at = values.firstIndex(where: { $0.0 == "tab_type" }) { values[at] = ("tab_type", String(tabType)) }
        let payload = try await AccountDataAccess.get(path: "/reading/bookapi/bookmall/cell/change/v", values: values)
        return try parseCellChange(payload, after: cursor)
    }

    public static func page(
        channel: BookMallFeedChannel,
        cursor: AppFeedCursor = .first,
        context: BookMallFeedContext = .initial
    ) async throws -> AppFeedPage {
        if cursor.cellId.isEmpty {
            let payload = try await AppBookMallAccess.tab(values: tabQuery(channel: channel, context: context), host: defaultHost)
            return try parseTab(payload, channel: channel)
        }
        let payload = try await AppCatalogueAccess.cellChange(values: cellChangeQuery(channel: channel, cursor: cursor, context: context))
        return try parseCellChange(payload, after: cursor)
    }

    /// Parses the initial response from `/reading/bookapi/bookmall/tab/v/`.
    public static func parseTab(_ payload: JSONValue, channel: BookMallFeedChannel) throws -> AppFeedPage {
        try parseTab(payload, tabType: channel.tabType)
    }

    public static func parseTab(_ payload: JSONValue, tabType: Int) throws -> AppFeedPage {
        guard payload.object != nil else { throw HongguoError(.format, "推荐信息流返回了空响应") }
        guard AppFeed.integer(payload["code"]) == 0 else { throw HongguoError(.upstream, "推荐信息流服务暂不可用") }
        guard let tabs = payload["data"]["tab_item"].array else {
            throw HongguoError(.format, "推荐信息流数据结构异常")
        }
        let tab = tabs.first(where: { AppFeed.integer($0["tab_type"]) == tabType && !($0["cell_data"].array ?? []).isEmpty })
            ?? tabs.first(where: { !($0["cell_data"].array ?? []).isEmpty })
        guard let tab, let cells = tab["cell_data"].array else {
            return AppFeedPage(entries: [], next: nil)
        }

        let sessionId = validSessionId(tab["session_id"])
        var seen = Set<String>()
        var entries: [AppFeedEntry] = []
        var feedCellId = ""
        var feedNextOffset: Int?

        for cell in cells {
            let nested = cell["cell_data"].array ?? []
            var cellHasVideo = false
            for item in nested {
                for row in item["video_data"].array ?? [] {
                    if let entry = AppFeed.parseEntry(row, seen: &seen) {
                        entries.append(entry)
                        cellHasVideo = true
                    }
                }
            }
            if cellHasVideo, feedCellId.isEmpty {
                feedCellId = cell["cell_id_str"].string ?? cell["cell_id"].idString ?? ""
                feedNextOffset = AppFeed.integer(cell["next_offset"])
            }
        }

        SeriesCredits.shared.save()
        var next: AppFeedCursor?
        if !feedCellId.isEmpty, let offset = feedNextOffset, offset > 0, let sessionId {
            next = AppFeedCursor(offset: offset, sessionId: sessionId, cellId: feedCellId)
        }
        return AppFeedPage(entries: entries, next: next)
    }

    /// Parses a load-more response from `/reading/bookapi/bookmall/cell/change/v`.
    public static func parseCellChange(_ payload: JSONValue, after cursor: AppFeedCursor) throws -> AppFeedPage {
        guard payload.object != nil else { throw HongguoError(.format, "推荐信息流翻页返回了空响应") }
        guard AppFeed.integer(payload["code"]) == 0 else { throw HongguoError(.upstream, "推荐信息流翻页暂不可用") }
        let data = payload["data"]
        guard let items = data["cell_view"]["cell_data"].array ?? data["cell_data"].array else {
            throw HongguoError(.format, "推荐信息流翻页数据结构异常")
        }

        var seen = Set<String>()
        var entries: [AppFeedEntry] = []
        for item in items {
            for row in item["video_data"].array ?? [] {
                if let entry = AppFeed.parseEntry(row, seen: &seen) {
                    entries.append(entry)
                }
            }
        }

        SeriesCredits.shared.save()
        var next: AppFeedCursor?
        let session = validSessionId(data["session_id"]) ?? (cursor.sessionId.isEmpty ? nil : cursor.sessionId)
        if data["has_more"].bool == true,
           let offset = AppFeed.integer(data["next_offset"]),
           offset > cursor.offset,
           let session,
           !cursor.cellId.isEmpty {
            next = AppFeedCursor(offset: offset, sessionId: session, cellId: cursor.cellId)
        }
        return AppFeedPage(entries: entries, next: next)
    }

    private static func validSessionId(_ value: JSONValue) -> String? {
        guard let session = value.string ?? value.idString, !session.isEmpty, session.count <= 4096 else {
            return nil
        }
        return session
    }
}

import Foundation
import HongguoCore

/// Channel mapping to `BookstoreTabType` on `/reading/bookapi/bookmall/tab/v/` under the official
/// 7.4.3 iOS home vertical video feed (`BottomTabBarItemType.VideoSeriesFeedTab`, `bottom_tab_type=7`).
public enum BookMallFeedChannel: String, Sendable, CaseIterable {
    /// 推荐 (`BookstoreTabType.video_feed`)
    case recommend
    /// 真人剧 (`BookstoreTabType.real_person_feed`)
    case liveAction
    /// 漫剧 (`BookstoreTabType.motion_comic_feed`)
    case comic

    public var tabType: Int {
        switch self {
        case .recommend: return 16
        case .liveAction: return 39
        case .comic: return 36
        }
    }

    var contentFilter: AppFeed.ContentFilter {
        switch self {
        case .recommend: return .anyShortDrama
        case .liveAction: return .liveActionOnly
        case .comic: return .comicOnly
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

/// Official home vertical video feed backed by `GET /reading/bookapi/bookmall/tab/v/`
/// for page 1 and `GET /reading/bookapi/bookmall/cell/change/v` for subsequent pages.
public enum BookMallFeed {
    public static let defaultHost = "https://reading.snssdk.com"
    /// `BottomTabBarItemType.VideoSeriesFeedTab` in the official 7.4.3 iOS binary.
    public static let feedBottomTabType = 7
    /// Retained for source compatibility; `BookMallFeedChannel.recommend.tabType` is also 16.
    public static let accountRecommendTab = 16

    public static func tabQuery(channel: BookMallFeedChannel, context: BookMallFeedContext = .initial) -> [(String, String)] {
        var values: [(String, String)] = [
            ("tab_type", String(channel.tabType)),
            ("offset", "0"),
            ("client_req_type", String(context.clientReqType)),
            ("bottom_tab_type", String(feedBottomTabType)),
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
            ("bottom_tab_type", String(feedBottomTabType)),
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

    /// The feed as the signed-in account sees it: the same two requests under `bottom_tab_type=7`,
    /// carrying the account's login cookie and current client version profile.
    public static func accountPage(
        channel: BookMallFeedChannel,
        cursor: AppFeedCursor = .first,
        context: BookMallFeedContext = .initial
    ) async throws -> AppFeedPage {
        if cursor.cellId.isEmpty {
            let values = tabQuery(channel: channel, context: context)
            let payload = try await AccountDataAccess.get(path: "/reading/bookapi/bookmall/tab/v/", values: values)
            return try parseTab(payload, channel: channel)
        }
        let values = cellChangeQuery(channel: channel, cursor: cursor, context: context)
        let payload = try await AccountDataAccess.get(path: "/reading/bookapi/bookmall/cell/change/v", values: values)
        return try parseCellChange(payload, after: cursor, channel: channel)
    }

    /// The anonymous feed under `bottom_tab_type=7`, using the current client version profile for
    /// both page 1 and `cell/change/v` pagination.
    public static func page(
        channel: BookMallFeedChannel,
        cursor: AppFeedCursor = .first,
        context: BookMallFeedContext = .initial
    ) async throws -> AppFeedPage {
        if cursor.cellId.isEmpty {
            let payload = try await AppBookMallAccess.tab(
                values: tabQuery(channel: channel, context: context),
                host: defaultHost
            )
            return try parseTab(payload, channel: channel)
        }
        let payload = try await AppBookMallAccess.tab(
            values: cellChangeQuery(channel: channel, cursor: cursor, context: context),
            host: defaultHost,
            path: "/reading/bookapi/bookmall/cell/change/v"
        )
        return try parseCellChange(payload, after: cursor, channel: channel)
    }

    /// Parses the initial response from `/reading/bookapi/bookmall/tab/v/`.
    public static func parseTab(_ payload: JSONValue, channel: BookMallFeedChannel) throws -> AppFeedPage {
        try parseTab(payload, tabType: channel.tabType, contentFilter: channel.contentFilter)
    }

    public static func parseTab(
        _ payload: JSONValue,
        tabType: Int,
        contentFilter: AppFeed.ContentFilter = .anyShortDrama
    ) throws -> AppFeedPage {
        guard payload.object != nil else { throw HongguoError(.format, "推荐信息流返回了空响应") }
        guard AppFeed.integer(payload["code"]) == 0 else { throw HongguoError(.upstream, "推荐信息流服务暂不可用") }
        guard let tabs = payload["data"]["tab_item"].array else {
            throw HongguoError(.format, "推荐信息流数据结构异常")
        }
        // Strict tab match: never silently fall back to a different tab_type (which previously
        // caused 真人剧 to display 找剧/推荐 comic and AI dramas when the requested tab was absent).
        guard let tab = tabs.first(where: { AppFeed.integer($0["tab_type"]) == tabType }) else {
            throw HongguoError(.format, "推荐信息流未返回目标频道（tab_type=\(tabType)）")
        }
        guard let cells = tab["cell_data"].array, !cells.isEmpty else {
            return AppFeedPage(entries: [], next: nil)
        }

        let tabSessionId = validSessionId(tab["session_id"]) ?? validSessionId(payload["data"]["session_id"])
        var seen = Set<String>()
        var entries: [AppFeedEntry] = []
        var feedCellId = ""
        var feedNextOffset: Int?
        var cellSessionId: String?

        for cell in cells {
            let nested = cell["cell_data"].array ?? []
            var cellRawVideos = 0
            for item in nested {
                for row in videoRows(in: item) {
                    cellRawVideos += 1
                    if let entry = AppFeed.parseEntry(row, seen: &seen, filter: contentFilter) {
                        entries.append(entry)
                    }
                }
            }
            let cid = cell["cell_id_str"].nonZeroIdString ?? cell["cell_id"].nonZeroIdString ?? ""
            if cellRawVideos > 0, feedCellId.isEmpty, !cid.isEmpty {
                feedCellId = cid
                cellSessionId = validSessionId(cell["session_id"])
                // `show_type=407` cells under `bottom_tab_type=7` omit `cell.next_offset`; paging
                // continues from the number of videos already delivered on page 1.
                let explicitOffset = AppFeed.integer(cell["next_offset"]).flatMap { $0 > 0 ? $0 : nil }
                feedNextOffset = explicitOffset ?? cellRawVideos
            }
        }

        SeriesCredits.shared.save()
        var next: AppFeedCursor?
        let sessionId = tabSessionId ?? cellSessionId
        if !feedCellId.isEmpty, let offset = feedNextOffset, offset > 0, let sessionId {
            next = AppFeedCursor(offset: offset, sessionId: sessionId, cellId: feedCellId)
        }
        return AppFeedPage(entries: entries, next: next)
    }

    /// Parses a load-more response from `/reading/bookapi/bookmall/cell/change/v`.
    public static func parseCellChange(
        _ payload: JSONValue,
        after cursor: AppFeedCursor,
        channel: BookMallFeedChannel? = nil
    ) throws -> AppFeedPage {
        guard payload.object != nil else { throw HongguoError(.format, "推荐信息流翻页返回了空响应") }
        guard AppFeed.integer(payload["code"]) == 0 else { throw HongguoError(.upstream, "推荐信息流翻页暂不可用") }
        let data = payload["data"]
        guard let items = data["cell_view"]["cell_data"].array ?? data["cell_data"].array else {
            throw HongguoError(.format, "推荐信息流翻页数据结构异常")
        }

        let filter = channel?.contentFilter ?? .anyShortDrama
        var seen = Set<String>()
        var entries: [AppFeedEntry] = []
        var rawVideoCount = 0
        for item in items {
            for row in videoRows(in: item) {
                rawVideoCount += 1
                if let entry = AppFeed.parseEntry(row, seen: &seen, filter: filter) {
                    entries.append(entry)
                }
            }
        }

        SeriesCredits.shared.save()
        var next: AppFeedCursor?
        let session = validSessionId(data["session_id"]) ?? validSessionId(data["cell_view"]["session_id"]) ?? (cursor.sessionId.isEmpty ? nil : cursor.sessionId)
        let explicitOffset = AppFeed.integer(data["next_offset"]).flatMap { $0 > 0 ? $0 : nil }
            ?? AppFeed.integer(data["cell_view"]["next_offset"]).flatMap { $0 > 0 ? $0 : nil }
        let resolvedOffset = explicitOffset ?? (rawVideoCount > 0 ? cursor.offset + rawVideoCount : 0)
        if data["has_more"].bool == true,
           resolvedOffset > cursor.offset,
           let session,
           !cursor.cellId.isEmpty {
            next = AppFeedCursor(offset: resolvedOffset, sessionId: session, cellId: cursor.cellId)
        }
        return AppFeedPage(entries: entries, next: next)
    }

    /// Extracts playable rows from one `cell_data` item: either `video_data` (array of rows) or a
    /// direct `video_detail` object/array (used by `show_type=407` items under `bottom_tab_type=7`).
    private static func videoRows(in item: JSONValue) -> [JSONValue] {
        if let rows = item["video_data"].array, !rows.isEmpty {
            return rows
        }
        if item["video_detail"].object != nil {
            return [item]
        }
        if let details = item["video_detail"].array, !details.isEmpty {
            return details
        }
        return []
    }

    private static func validSessionId(_ value: JSONValue) -> String? {
        guard let session = value.string ?? value.idString, !session.isEmpty, session.count <= 4096 else {
            return nil
        }
        return session
    }
}

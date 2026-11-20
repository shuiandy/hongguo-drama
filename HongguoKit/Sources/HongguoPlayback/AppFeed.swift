import Foundation
import HongguoCore

/// A feed built from the App's category list (`/reading/distribution/category/landpage/v/`),
/// asked without a sort order. Each row already names episode 1 (`vid`), so a clip can start
/// without first fetching the series' episode list. Paging uses the service's own cursor.
///
/// What this is not: the personalised 推荐 stream of the official app's home tab. That comes
/// from another endpoint the core's signer does not allow. Two fresh requests here return the
/// same series in a slightly different order.
public enum AppFeedChannel: String, Sendable, CaseIterable {
    /// Every genre mixed.
    case all
    /// 真人剧
    case liveAction
    /// 漫剧
    case comic

    var scene: String { self == .comic ? "comic_series" : "default" }
    var genre: [String] {
        switch self {
        case .all: return []
        case .liveAction: return ["short_play"]
        case .comic: return ["comic_series"]
        }
    }
}

public struct AppFeedCursor: Equatable, Sendable {
    public var offset: Int
    public var sessionId: String
    public var cellId: String

    public init(offset: Int = 0, sessionId: String = "", cellId: String = "") {
        self.offset = offset
        self.sessionId = sessionId
        self.cellId = cellId
    }

    public static let first = AppFeedCursor()
}

public struct AppFeedEntry: Equatable, Sendable {
    public var series: SeriesSummary
    /// Video id of episode 1.
    public var firstVid: String
    public var commentCount: Int
    public var playCount: Int
    /// The source says the video is portrait.
    public var isVertical: Bool
}

public struct AppFeedPage: Equatable, Sendable {
    public var entries: [AppFeedEntry]
    /// nil when the list ended or the service sent no usable cursor.
    public var next: AppFeedCursor?
}

public enum AppFeed {
    public static let pageSize = 15

    public static func requestBody(channel: AppFeedChannel, cursor: AppFeedCursor) -> Data {
        let body: [String: Any] = [
            "filter_ids": "", "req_scene": channel.scene, "offset": cursor.offset, "need_selector_panel": false, "limit": pageSize,
            "select_items": ["genre": channel.genre, "sort": [String](), "category_dim_theme": [String](),
                             "category_dim_role": [String](), "category_dim_epoch": [String](), "gender": [String](),
                             "online_time": [String](), "creation_status": [String]()],
            "session_id": cursor.sessionId, "req_type": cursor.offset > 0 ? "only_content" : "default", "client_req_type": 3,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    public static func page(channel: AppFeedChannel, cursor: AppFeedCursor = .first) async throws -> AppFeedPage {
        let payload = try await AppCatalogueAccess.landpage(body: requestBody(channel: channel, cursor: cursor))
        return try parse(payload, after: cursor)
    }

    /// Short dramas only (content types 1 and 1004), playable, with a series id, a title and an
    /// episode 1 id; duplicates inside the page are dropped.
    public static func parse(_ payload: JSONValue, after cursor: AppFeedCursor = .first) throws -> AppFeedPage {
        guard payload.object != nil else { throw HongguoError(.format, "App 列表返回了空响应") }
        guard integer(payload["code"]) == 0 else { throw HongguoError(.upstream, "App 列表服务暂不可用") }
        let data = payload["data"]
        guard let rows = data["video_data"].array else { throw HongguoError(.format, "App 列表数据结构异常") }
        var seen = Set<String>()
        var entries: [AppFeedEntry] = []
        for row in rows {
            guard let entry = parseEntry(row, seen: &seen) else { continue }
            entries.append(entry)
        }
        var next: AppFeedCursor?
        if data["has_more"].bool == true, let offset = integer(data["next_offset"]), offset > cursor.offset,
           let session = data["session_id"].string ?? data["session_id"].idString, !session.isEmpty, session.count <= 4096 {
            next = AppFeedCursor(offset: offset, sessionId: session)
        }
        SeriesCredits.shared.save()
        return AppFeedPage(entries: entries, next: next)
    }

    /// Parses one `video_data` row shared by `landpage/v/` and `bookmall/tab/v/`.
    static func parseEntry(_ row: JSONValue, seen: inout Set<String>) -> AppFeedEntry? {
        guard let id = row["series_id"].idString, isDigits(id),
              let vid = row["vid"].idString, isDigits(vid),
              [1, 1004].contains(integer(row["content_type"]) ?? -1),
              row["disable_play"].bool != true else { return nil }
        let title = SearchText.clean(row["title"].string ?? row["series_title"].string ?? row["series_name"].string)
        guard !title.isEmpty, seen.insert(id).inserted else { return nil }
        var tags: [String] = [], heat = ""
        for item in row["sub_title_list"].array ?? [] {
            let text = SearchText.clean(item["content"].string)
            guard !text.isEmpty else { continue }
            // data_type 27 is the play count ("7031万"), shown as heat rather than as a tag.
            if integer(item["data_type"]) == 27 { heat = text } else if !tags.contains(text) { tags.append(text) }
        }
        if heat.isEmpty {
            heat = SearchText.clean(row["rec_text"].string)
        }
        if tags.isEmpty {
            for item in row["rec_tags"].array ?? [] {
                let text = SearchText.clean(item["content"].string)
                if !text.isEmpty, !tags.contains(text) { tags.append(text) }
            }
        }
        let count = integer(row["episode_cnt"]) ?? 0
        // The rights holder, for the series page (see `SeriesCredits`).
        SeriesCredits.shared.note(seriesId: id, copyright: SearchText.clean(row["copyright"].string))
        let summary = SeriesSummary(seriesId: id, title: title, cover: SearchText.catalogCover(row["cover"].string),
                                    episodeCount: count, tags: Array(tags.prefix(4)),
                                    description: SearchText.clean(row["video_desc"].string ?? row["series_intro"].string),
                                    heat: heat, episodeLabel: count > 0 ? "全\(count)集" : "")
        return AppFeedEntry(series: summary, firstVid: vid, commentCount: integer(row["comment_count"]) ?? 0,
                            playCount: integer(row["play_cnt"]) ?? 0, isVertical: row["vertical"].bool ?? true)
    }

    private static func isDigits(_ text: String) -> Bool {
        (1...30).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The service sends counts as numbers or as digit strings.
    static func integer(_ value: JSONValue) -> Int? {
        if let number = value.number, number >= 0, number.rounded() == number, number < 9e15 { return Int(number) }
        if let text = value.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return Int(text)
        }
        return nil
    }
}

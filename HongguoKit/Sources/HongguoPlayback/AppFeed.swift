import Foundation
import HongguoCore

/// Row parsing shared by the home feed (`BookMallFeed`, the official 首页视频流) and the App
/// category list (`landpage/v/` rows): each row already names episode 1 (`vid` or
/// `video_detail.first_vid`), so a clip can start without first fetching the series' episode list.
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
    /// `content_type` (1 = 真人剧, 1004 = 漫剧/AI剧).
    public var contentType: Int
    /// `ai_usage_type` (> 0 marks AI-generated dramas).
    public var aiUsageType: Int

    public init(
        series: SeriesSummary,
        firstVid: String,
        commentCount: Int,
        playCount: Int,
        isVertical: Bool,
        contentType: Int = 1,
        aiUsageType: Int = 0
    ) {
        self.series = series
        self.firstVid = firstVid
        self.commentCount = commentCount
        self.playCount = playCount
        self.isVertical = isVertical
        self.contentType = contentType
        self.aiUsageType = aiUsageType
    }
}

public struct AppFeedPage: Equatable, Sendable {
    public var entries: [AppFeedEntry]
    /// nil when the list ended or the service sent no usable cursor.
    public var next: AppFeedCursor?
}

public enum AppFeed {
    /// Content-type guard applied per feed channel so a live-action stream never surfaces comic or
    /// AI dramas and a comic stream never surfaces live-action dramas.
    public enum ContentFilter: Sendable {
        case anyShortDrama
        case liveActionOnly
        case comicOnly

        func accepts(contentType: Int, aiUsageType: Int) -> Bool {
            switch self {
            case .anyShortDrama:
                return [1, 1004].contains(contentType)
            case .liveActionOnly:
                return contentType == 1 && aiUsageType == 0
            case .comicOnly:
                return contentType == 1004
            }
        }
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

    /// Parses one `video_data` row shared by `landpage/v/`, `bookmall/tab/v/` (both flat
    /// `show_type=507` rows and nested `show_type=407` rows carrying `video_detail`), and
    /// `bookmall/cell/change/v`.
    static func parseEntry(
        _ row: JSONValue,
        seen: inout Set<String>,
        filter: ContentFilter = .anyShortDrama
    ) -> AppFeedEntry? {
        let detail = row["video_detail"]
        guard let id = firstDigits(row["series_id"], row["series_id_str"], detail["series_id_str"], detail["series_id"]),
              let vid = firstDigits(row["vid"], row["first_vid"], detail["first_vid"],
                                    row["video_list"].array?.first?["vid"],
                                    detail["video_list"].array?.first?["vid"]),
              let contentType = integer(row["content_type"]) ?? integer(detail["content_type"]) else { return nil }
        let aiUsageType = integer(row["ai_usage_type"]) ?? integer(detail["ai_usage_type"]) ?? 0
        guard filter.accepts(contentType: contentType, aiUsageType: aiUsageType),
              row["disable_play"].bool != true,
              detail["disable_play"].bool != true else { return nil }
        let title = SearchText.clean(
            firstNonEmpty(row["title"].string, row["series_title"].string, row["series_name"].string, detail["series_title"].string)
        )
        guard !title.isEmpty, seen.insert(id).inserted else { return nil }
        var tags: [String] = [], heat = ""
        for item in row["sub_title_list"].array ?? [] {
            let text = SearchText.clean(item["content"].string)
            guard !text.isEmpty else { continue }
            // data_type 27 is the play count / heat ("7031万"), shown as heat rather than as a tag.
            if integer(item["data_type"]) == 27 { heat = text } else if !tags.contains(text) { tags.append(text) }
        }
        for item in (row["secondary_infos"].array ?? []) + (detail["secondary_infos"].array ?? []) {
            let text = SearchText.clean(item["content"].string)
            guard !text.isEmpty else { continue }
            let dataType = integer(item["data_type"])
            if dataType == 27 || (heat.isEmpty && text.contains("热度")) {
                if heat.isEmpty { heat = text }
            } else if dataType != 33, !tags.contains(text) {
                // Skip data_type 33 ("演员·...") so hashtag pills stay genre/theme labels.
                tags.append(text)
            }
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
        if tags.isEmpty {
            for name in categorySchemaNames(detail["category_schema"]) + categorySchemaNames(row["category_schema"]) {
                if !tags.contains(name) { tags.append(name) }
            }
        }
        let count = integer(row["episode_cnt"]) ?? integer(detail["episode_cnt"]) ?? 0
        // The rights holder, for the series page (see `SeriesCredits`).
        SeriesCredits.shared.note(seriesId: id, copyright: SearchText.clean(firstNonEmpty(row["copyright"].string, detail["copyright"].string)))
        let rawCover = firstNonEmpty(row["cover"].string, row["series_cover"].string, detail["series_cover"].string)
        let summary = SeriesSummary(
            seriesId: id,
            title: title,
            cover: SearchText.catalogCover(rawCover),
            episodeCount: count,
            tags: Array(tags.prefix(4)),
            description: SearchText.clean(firstNonEmpty(row["video_desc"].string, row["series_intro"].string, detail["series_intro"].string)),
            heat: heat,
            episodeLabel: count > 0 ? "全\(count)集" : ""
        )
        return AppFeedEntry(
            series: summary,
            firstVid: vid,
            commentCount: integer(row["comment_count"]) ?? integer(detail["comment_count"]) ?? 0,
            playCount: integer(row["play_cnt"]) ?? integer(row["series_play_cnt"]) ?? integer(detail["series_play_cnt"]) ?? 0,
            isVertical: row["vertical"].bool ?? detail["vertical"].bool ?? true,
            contentType: contentType,
            aiUsageType: aiUsageType
        )
    }

    private static func firstDigits(_ values: JSONValue?...) -> String? {
        for value in values {
            if let text = value?.idString?.trimmingCharacters(in: .whitespaces), isDigits(text) {
                return text
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func categorySchemaNames(_ value: JSONValue) -> [String] {
        var list = value
        if let text = value.string, let parsed = try? JSONValue.parse(Data(text.utf8)) {
            list = parsed
        }
        var out: [String] = []
        for item in list.array ?? [] {
            let name = SearchText.clean(item.string ?? item["name"].string ?? item["category_name"].string)
            if !name.isEmpty, name.count <= 20, !out.contains(name) { out.append(name) }
        }
        return out
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

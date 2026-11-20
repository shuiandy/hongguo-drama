import Foundation
import HongguoCore

/// Row parsing shared by the home feed (`BookMallFeed`, the official 推荐 stream) and the App
/// category list (`landpage/v/` rows): each row already names episode 1 (`vid`), so a clip can
/// start without first fetching the series' episode list. The category list is no longer asked
/// for a feed of its own; the book mall feed is the only one.
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

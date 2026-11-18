// SPDX-License-Identifier: GPL-3.0-only
// Request bodies for writing watch progress back to the signed-in Hongguo account.
// The official client keeps two stores and both must be written:
//   • /reading/bookapi/read_history/update/v1/  → the watch history list (what `AccountService.history` reads)
//   • /reading/bookapi/read_progress/upload/v1/ → the resume point ("continue watching")
// Field names follow two independent public clients: N3urda/hongguoTV `CloudAccountClient.upload`
// and dddmiku/hongguo-tv `ProgressContract` (history + resume bodies). Times are milliseconds.
import Foundation

/// One episode position to report for a Hongguo series.
public struct AccountProgressReport: Equatable, Sendable {
    public var seriesId: String
    public var episodeId: String
    /// 1-based.
    public var episodeIndex: Int
    /// Seconds.
    public var position: Double
    /// Seconds; 0 when unknown.
    public var duration: Double
    /// Episodes in the series; 0 when unknown.
    public var episodeCount: Int
    public var title: String
    public var cover: String
    public var watchedAt: Date

    public init(seriesId: String, episodeId: String, episodeIndex: Int, position: Double, duration: Double,
                episodeCount: Int, title: String = "", cover: String = "", watchedAt: Date) {
        self.seriesId = seriesId
        self.episodeId = episodeId
        self.episodeIndex = episodeIndex
        self.position = position
        self.duration = duration
        self.episodeCount = episodeCount
        self.title = title
        self.cover = cover
        self.watchedAt = watchedAt
    }

    /// Hongguo ids are 16 to 19 digit integers that must fit a signed 64-bit JSON number.
    static func validId(_ value: String) -> Bool {
        value.matchesDigits(min: 8, max: 19) && value.first != "0" && Int64(value) != nil
    }

    /// Throws when the report cannot be sent as is.
    func validated() throws -> AccountProgressReport {
        guard Self.validId(seriesId), Self.validId(episodeId) else { throw HongguoError(.input, "剧集或分集编号无效，无法同步进度") }
        guard episodeIndex >= 1, episodeIndex <= 10_000 else { throw HongguoError(.input, "集数无效，无法同步进度") }
        guard position.isFinite, duration.isFinite, position >= 0, duration >= 0 else { throw HongguoError(.input, "播放位置无效，无法同步进度") }
        guard watchedAt.timeIntervalSince1970 > 1_500_000_000 else { throw HongguoError(.input, "观看时间无效，无法同步进度") }
        return self
    }

    var positionMillis: Int64 { Int64((position * 1000).rounded(.down)) }
    var durationMillis: Int64 { Int64((duration * 1000).rounded(.down)) }
    var watchedMillis: Int64 { Int64((watchedAt.timeIntervalSince1970 * 1000).rounded(.down)) }

    /// Body of `read_history/update/v1`.
    public func historyBody() throws -> [UInt8] {
        let r = try validated()
        var row: [(String, OrderedJSON)] = [
            ("book_id", .raw(r.seriesId)), ("book_id_str", .string(r.seriesId)), ("book_type", .int(2)),
            ("vid", .raw(r.episodeId)), ("vid_index", .int(Int64(r.episodeIndex))), ("chapter_index", .int(Int64(r.episodeIndex))),
            ("read_timestamp_ms", .int(r.watchedMillis)), ("update_timestamp_ms", .int(0)),
            ("current_play_position", .int(r.positionMillis)), ("player_accumulate_total_time", .int(r.positionMillis)),
            ("duration", .int(r.durationMillis)), ("episode_cnt", .int(Int64(max(0, r.episodeCount)))),
            ("is_delete", .bool(false)), ("use_soft_delete", .bool(false)), ("genre_type", .int(2150)),
        ]
        let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { row.append(("book_name", .string(String(title.prefix(200))))) }
        if r.cover.hasPrefix("https://") { row.append(("thumb_url", .string(r.cover))) }
        return OrderedJSON.object([("update_datas", .array([.object(row)]))]).bytes
    }

    /// Body of `read_progress/upload/v1`.
    public func progressBody() throws -> [UInt8] {
        let r = try validated()
        var row: [(String, OrderedJSON)] = [
            ("book_id", .string(r.seriesId)), ("item_id", .string(r.episodeId)),
            ("vid_index", .int(Int64(r.episodeIndex))),
            ("current_play_time", .int(r.positionMillis)), ("current_total_time", .int(r.durationMillis)),
        ]
        if r.episodeCount > 0 { row.append(("episode_count", .int(Int64(r.episodeCount)))) }
        let rate = r.duration > 0 ? min(1, max(0, r.position / r.duration)) : 0
        row += [
            ("read_timestamp_ms", .int(r.watchedMillis)), ("book_type", .int(2)),
            ("progress_rate", .string(rate == 0 ? "0" : String(format: "%.4f", rate))),
            ("player_cumulative_total_duration", .int(r.positionMillis)),
        ]
        return OrderedJSON.object([("books", .array([.object(row)])), ("write_mode", .int(1))]).bytes
    }

    /// Whether a write reply confirms the change: top-level `code` 0 and no non-zero nested error code.
    static func acknowledged(_ payload: JSONValue) -> Bool {
        func zero(_ value: JSONValue) -> Bool {
            switch value {
            case .int(let i): return i == 0
            case .double(let d): return d == 0
            case .string(let s): return s.trimmingCharacters(in: .whitespaces) == "0"
            default: return false
            }
        }
        guard payload.object != nil, zero(payload["code"]) else { return false }
        for key in ["error_code", "err_no", "status_code"] {
            let nested = payload["data"][key]
            if !nested.isNull, !zero(nested) { return false }
        }
        return true
    }
}

/// Minimal JSON writer that keeps key order and writes 19-digit ids as exact numbers.
enum OrderedJSON {
    case string(String), int(Int64), bool(Bool)
    /// Digits written verbatim as a JSON number (pre-validated ids only).
    case raw(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    var text: String {
        switch self {
        case .string(let s): return Self.quote(s)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .raw(let digits): return digits.isDigitsOnly && !digits.isEmpty ? digits : "0"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { Self.quote($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    var bytes: [UInt8] { Array(text.utf8) }

    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "/": out += "\\/"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

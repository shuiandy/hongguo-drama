// SPDX-License-Identifier: GPL-3.0-only
// Official timed danmaku (comments with a video offset). Port of src/native/danmaku.js, adapted
// from dawei233/hongguo-drama (GPL-3.0, commit c884fab6c6e36ad38173e251738b9b35f958383f).
//
// The endpoint is private and needs forged client signatures (see `DanmakuSigner`). It can break
// at any time, so `fetch` never throws: every outcome is a `DanmakuResult` whose `notice` says in
// plain Chinese what happened. A failure is never reported as "this episode has no danmaku".
import Foundation

public enum DanmakuMode: String, Codable, Sendable, CaseIterable { case scroll, top, bottom }

public struct DanmakuItem: Hashable, Codable, Sendable {
    /// Seconds from the start of the episode.
    public var time: Double
    public var text: String
    /// `#RRGGBB`.
    public var color: String
    public var mode: DanmakuMode
    public init(time: Double, text: String, color: String = "#FFFFFF", mode: DanmakuMode = .scroll) {
        self.time = time; self.text = text; self.color = color; self.mode = mode
    }
}

public struct DanmakuResult: Sendable, Equatable {
    public var success: Bool
    public var seriesId: String
    public var vid: String
    /// Sorted by time.
    public var items: [DanmakuItem]
    public var truncated: Bool
    /// Failed midway but kept what was already fetched.
    public var partial: Bool
    public var error: String
    /// The one status line to show. Equals `error` whenever there is one.
    public var notice: String
    public var total: Int { items.count }

    static func finalize(seriesId: String, vid: String, items: [DanmakuItem], truncated: Bool, error: String) -> DanmakuResult {
        let notice: String
        if !error.isEmpty { notice = error }
        else if truncated { notice = "弹幕较多，本次仅载入前 \(items.count) 条" }
        else if items.isEmpty { notice = "本集暂无弹幕" }
        else { notice = "" }
        return DanmakuResult(success: error.isEmpty, seriesId: seriesId, vid: vid, items: items, truncated: truncated,
                             partial: !error.isEmpty && !items.isEmpty, error: error, notice: notice)
    }

    /// Trims to `limit` without rewriting an error into a normal notice.
    func limited(to limit: Int) -> DanmakuResult {
        guard items.count > limit else { return self }
        var copy = self
        copy.items = Array(items.prefix(limit))
        copy.truncated = true
        if error.isEmpty { copy.notice = "弹幕较多，本次仅载入前 \(limit) 条" }
        return copy
    }
}

/// Sends one signed POST and returns the body. Injected in tests.
public protocol DanmakuTransport: Sendable {
    func post(url: URL, body: Data, headers: [(String, String)], timeout: TimeInterval) async throws -> Data
}

public struct HTTPDanmakuTransport: DanmakuTransport {
    let http: HTTPClient
    public init(http: HTTPClient = .shared) { self.http = http }
    public func post(url: URL, body: Data, headers: [(String, String)], timeout: TimeInterval) async throws -> Data {
        var options = HTTPClient.Options()
        options.timeout = timeout
        options.maxBytes = DanmakuService.maxResponseBytes
        options.maxRedirects = 0
        options.acceptStatus = 200...299
        for (key, value) in headers { options.headers[key] = value }
        return try await http.post(url, json: body, options: options).data
    }
}

/// The anonymous client identity. Upstream assigns danmaku subsets per identity, so it must
/// survive restarts. Stored next to the library with 0600 permissions.
public struct DanmakuIdentity: Codable, Equatable, Sendable {
    public var deviceId: String
    public var installId: String

    var isValid: Bool {
        [deviceId, installId].allSatisfy { $0.count == 19 && $0.allSatisfy(\.isASCIIDigitChar) }
    }

    public static func loadOrCreate(at file: URL) throws -> DanmakuIdentity {
        if let data = try? Data(contentsOf: file) {
            guard let saved = try? JSONDecoder().decode(DanmakuIdentity.self, from: data), saved.isValid else {
                throw HongguoError(.input, "弹幕本机配置读取或保存失败，请检查资料目录权限后重试")
            }
            return saved
        }
        let created = DanmakuIdentity(deviceId: DanmakuSigner.newDeviceId(), installId: DanmakuSigner.newDeviceId())
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(created).write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw HongguoError(.input, "弹幕本机配置读取或保存失败，请检查资料目录权限后重试")
        }
        return created
    }
}

private extension Character {
    var isASCIIDigitChar: Bool { isASCII && isNumber }
}

public actor DanmakuService {
    public static let shared = DanmakuService()

    static let baseURL = "https://api5-normal-sinfonlineb.fqnovel.com"
    static let userAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; "
        + "Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
    public static let maxTextLength = 200
    public static let maxTimeSeconds: Double = 604_800
    public static let pageCount = 90
    public static let maxPages = 40
    public static let maxItems = 3000
    static let requestTimeout: TimeInterval = 20
    static let effectiveDurationMs: Int64 = 3_600_000
    static let maxDurationMs: Int64 = 24 * 60 * 60 * 1000
    static let maxEmptyPages = 2
    static let maxResponseBytes = 8 * 1024 * 1024
    static let cacheTTLOK: TimeInterval = 5 * 60
    static let cacheTTLFail: TimeInterval = 15
    static let cacheLimit = 64

    private let transport: DanmakuTransport
    private let identityFile: URL?
    private var identity: DanmakuIdentity?
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () -> [UInt8]
    private let pageGap: Duration
    private var cache: [String: (result: DanmakuResult, expires: Date)] = [:]
    private var cacheOrder: [String] = []
    private var pending: [String: Task<DanmakuResult, Never>] = [:]

    public init(transport: DanmakuTransport = HTTPDanmakuTransport(),
                identityFile: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("HongguoDrama/danmaku-client.json"),
                identity: DanmakuIdentity? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                nonce: (@Sendable () -> [UInt8])? = nil,
                pageGap: Duration = .milliseconds(120)) {
        self.transport = transport
        self.identityFile = identityFile
        self.identity = identity
        self.now = now
        self.nonce = nonce ?? { AppCrypto.randomBytes(DanmakuSigner.nonceBytes) }
        self.pageGap = pageGap
    }

    public func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Fetches the official danmaku for one episode. `seriesId` is the book id and `vid` the
    /// episode video id; mixing them up gets rejected upstream. `fresh` skips the cache (for a
    /// retry button). Never throws.
    public func fetch(seriesId rawSeries: String, vid rawVid: String, limit: Int = DanmakuService.maxItems,
                      fresh: Bool = false) async -> DanmakuResult {
        let seriesId = rawSeries.trimmingCharacters(in: .whitespaces)
        let vid = rawVid.trimmingCharacters(in: .whitespaces)
        guard (1...Self.maxItems).contains(limit) else {
            return .finalize(seriesId: seriesId, vid: vid, items: [], truncated: false, error: "弹幕请求参数无效")
        }
        guard seriesId.matchesDigits(min: 6, max: 30), vid.matchesDigits(min: 6, max: 30) else {
            return .finalize(seriesId: seriesId, vid: vid, items: [], truncated: false, error: "仅红果来源的剧集支持弹幕")
        }
        let key = "\(seriesId):\(vid)"
        if !fresh, let hit = cache[key], hit.expires > Date() { return hit.result.limited(to: limit) }
        if let shared = pending[key] { return await shared.value.limited(to: limit) }
        let task = Task { await self.collect(seriesId: seriesId, vid: vid) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if Task.isCancelled || result.error == "弹幕请求已取消" { return result }
        store(key, result)
        return result.limited(to: limit)
    }

    private func store(_ key: String, _ result: DanmakuResult) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = (result, Date().addingTimeInterval(result.success ? Self.cacheTTLOK : Self.cacheTTLFail))
        while cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    private func collect(seriesId: String, vid: String) async -> DanmakuResult {
        var collected: [DanmakuItem] = []
        var seen = Set<String>()
        var start: Int64 = 0
        var duration = Self.effectiveDurationMs
        var emptyPages = 0
        var truncated = false
        var failure = ""
        let cancelled = DanmakuResult.finalize(seriesId: seriesId, vid: vid, items: [], truncated: false, error: "弹幕请求已取消")

        for page in 0..<Self.maxPages {
            if Task.isCancelled { return cancelled }
            if page > 0 {
                do { try await Task.sleep(for: pageGap) } catch { return cancelled }
            }
            let payload: JSONValue
            do {
                payload = try await requestWindow(vid: vid, bookId: seriesId, start: start, duration: duration)
            } catch {
                if Task.isCancelled { return cancelled }
                failure = Self.describeFailure(error, hasItems: !collected.isEmpty)
                break
            }
            let parsed = Self.parsePage(payload, vid: vid)
            emptyPages = parsed.items.isEmpty ? emptyPages + 1 : 0
            for raw in parsed.items {
                guard let seconds = Self.toSeconds(raw.timeRaw) else { continue }
                let text = Self.cleanControl(raw.text)
                guard !text.isEmpty, text.count <= Self.maxTextLength else { continue }
                let dedupe = String(format: "%.3f|", seconds) + text
                guard seen.insert(dedupe).inserted else { continue }
                collected.append(DanmakuItem(time: seconds, text: text, color: raw.color, mode: raw.mode))
                if collected.count >= Self.maxItems { break }
            }
            if collected.count >= Self.maxItems { truncated = true; break }
            guard let next = parsed.nextMs else {
                if parsed.hasMore == true {
                    truncated = true
                    if collected.isEmpty { failure = "弹幕接口未返回有效分页，请稍后重试" }
                }
                break
            }
            if next <= start || Double(next) > Self.maxTimeSeconds * 1000 || emptyPages >= Self.maxEmptyPages || page == Self.maxPages - 1 {
                truncated = true
                if collected.isEmpty { failure = "弹幕接口未返回有效分页，请稍后重试" }
                break
            }
            start = next
            // Upstream rejects windows longer than 24 hours.
            duration = min(max(duration, start + Self.effectiveDurationMs), Self.maxDurationMs)
        }
        collected.sort { $0.time < $1.time }
        return .finalize(seriesId: seriesId, vid: vid, items: collected, truncated: truncated, error: failure)
    }

    static func describeFailure(_ error: Error, hasItems: Bool) -> String {
        if let error = error as? HongguoError, error.message.hasPrefix("弹幕本机配置") { return error.message }
        if hasItems { return "后续弹幕加载中断，已保留已获取的部分" }
        if let error = error as? HongguoError, error.kind == .timeout || error.kind == .cancelled {
            return "弹幕接口响应超时（已用官方签名请求），可稍后再试"
        }
        if let status = error as? HTTPStatusError {
            return "弹幕接口不可用（HTTP \(status.status)），已尝试官方签名请求；可改用「本集评论」"
        }
        // Never surface raw error text: it may include the signed URL or the device identity.
        return "弹幕接口暂不可用（已尝试官方签名请求），请稍后重试"
    }

    private func currentIdentity() throws -> DanmakuIdentity {
        if let identity { return identity }
        let loaded = try identityFile.map(DanmakuIdentity.loadOrCreate(at:))
            ?? DanmakuIdentity(deviceId: DanmakuSigner.newDeviceId(), installId: DanmakuSigner.newDeviceId())
        identity = loaded
        return loaded
    }

    /// The stamp (seconds), `_rticket` (milliseconds) and nonce come from one clock read; a
    /// mismatch between them is an invalid signature.
    func requestWindow(vid: String, bookId: String, start: Int64, duration: Int64) async throws -> JSONValue {
        let stampMs = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        let stamp = stampMs / 1000
        let who = try currentIdentity()
        let rawQuery = DanmakuSigner.buildQuery(stampMs: stampMs, deviceId: who.deviceId, installId: who.installId)
        guard let url = URL(string: "\(Self.baseURL)/novel/commentapi/comment/list/\(vid)/v1/?\(rawQuery)") else {
            throw HongguoError(.input, "弹幕请求地址无效")
        }
        var headers: [(String, String)] = [
            ("User-Agent", Self.userAgent), ("Accept", "application/json"), ("X-XS-From-Web", "0"), ("Sdk-Version", "2"),
            ("Content-Type", "application/json; charset=utf-8"), ("Comment-Source", "601"), ("Server-Channel", "1000"),
        ]
        headers += try DanmakuSigner.headers(rawQuery: rawQuery, stamp: stamp, nonce: nonce())
        let body = try JSONSerialization.data(withJSONObject: Self.body(vid: vid, bookId: bookId, start: start, duration: duration),
                                              options: [.sortedKeys])
        let data = try await transport.post(url: url, body: body, headers: headers, timeout: Self.requestTimeout)
        guard data.count <= Self.maxResponseBytes else { throw HongguoError(.upstream, "弹幕响应过大") }
        guard let payload = try? JSONValue.parse(data) else { throw HongguoError(.format, "弹幕接口返回了非 JSON 内容") }
        let code = payload["code"]
        let ok = code == .int(0) || code == .string("0") || code == .double(0)
        guard ok, payload["data"]["data_list"].array != nil else { throw HongguoError(.upstream, "弹幕接口响应无效") }
        return payload
    }

    static func body(vid: String, bookId: String, start: Int64, duration: Int64) -> [String: Any] {
        [
            "comment_source": 601, "server_channel": 1000, "group_id": vid, "group_type": 30, "comment_type": 20,
            "sort": 1, "count": pageCount, "cursor": "", "aid": 8662, "compliance_status": 0,
            "business_param": [
                "book_id": bookId, "start_offset_time": start, "playlet_item_duration": duration,
                "need_danmaku_guide_type": [1, 3, 4, 2],
            ] as [String: Any],
        ]
    }

    // MARK: Parsing (mirrors the reference's cleaning rules)

    struct RawItem: Equatable { var text: String; var timeRaw: JSONValue; var color: String; var mode: DanmakuMode }
    struct Page { var items: [RawItem]; var nextMs: Int64?; var hasMore: Bool? }

    /// JS `String(value)` for scalars; booleans become "1"/"0"; null and containers become "".
    static func asText(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return String(i)
        case .double(let d):
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    /// JS `Number.parseInt(text, 10)`: leading integer prefix after optional whitespace and sign.
    static func parseIntPrefix(_ text: String) -> Int64? {
        var chars = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var sign: Int64 = 1
        if chars.first == "-" { sign = -1; chars = chars.dropFirst() } else if chars.first == "+" { chars = chars.dropFirst() }
        let digits = chars.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let value = Int64(digits.prefix(18)) else { return nil }
        return sign * value
    }

    static func intPrefix(_ value: JSONValue) -> Int64? {
        switch value {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int64(d.rounded(.towardZero)) : nil
        case .string(let s): return parseIntPrefix(s)
        default: return nil
        }
    }

    /// Normalises to `#RRGGBB`; anything unusable becomes white.
    static func normalizeColor(_ value: JSONValue?) -> String {
        func hex(_ n: Int64) -> String { String(format: "#%06X", Int(n & 0xFFFFFF)) }
        switch value {
        case .int(let i): return i < 0 ? "#FFFFFF" : hex(i)
        case .double(let d): return d.isFinite && d >= 0 ? hex(Int64(d.rounded(.towardZero)) ) : "#FFFFFF"
        case .string(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
            func allHex(_ s: Substring) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy(hexDigits.contains) }
            if text.isEmpty { return "#FFFFFF" }
            if lower.hasPrefix("#") {
                let body = lower.dropFirst()
                if body.count == 6, allHex(body) { return text.uppercased() }
                if body.count == 3, allHex(body) { return "#" + body.map { "\($0)\($0)" }.joined().uppercased() }
                return "#FFFFFF"
            }
            if lower.hasPrefix("0x"), allHex(lower.dropFirst(2)) {
                guard let n = UInt64(lower.dropFirst(2).suffix(16), radix: 16) else { return "#FFFFFF" }
                return String(format: "#%06X", Int(n & 0xFFFFFF))
            }
            if lower.allSatisfy({ $0.isASCII && $0.isNumber }) {
                if let n = UInt64(lower) { return String(format: "#%06X", Int(n & 0xFFFFFF)) }
                // Beyond 64 bits JS loses precision anyway; low bits are not meaningful.
                return "#FFFFFF"
            }
            return "#FFFFFF"
        default: return "#FFFFFF"
        }
    }

    /// scroll / top / bottom. Upstream currently never sends a position field, so this is always
    /// scroll in practice; the fallbacks stay for when it does.
    static func normalizeMode(_ holders: [JSONValue]) -> DanmakuMode {
        for holder in holders {
            guard let object = holder.object else { continue }
            for key in ["mode", "danmaku_type", "position", "fix_type", "danmaku_position"] {
                guard let value = object[key], !value.isNull else { continue }
                let token = asText(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["top", "2", "fix_top", "顶部"].contains(token) { return .top }
                if ["bottom", "3", "fix_bottom", "底部"].contains(token) { return .bottom }
            }
        }
        return .scroll
    }

    /// Control characters and line/paragraph separators become spaces, then the ends are trimmed.
    static func cleanControl(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            out.append(v < 0x20 || v == 0x7F || v == 0x2028 || v == 0x2029 ? " " : scalar)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Milliseconds to seconds, rejecting anything outside 0...7 days.
    static func toSeconds(_ value: JSONValue) -> Double? {
        let number: Double
        switch value {
        case .int(let i): number = Double(i)
        case .double(let d): number = d
        case .string(let s):
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                  let parsed = Double(s) else { return nil }
            number = parsed
        default: return nil
        }
        guard number.isFinite else { return nil }
        let seconds = number / 1000
        guard seconds >= 0, seconds <= maxTimeSeconds else { return nil }
        return seconds
    }

    /// Paging has two signals and both occur in practice: `data.extra.next_query_danmaku_list_time`
    /// and `data.common_list_info` (`has_more` + `cursor.end_offset_time`). `extra` is often empty,
    /// so reading only the first stops after one page. An explicit `has_more: false` wins.
    static func parsePage(_ payload: JSONValue, vid: String) -> Page {
        let data = payload["data"]
        guard data.object != nil else { return Page(items: [], nextMs: nil, hasMore: nil) }
        var nextMs: Int64?
        var hasMore: Bool?

        if data["extra"].object != nil {
            let raw = asText(data["extra"]["next_query_danmaku_list_time"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty, let parsed = parseIntPrefix(raw) { nextMs = parsed }
        }
        let info = data["common_list_info"]
        if info.object != nil {
            switch info["has_more"] {
            case .bool(let b): hasMore = b
            case .string(let s): hasMore = ["1", "true", "yes"].contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            case let other:
                let text = asText(other)
                if !text.isEmpty { hasMore = !["0", "false", "no"].contains(text) }
            }
            var cursor = info["cursor"]
            if case .string(let s) = cursor, s.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                cursor = (try? JSONValue.parse(s)) ?? .null
            }
            if cursor.object != nil {
                for key in ["end_offset_time", "next_offset_time", "offset"] {
                    guard let candidate = intPrefix(cursor[key]) else { continue }
                    if nextMs == nil || candidate > nextMs! { nextMs = candidate }
                    break
                }
            }
        }
        if hasMore == false { nextMs = nil }

        var items: [RawItem] = []
        for raw in data["data_list"].array ?? [] {
            let comment = raw["comment"]
            guard comment.object != nil else { continue }
            let common = comment["common"].object != nil ? comment["common"] : .object([:])
            // Only this video, only status 1: other values are pending review or folded.
            let groupId = asText(common["group_id"])
            if !groupId.isEmpty, groupId != vid { continue }
            guard asText(common["status"]) == "1" else { continue }
            let content = common["content"]
            let text = asText(content.object != nil ? content["text"] : .null)
            let expand = comment["expand"].object != nil ? comment["expand"] : .object([:])
            var timeRaw = expand["offset_time"]
            if timeRaw.isNull { timeRaw = comment["offset_time"] }
            var colorRaw: JSONValue?
            holders: for holder in [content, common, expand, comment] {
                guard let object = holder.object else { continue }
                for key in ["color", "font_color", "text_color", "col"] {
                    if let value = object[key], !value.isNull { colorRaw = value; break holders }
                }
            }
            items.append(RawItem(text: text, timeRaw: timeRaw, color: normalizeColor(colorRaw), mode: normalizeMode([raw, comment])))
        }
        if let n = nextMs, n <= 0 { nextMs = nil }
        return Page(items: items, nextMs: nextMs, hasMore: hasMore)
    }
}

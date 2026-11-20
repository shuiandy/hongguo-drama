// SPDX-License-Identifier: GPL-3.0-only
// User-added Apple CMS endpoints (port of src/native/custom-source.js). Ids are
// `custom:<uuid>:<vod_id>` and episodes `custom:<uuid>:<vod_id>:<line>:<episode>`. Every request
// checks again that the source is still enabled with the same URL, and upstream messages are
// never shown (they can carry signed URLs).
import Foundation

public struct CustomSourceConfig: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Lowercase UUID; empty for a draft that has not been saved yet.
    public var id: String
    public var name: String
    public var url: String
    public var enabled: Bool

    public init(id: String = "", name: String, url: String, enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, name, url, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        // Electron treats anything but an explicit false as enabled when validating.
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }
}

public final class CustomSource: MediaSource {
    public let config: CustomSourceConfig
    public var id: String { "custom:\(config.id)" }
    public var label: String { config.name }

    public typealias Fetch = @Sendable (_ url: URL) async throws -> Data
    private let fetch: Fetch
    private let current: @Sendable (_ id: String) -> CustomSourceConfig?
    private let draft: Bool

    static let uuidPattern = "^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"

    /// `current` returns the stored entry for a source id, so a disabled or edited source stops at once.
    public init(config: CustomSourceConfig, current: @escaping @Sendable (String) -> CustomSourceConfig?, fetch: Fetch? = nil) {
        self.config = config
        self.current = current
        self.draft = false
        self.fetch = fetch ?? CustomSource.defaultFetch
    }

    private init(draft: CustomSourceConfig, fetch: Fetch?) {
        self.config = draft
        self.current = { _ in nil }
        self.draft = true
        self.fetch = fetch ?? CustomSource.defaultFetch
    }

    static let defaultFetch: Fetch = { url in
        var options = HTTPClient.Options()
        options.headers = ["Accept": "application/json", "User-Agent": "Mozilla/5.0"]
        options.timeout = 12
        options.maxBytes = 8 * 1024 * 1024
        return try await HTTPClient.shared.get(url, options: options).data
    }

    static func plainText(_ value: JSONValue) -> String { value.string.map { MediaSources.plainText($0) } ?? "" }

    // MARK: Configuration

    /// Name 1 to 80 characters; a public http(s) URL without credentials. A bare origin gets
    /// `/api.php/provide/vod/`; the fragment is dropped.
    public static func validate(_ draft: CustomSourceConfig) throws -> CustomSourceConfig {
        let name = MediaSources.plainText(draft.name)
        guard !name.isEmpty, name.count <= 80 else { throw HongguoError(.input, "来源名称需为 1 至 80 个字符") }
        if !draft.id.isEmpty && draft.id.range(of: uuidPattern, options: .regularExpression) == nil {
            throw HongguoError(.input, "自定义源编号无效")
        }
        guard draft.url.count <= 4096, let parsed = URL(string: draft.url), URLGuard.isPublicURL(parsed),
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            throw HongguoError(.input, "接口需为不含账号密码的公网 HTTP 或 HTTPS 地址")
        }
        if components.path.isEmpty || components.path == "/" { components.path = "/api.php/provide/vod/" }
        components.fragment = nil
        return CustomSourceConfig(id: draft.id.lowercased(), name: name, url: components.url!.absoluteString, enabled: draft.enabled)
    }

    /// The UUID from `custom:<uuid>[:…]` or a bare UUID.
    static func sourceId(_ value: String) throws -> String {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let id = parts.first == "custom" && parts.count > 1 ? parts[1] : parts[0]
        guard id.range(of: uuidPattern, options: .regularExpression) != nil else { throw HongguoError(.input, "自定义源编号无效") }
        return id.lowercased()
    }

    struct ID { var source: String; var vodId: String; var seriesId: String; var line: Int; var episode: Int }

    static func parseId(_ value: String, episode: Bool = false) throws -> ID {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "custom", parts.count == (episode ? 5 : 3), parts[1].range(of: uuidPattern, options: .regularExpression) != nil,
              parts[2].matchesDigits(min: 1, max: 30), !episode || parts[3...].allSatisfy({ $0.matchesDigits(min: 1, max: 5) }) else {
            throw HongguoError(.input, "自定义剧集编号无效")
        }
        let source = parts[1].lowercased()
        return ID(source: source, vodId: parts[2], seriesId: "custom:\(source):\(parts[2])",
                  line: episode ? Int(parts[3])! : 0, episode: episode ? Int(parts[4])! : 0)
    }

    /// Tries a draft endpoint before it is saved: item count of page 1 and its genres.
    public static func test(_ draft: CustomSourceConfig, fetch: Fetch? = nil) async throws -> (count: Int, genres: [Genre]) {
        let source = CustomSource(draft: try validate(draft), fetch: fetch)
        let data = try await source.request([("pg", "1")])
        return ((data["list"].array ?? []).count, try source.pageResult(data, page: 1).genres)
    }

    // MARK: Requests

    func checkCurrent() throws {
        guard !draft else { return }
        guard let stored = current(config.id), stored.enabled else { throw HongguoError(.unavailable, "该自定义源已禁用或删除") }
        guard (try? Self.validate(stored))?.url == config.url else { throw HongguoError(.input, "来源配置已变更，请重新加载") }
    }

    func request(_ params: [(String, String)]) async throws -> JSONValue {
        try checkCurrent()
        var components = URLComponents(string: config.url)!
        let reserved: Set<String> = ["ac", "pg", "t", "wd", "ids", "at"]
        components.queryItems = (components.queryItems ?? []).filter { !reserved.contains($0.name) }
            + ([("ac", "detail"), ("at", "json")] + params).map { URLQueryItem(name: $0.0, value: $0.1) }
        let body: Data
        do { body = try await fetch(components.url!) } catch let error as HongguoError where error.kind == .timeout || error.kind == .cancelled {
            throw HongguoError(.timeout, "自定义源请求已取消或超时，请重试")
        } catch {
            throw HongguoError(.network, "自定义源请求失败，请检查公网接口与网络")
        }
        try checkCurrent()
        guard let data = try? JSONValue.parse(body) else { throw HongguoError(.format, "自定义源未返回有效 JSON") }
        guard data["code"].number == 1, let list = data["list"].array, list.count <= 500 else {
            throw HongguoError(.format, "自定义源返回的苹果 CMS 数据无效")
        }
        return data
    }

    static func isLocked(_ item: JSONValue) -> Bool {
        let password = plainText(item["vod_pwd_play"]).isEmpty ? (item["vod_pwd"].string ?? "") : (item["vod_pwd_play"].string ?? "")
        return item["locked"] == .bool(true) || (item["vod_points_play"].number ?? 0) > 0 || (item["vod_points"].number ?? 0) > 0
            || !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func item(_ item: JSONValue) -> SeriesSummary? {
        guard let id = item["vod_id"].idString, id.matchesDigits(min: 1, max: 30) else { return nil }
        let title = Self.plainText(item["vod_name"])
        guard !title.isEmpty else { return nil }
        let cover = item["vod_pic"].string.flatMap { URLGuard.isPublicURL($0) ? $0 : nil } ?? ""
        let type = Self.plainText(item["type_name"])
        return SeriesSummary(seriesId: "custom:\(config.id):\(id)", title: title, cover: cover,
                             episodeCount: item["vod_total"].number.map(Int.init) ?? 0, tags: type.isEmpty ? [] : [type],
                             description: Self.plainText(item["vod_content"]))
    }

    func pageResult(_ data: JSONValue, page: Int) throws -> SourcePage {
        if !data["page"].isNull, data["page"].number != Double(page) { throw HongguoError(.format, "自定义源返回的页码不一致") }
        let results = NextPage.dedupe((data["list"].array ?? []).map(item))
        let totalPages = max(0, data["pagecount"].number.map(Int.init) ?? 0)
        let genres = (data["class"].array ?? []).prefix(500).compactMap { item -> Genre? in
            guard let id = item["type_id"].idString, id.matchesDigits(min: 1, max: 30) else { return nil }
            let label = Self.plainText(item["type_name"])
            return label.isEmpty ? nil : Genre(slug: id, label: label)
        }
        return SourcePage(results: results, page: page, hasMore: !results.isEmpty && page < totalPages, genres: genres,
                          total: max(0, data["total"].number.map(Int.init) ?? 0))
    }

    public func browse(genre: String?, page: Int) async throws -> SourcePage {
        let genre = genre.flatMap { $0.isEmpty ? nil : $0 }
        guard (1...100000).contains(page), genre.map({ $0.matchesDigits(min: 1, max: 30) }) ?? true else {
            throw HongguoError(.input, "自定义源分类或页码无效")
        }
        return try pageResult(try await request([("pg", String(page))] + (genre.map { [("t", $0)] } ?? [])), page: page)
    }

    public func search(_ keyword: String, page: Int) async throws -> SourcePage {
        let wd = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wd.isEmpty, wd.count <= 200, (1...100000).contains(page) else { throw HongguoError(.input, "自定义源搜索词或页码无效") }
        return try pageResult(try await request([("wd", wd), ("pg", String(page))]), page: page)
    }

    // MARK: Episodes

    func detail(_ seriesId: String) async throws -> (id: ID, item: JSONValue) {
        let id = try Self.parseId(seriesId)
        guard id.source == config.id else { throw HongguoError(.input, "自定义分集不属于当前来源") }
        let list = try await request([("ids", id.vodId)])["list"].array ?? []
        guard list.count == 1, list[0]["vod_id"].idString == id.vodId else { throw HongguoError(.format, "自定义源返回的剧集与请求不一致") }
        guard item(list[0]) != nil else { throw HongguoError(.format, "自定义源详情无效") }
        return (id, list[0])
    }

    static func episodeKey(_ title: String) -> String {
        guard let match = HTMLData.firstMatch("^(?:第\\s*)?(\\d+)\\s*(?:集|话|期)?$", in: title, options: []), match.count > 1,
              let number = Int(match[1]) else { return title }
        return "number:\(number)"
    }

    struct MediaEntry { var title: String; var key: String; var url: URL; var line: Int; var episode: Int }

    /// Playable lines of `vod_play_url` (`$$$` between lines, `#` between episodes, `title$url`).
    static func mediaLines(_ item: JSONValue) -> [(line: Int, episodes: [MediaEntry])] {
        (item["vod_play_url"].idString ?? "").components(separatedBy: "$$$").prefix(32).enumerated().map { lineIndex, line in
            let episodes = line.components(separatedBy: "#").prefix(10000).enumerated().compactMap { episodeIndex, entry -> MediaEntry? in
                guard let split = entry.firstIndex(of: "$"), split > entry.startIndex else { return nil }
                let title = MediaSources.plainText(String(entry[..<split]))
                let value = entry[entry.index(after: split)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let url = URL(string: value), URLGuard.isPublicURL(url),
                      ["mp4", "m3u8"].contains(url.pathExtension.lowercased()) else { return nil }
                return MediaEntry(title: title, key: episodeKey(title), url: url, line: lineIndex, episode: episodeIndex)
            }
            return (lineIndex, episodes)
        }.filter { !$0.episodes.isEmpty }
    }

    public func episodes(seriesId: String) async throws -> SeriesEpisodes {
        let (id, raw) = try await detail(seriesId)
        // The line with the most episodes, duplicates by episode number removed.
        guard let best = Self.mediaLines(raw).enumerated().max(by: { a, b in
            a.element.episodes.count != b.element.episodes.count ? a.element.episodes.count < b.element.episodes.count : a.offset > b.offset
        })?.element else { throw HongguoError(.unavailable, "该剧没有可直接播放的 MP4 或 M3U8 分集，不支持网页解析") }
        let summary = item(raw)!
        let locked = Self.isLocked(raw)
        var seen = Set<String>()
        let episodes = best.episodes.filter { seen.insert($0.key).inserted }.enumerated().map { offset, entry in
            Episode(vid: "\(id.seriesId):\(entry.line):\(entry.episode)", index: offset + 1, title: entry.title, seriesId: id.seriesId,
                    webAvailable: !locked, locked: locked)
        }
        return SeriesEpisodes(seriesId: id.seriesId, title: summary.title, cover: summary.cover, episodes: episodes,
                              webAccessibleEpisodes: locked ? 0 : episodes.count, source: .web)
    }

    /// The chosen episode first, then the same episode on the other lines (deduplicated by URL).
    public func playCandidates(vid: String, seriesId: String?) async throws -> [PlayInfo] {
        let id = try Self.parseId(vid, episode: true)
        if let seriesId, !seriesId.isEmpty, try Self.parseId(seriesId).seriesId != id.seriesId {
            throw HongguoError(.input, "自定义分集不属于当前剧集")
        }
        let (_, raw) = try await detail(id.seriesId)
        if Self.isLocked(raw) { throw MediaSources.locked("该剧当前需付费或密码，请在来源平台确认观看权限") }
        let lines = Self.mediaLines(raw)
        guard let selected = lines.first(where: { $0.line == id.line })?.episodes.first(where: { $0.episode == id.episode }) else {
            throw HongguoError(.upstream, "自定义源未找到可直接播放的分集")
        }
        var urls = Set<URL>()
        let referer = URL(string: config.url).map { "\($0.scheme!)://\($0.host!)\($0.port.map { ":\($0)" } ?? "")/" }
        return ([selected] + lines.flatMap { $0.episodes.filter { $0.key == selected.key } }).filter { urls.insert($0.url).inserted }.map {
            PlayInfo(url: $0.url, spadeA: nil, codec: "", source: .web, vid: "\(id.seriesId):\($0.line):\($0.episode)",
                     userAgent: "Mozilla/5.0", referer: referer)
        }
    }

    public func playInfo(vid: String, seriesId: String?) async throws -> PlayInfo {
        try await playCandidates(vid: vid, seriesId: seriesId)[0]
    }
}

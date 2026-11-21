import Foundation

/// An actor's home page as the official iOS app shows it: the actor's own 红果 account's user
/// profile (`sslocal://guest_profile?uid=…`, the `schema` of each `celebrities` entry in the series
/// detail). POST `/novel/commentapi/user/profile/:target_user_id/v1/` (`FQCRpcGetUserProfileRequest`,
/// the comment RPC service, so signed like the comment lists), signed out, `comment_source` 1506,
/// `server_channel` 0, `sort` time_desc, as `SSBizCustomUserDataManager` sends it.
///
/// The first read (no tab) gives the tabs. On the current client (7.4.5.32): 作品 (23; sub tabs 全部
/// 100, 剧作 22, 预约 20, 合集 13, 剧评 121) and 红果圈; 全部 also holds the actor's own single videos.
/// Older clients got 剧作 (8), 动态 and 红果圈. A read with a tab and sub tab gives that list. The works lists hold `video` items
/// (title, cover, intro, episode count, genre, heat) and `subscribe_item` items (series not out yet).
/// The server sends no sort options (`sort_cfgs` is empty), so 最热 is sorted here by heat.
public struct ActorHome: Sendable, Equatable {
    public struct Tab: Sendable, Hashable, Identifiable {
        /// `tab_type`; a sub tab's is the `sub_tab_type` to ask for.
        public var type: Int
        public var name: String
        public var total: Int?
        public var subTabs: [Tab]
        public var id: Int { type }

        public init(type: Int, name: String, total: Int? = nil, subTabs: [Tab] = []) {
            self.type = type; self.name = name; self.total = total; self.subTabs = subTabs
        }
    }

    public var tabs: [Tab]
    /// `hightlight` (sic): the tab the page opens on.
    public var highlight: Int?

    /// The tab of the actor's works: 作品 (23) on the current client, with sub tabs 全部, 剧作, 预约,
    /// 合集 and 剧评; 剧作 (8) on older clients.
    public var worksTab: Tab? {
        tabs.first { ActorHomeService.worksTabTypes.contains($0.type) } ?? tabs.first { ["作品", "剧作"].contains($0.name) }
    }

    /// The works tab's sub tabs the apps can show: all but 剧评 (121), whose list holds review posts,
    /// not series.
    public var worksSubTabs: [Tab] {
        (worksTab?.subTabs ?? []).filter { $0.type != ActorHomeService.reviewSubTabType && $0.name != "剧评" }
    }
}

/// One list of an actor's home page.
public struct ActorWorksPage: Sendable, Equatable {
    /// Released series and series not out yet, in the server's order.
    public var items: [SeriesSummary]
    /// The series in `items` that are not out yet (预约), which cannot be played.
    public var upcomingIds: Set<String>
    /// The merged card's text in 全部, e.g. 7部剧可预约; "" when there is none.
    public var upcomingNote: String
    public var cursor: String
    public var hasMore: Bool

    public init(items: [SeriesSummary], upcomingIds: Set<String> = [], upcomingNote: String = "", cursor: String = "", hasMore: Bool = false) {
        self.items = items; self.upcomingIds = upcomingIds; self.upcomingNote = upcomingNote; self.cursor = cursor; self.hasMore = hasMore
    }
}

public enum ActorHomeService {
    static let commentSource = 1506
    static let serverChannel = 0
    static let worksTabTypes = [23, 8]
    static let reviewSubTabType = 121
    private static let homeCache = TTLCache<ActorHome>(limit: 64)
    private static let pageCache = TTLCache<ActorWorksPage>(limit: 128)

    static func path(_ userId: String) -> String { "/novel/commentapi/user/profile/\(userId)/v1/" }

    /// The tabs of `userId`'s home page (cached for five minutes).
    public static func home(userId: String, http: HTTPClient = .shared) async throws -> ActorHome {
        if let cached = await homeCache.get(userId) { return cached }
        let home = try parseHome(try await request(userId: userId, http: http))
        await homeCache.set(userId, home, ttl: 300)
        return home
    }

    /// One list (`tab`, `subTab`) of `userId`'s home page; the first page is cached for five minutes.
    public static func works(userId: String, tab: Int, subTab: Int, cursor: String = "",
                             http: HTTPClient = .shared) async throws -> ActorWorksPage {
        let key = "\(userId):\(tab):\(subTab)"
        if cursor.isEmpty, let cached = await pageCache.get(key) { return cached }
        let page = try parseWorks(try await request(userId: userId, tab: tab, subTab: subTab, cursor: cursor, http: http))
        if cursor.isEmpty { await pageCache.set(key, page, ttl: 300) }
        return page
    }

    static func request(userId: String, tab: Int? = nil, subTab: Int? = nil, cursor: String = "",
                        http: HTTPClient = .shared) async throws -> JSONValue {
        guard userId.matchesDigits(min: 6, max: 30), cursor.count <= 1000 else {
            throw HongguoError(.input, "演员主页请求参数无效")
        }
        var body: [String: Any] = [
            "target_user_id": userId, "comment_source": commentSource, "server_channel": serverChannel,
            "count": 18, "cursor": cursor, "sort": "time_desc", "aid": 8662,
            "extra_param": ["enter_source": "0"],
        ]
        if let tab { body["tab_type"] = tab }
        if let subTab { body["sub_tab_type"] = subTab }
        return try await AppCommentClient.post(path(userId), body: body,
                                               headers: [("Comment-Source", String(commentSource)), ("Server-Channel", String(serverChannel))],
                                               http: http)
    }

    static func check(_ json: JSONValue) throws {
        let code = Int(json["code"].number ?? -1)
        guard code == 0 else { throw HongguoError(.upstream, "红果演员主页暂时不可用（\(code)）") }
    }

    static func parseHome(_ json: JSONValue) throws -> ActorHome {
        try check(json)
        let data = json["data"]
        func tab(_ value: JSONValue) -> ActorHome.Tab? {
            guard let type = EpisodeSocialService.integer(value["tab_type"]) else { return nil }
            let name = AccountService.cleanText(value["name"].string)
            guard !name.isEmpty, value["is_privacy_tab"].bool != true else { return nil }
            return .init(type: type, name: name, total: EpisodeSocialService.integer(value["total"]),
                         subTabs: (value["sub_tabs"].array ?? []).compactMap(tab))
        }
        return ActorHome(tabs: (data["tabs"].array ?? []).compactMap(tab),
                         highlight: EpisodeSocialService.integer(data["hightlight"]) ?? EpisodeSocialService.integer(data["hightlight"]["tab_type"]))
    }

    static func parseWorks(_ json: JSONValue) throws -> ActorWorksPage {
        try check(json)
        let data = json["data"]
        var seen = Set<String>()
        var items: [SeriesSummary] = []
        var upcomingIds = Set<String>()
        var note = ""
        for entry in data["data_list"].array ?? [] {
            if entry["video"].object != nil {
                if let item = released(entry["video"]), seen.insert(item.seriesId).inserted { items.append(item) }
            } else if entry["subscribe_item"].object != nil {
                let card = entry["subscribe_item"]
                if card["is_merged_data"].bool == true {
                    if note.isEmpty { note = AccountService.cleanText(card["name"].string) }
                } else if let item = upcoming(card), seen.insert(item.seriesId).inserted {
                    items.append(item)
                    upcomingIds.insert(item.seriesId)
                }
            }
        }
        let info = data["common_list_info"]
        return ActorWorksPage(items: items, upcomingIds: upcomingIds, upcomingNote: note.count <= 40 ? note : "",
                              cursor: info["cursor"].string ?? "", hasMore: info["has_more"].bool ?? false)
    }

    /// A `video` item: `video_id`, `common` {title, cover, intro}, `expand` {episode_cnt,
    /// sub_title_list}, `stat` {hot}. The card reads like the official one: heat on the cover,
    /// genre · N集 under the title.
    static func released(_ video: JSONValue) -> SeriesSummary? {
        let common = video["common"], expand = video["expand"]
        let id = (video["video_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
        let title = AccountService.cleanText(common["title"].string)
        guard id.matchesDigits(min: 6, max: 30), !title.isEmpty else { return nil }
        let tags = texts(expand["sub_title_list"])
        let episodes = EpisodeSocialService.integer(expand["episode_cnt"]).flatMap { $0 > 0 ? $0 : nil } ?? 0
        return SeriesSummary(
            seriesId: id, title: title, cover: cover(common["cover"].string), episodeCount: episodes, tags: tags,
            description: String(AccountService.cleanText(common["intro"].string).prefix(500)),
            heat: heatText(video["stat"]["hot"].number),
            episodeLabel: label(tags.first, episodes))
    }

    /// A `subscribe_item` (预约): a series not out yet, with its date.
    static func upcoming(_ card: JSONValue) -> SeriesSummary? {
        let id = (card["item_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
        let title = AccountService.cleanText(card["name"].string)
        guard id.matchesDigits(min: 6, max: 30), !title.isEmpty else { return nil }
        let date = EpisodeSocialService.date(card["schedule_publish_time"])
        let tags = texts(card["sub_title_list"])
        return SeriesSummary(seriesId: id, title: title, cover: cover(card["cover"].string), tags: tags,
                             episodeLabel: date.map(releaseLabel) ?? "待上线", publishedAt: date)
    }

    /// `sub_title_list` entries: plain strings or objects with a text field.
    static func texts(_ list: JSONValue) -> [String] {
        var seen = Set<String>()
        return (list.array ?? []).compactMap { item -> String? in
            let text = AccountService.cleanText(item.string ?? item["content"].string ?? item["text"].string ?? item["name"].string)
            guard !text.isEmpty, text.count <= 12, seen.insert(text).inserted else { return nil }
            return text
        }
    }

    static func cover(_ raw: String?) -> String {
        let value = raw ?? ""
        let cleaned = AccountService.cleanCover(value)
        return AccountDataAccess.normalizeHTTPSURL(cleaned.isEmpty ? value : cleaned)
    }

    /// 都市·81集, as under the official card's title.
    static func label(_ genre: String?, _ episodes: Int) -> String {
        [genre ?? "", episodes > 0 ? "\(episodes)集" : ""].filter { !$0.isEmpty }.joined(separator: "·")
    }

    /// 11月28日上线.
    static func releaseLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日上线"
    }

    /// 15049000 → 1504.9万热度, 120000000 → 1.2亿热度; "" for nothing.
    static func heatText(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "" }
        func short(_ number: Double) -> String {
            let text = String(format: "%.1f", number)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        if value >= 100_000_000 { return short(value / 100_000_000) + "亿热度" }
        if value >= 10_000 { return short(value / 10_000) + "万热度" }
        return "\(Int(value))热度"
    }

    /// Works most popular first (最热), by the number in their heat text; works without one go last
    /// and ties keep the server's order.
    public static func hottestFirst(_ items: [SeriesSummary]) -> [SeriesSummary] {
        items.enumerated()
            .sorted { a, b in
                let (x, y) = (heatScore(a.element.heat), heatScore(b.element.heat))
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
    }

    /// 4210万热度 → 42_100_000, 1.2亿热度 → 120_000_000, 5300热度 → 5300; 0 when there is no number.
    public static func heatScore(_ text: String) -> Double {
        guard let range = text.range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression),
              let number = Double(text[range]) else { return 0 }
        switch text[range.upperBound...].first {
        case "亿": return number * 100_000_000
        case "万": return number * 10_000
        default: return number
        }
    }
}

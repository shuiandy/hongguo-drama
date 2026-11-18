import Foundation

/// A series kept on this Mac: everything opened (the 剧库) plus the favourite flag, per-episode
/// "likes" and the public first-release date used by the release calendar. Port of
/// src/localLibrary.js plus the browse registry in main.js. Reviews are never stored.
public struct LibrarySeries: Codable, Identifiable, Hashable, Sendable {
    public var id: String { seriesId }
    public var seriesId: String
    public var title: String
    public var cover: String
    public var episodeCount: Int
    public var favorite: Bool
    public var likedEpisodeIds: [String]
    /// Public first-release time, when known (from public details).
    public var publishedAt: Date?
    public var addedAt: Date
    public var lastOpenedAt: Date
    public var favoritedAt: Date?

    /// `yyyy-MM-dd` in Beijing time, or "" when unknown (`publicDateKey`).
    public var publicDateKey: String { SeriesLibrary.publicDateKey(publishedAt) }
}

public final class SeriesLibrary: @unchecked Sendable {
    public static let shared = SeriesLibrary()

    private let store: JSONFileStore<[String: LibrarySeries]>?
    private let lock = NSLock()
    private var items: [String: LibrarySeries]
    /// Called after every change (on the caller's thread).
    public var onChange: (@Sendable () -> Void)?

    public init(directory: URL? = JSONFileStore<[String: LibrarySeries]>.defaultDirectory) {
        store = directory.map { JSONFileStore(directory: $0, name: "series-library.json") }
        items = store?.load(default: [:]) ?? [:]
    }

    // MARK: Reading

    public func series(_ seriesId: String) -> LibrarySeries? { lock.withLock { items[seriesId] } }

    public func isFavorite(_ seriesId: String) -> Bool { lock.withLock { items[seriesId]?.favorite ?? false } }

    /// Most recently opened first.
    public func recent(limit: Int? = nil) -> [LibrarySeries] {
        let sorted = lock.withLock { Array(items.values) }.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    /// Most recently favourited first.
    public func favorites() -> [LibrarySeries] {
        lock.withLock { items.values.filter(\.favorite) }
            .sorted { ($0.favoritedAt ?? $0.addedAt) > ($1.favoritedAt ?? $1.addedAt) }
    }

    /// Release calendar: dated series grouped by `yyyy-MM` (newest month first), each month's
    /// series by date (newest first) then title.
    public func calendar(favoritesOnly: Bool = false) -> [(month: String, series: [LibrarySeries])] {
        let dated = lock.withLock { Array(items.values) }.filter { (!favoritesOnly || $0.favorite) && !$0.publicDateKey.isEmpty }
        let grouped = Dictionary(grouping: dated) { String($0.publicDateKey.prefix(7)) }
        return grouped.keys.sorted(by: >).map { month in
            (month, grouped[month]!.sorted {
                $0.publicDateKey != $1.publicDateKey ? $0.publicDateKey > $1.publicDateKey
                    : $0.title.compare($1.title, locale: Locale(identifier: "zh_CN")) == .orderedAscending
            })
        }
    }

    // MARK: Writing

    /// Records that a series was opened. Keeps the favourite flag and likes; fills metadata
    /// that is missing and never replaces known data with blanks.
    @discardableResult
    public func recordOpened(seriesId: String, title: String, cover: String = "", episodeCount: Int = 0,
                             publishedAt: Date? = nil, now: Date = Date()) throws -> LibrarySeries {
        try mutate(seriesId: seriesId, title: title, now: now) { item in
            item.lastOpenedAt = now
            if !cover.isEmpty, URLGuard.isPublicURL(cover) { item.cover = cover }
            item.episodeCount = max(item.episodeCount, episodeCount)
            if let publishedAt, publishedAt.timeIntervalSince1970 > 0 { item.publishedAt = publishedAt }
        }
    }

    public func record(_ summary: SeriesSummary, now: Date = Date()) throws {
        try recordOpened(seriesId: summary.seriesId, title: summary.title, cover: summary.cover,
                         episodeCount: summary.episodeCount, publishedAt: summary.publishedAt, now: now)
    }

    @discardableResult
    public func setFavorite(_ favorite: Bool, seriesId: String, title: String, cover: String = "", now: Date = Date()) throws -> LibrarySeries {
        try mutate(seriesId: seriesId, title: title, now: now) { item in
            if item.favorite != favorite { item.favoritedAt = favorite ? now : nil }
            item.favorite = favorite
            if !cover.isEmpty, item.cover.isEmpty, URLGuard.isPublicURL(cover) { item.cover = cover }
        }
    }

    @discardableResult
    public func toggleFavorite(seriesId: String, title: String, cover: String = "") throws -> Bool {
        let next = !isFavorite(seriesId)
        try setFavorite(next, seriesId: seriesId, title: title, cover: cover)
        return next
    }

    /// Toggles the local "little red heart" on one episode. Returns the new state.
    @discardableResult
    public func toggleEpisodeLike(seriesId: String, title: String, vid: String) throws -> Bool {
        let id = vid.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw HongguoError(.input, "分集编号无效") }
        var liked = false
        try mutate(seriesId: seriesId, title: title, now: Date()) { item in
            if let index = item.likedEpisodeIds.firstIndex(of: id) {
                item.likedEpisodeIds.remove(at: index)
            } else {
                item.likedEpisodeIds.append(id)
                liked = true
            }
        }
        return liked
    }

    /// Removes the local record only; downloaded videos are untouched.
    public func remove(_ seriesId: String) throws {
        try lock.withLock {
            var next = items
            next[seriesId] = nil
            try store?.save(next)
            items = next
        }
        onChange?()
    }

    private func mutate(seriesId: String, title: String, now: Date, _ body: (inout LibrarySeries) -> Void) throws -> LibrarySeries {
        let id = seriesId.trimmingCharacters(in: .whitespaces)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw HongguoError(.input, "缺少剧集编号，无法保存到本机") }
        let result: LibrarySeries = try lock.withLock {
            var item = items[id] ?? LibrarySeries(seriesId: id, title: cleanTitle, cover: "", episodeCount: 0, favorite: false,
                                                  likedEpisodeIds: [], publishedAt: nil, addedAt: now, lastOpenedAt: now, favoritedAt: nil)
            if !cleanTitle.isEmpty { item.title = cleanTitle }
            guard !item.title.isEmpty else { throw HongguoError(.input, "缺少剧集名称，无法保存到本机") }
            body(&item)
            var next = items
            next[id] = item
            // Persist first: a failed write leaves memory and disk unchanged.
            do { try store?.save(next) } catch {
                throw HongguoError(.input, "未能保存到本机：\(error.localizedDescription)。请释放存储空间后重试")
            }
            items = next
            return item
        }
        onChange?()
        return result
    }

    static func publicDateKey(_ date: Date?) -> String {
        guard let date, date.timeIntervalSince1970 > 0 else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

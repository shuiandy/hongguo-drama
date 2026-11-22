import Foundation

/// The lists behind a row of swipeable tabs (排行榜 categories, 新剧推荐 / 上新日历), one per key, kept
/// in memory. Each key owns its items, load phase, paging cursor and whether more is loading, so
/// going back to a tab shows what it had at once and a tab that has nothing yet shows its own
/// spinner, never another tab's rows.
///
/// Every request gets a ticket naming the key it was made for. A reply lands only under that key,
/// and only while it is still that key's newest request: a slow reply for a tab the viewer has
/// left fills that tab's cache and nothing else, and a reply overtaken by a newer request for the
/// same tab (a pull to refresh, a retry) is dropped.
public struct TabPages<Key: Hashable & Sendable, Item: Identifiable & Sendable, Cursor: Sendable>: Sendable
where Item.ID: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, loading, loaded, failed(String)
    }

    public struct Page: Sendable {
        public var items: [Item] = []
        public var phase: Phase = .idle
        public var cursor: Cursor?
        public var loadingMore = false
    }

    public struct Ticket: Equatable, Sendable {
        public let key: Key
        fileprivate let id: Int
    }

    private var pages: [Key: Page] = [:]
    private var newest: [Key: Int] = [:]
    private var newestMore: [Key: Int] = [:]
    private var lastId = 0

    public init() {}

    public func page(_ key: Key) -> Page { pages[key] ?? Page() }

    /// Nothing loaded and nothing on the way: the tab should start its first request when it comes
    /// into view (or next to it). A failed tab waits for a retry instead of retrying on its own.
    public func needsLoad(_ key: Key) -> Bool { page(key).phase == .idle }

    /// Starts a first-page request. `keepingItems` (pull to refresh) leaves the rows on screen
    /// until the reply; otherwise the tab is emptied, so it shows its spinner.
    public mutating func beginLoad(_ key: Key, keepingItems: Bool = false) -> Ticket {
        lastId += 1
        newest[key] = lastId
        newestMore[key] = nil
        var page = page(key)
        if !keepingItems { page.items = [] }
        page.phase = .loading
        page.loadingMore = false
        pages[key] = page
        return Ticket(key: key, id: lastId)
    }

    /// Whether the reply was stored (it is still its tab's newest request).
    @discardableResult
    public mutating func finishLoad(_ ticket: Ticket, items: [Item], cursor: Cursor?) -> Bool {
        guard newest[ticket.key] == ticket.id else { return false }
        pages[ticket.key] = Page(items: Self.unique(items), phase: .loaded, cursor: cursor, loadingMore: false)
        return true
    }

    @discardableResult
    public mutating func failLoad(_ ticket: Ticket, message: String) -> Bool {
        guard newest[ticket.key] == ticket.id else { return false }
        var page = page(ticket.key)
        // Rows kept through a pull to refresh stay; an empty tab shows the error with 重试.
        page.phase = page.items.isEmpty ? .failed(message) : .loaded
        pages[ticket.key] = page
        return true
    }

    /// Starts loading the next page, if the tab is loaded, has a cursor and is not already at it.
    public mutating func beginMore(_ key: Key) -> Ticket? {
        var page = page(key)
        guard page.phase == .loaded, page.cursor != nil, !page.loadingMore else { return nil }
        lastId += 1
        newestMore[key] = lastId
        page.loadingMore = true
        pages[key] = page
        return Ticket(key: key, id: lastId)
    }

    /// Appends the next page (rows already shown are skipped). Dropped if the tab was reloaded in
    /// the meantime.
    @discardableResult
    public mutating func finishMore(_ ticket: Ticket, items: [Item], cursor: Cursor?) -> Bool {
        guard newestMore[ticket.key] == ticket.id, var page = pages[ticket.key] else { return false }
        newestMore[ticket.key] = nil
        let shown = Set(page.items.map(\.id))
        page.items += Self.unique(items).filter { !shown.contains($0.id) }
        page.cursor = cursor
        page.loadingMore = false
        pages[ticket.key] = page
        return true
    }

    /// A failed next page leaves the rows as they are and lets the tab try again.
    public mutating func failMore(_ ticket: Ticket) {
        guard newestMore[ticket.key] == ticket.id else { return }
        newestMore[ticket.key] = nil
        pages[ticket.key]?.loadingMore = false
    }

    private static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

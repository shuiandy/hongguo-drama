/// Per-comment reply pagination and expand/collapse state.
public struct CommentReplyThread<Reply: Identifiable & Equatable>: Equatable where Reply.ID: Hashable {
    public private(set) var replies: [Reply] = []
    public private(set) var total: Int = 0
    public private(set) var cursor: String = ""
    public private(set) var hasMore: Bool = false
    public private(set) var isExpanded: Bool = false
    public private(set) var isLoading: Bool = false
    public private(set) var failed: Bool = false
    public private(set) var loadedOnce: Bool = false

    public init(reportedCount: Int = 0) {
        self.total = max(0, reportedCount)
        self.hasMore = reportedCount > 0
    }

    /// Number of remaining replies estimated from the higher of reported/server total and loaded items.
    public func remainingCount(reportedCount: Int) -> Int {
        let knownTotal = max(total, reportedCount)
        return max(0, knownTotal - replies.count)
    }

    /// Total count to show on the collapsed toggle button.
    public func displayTotal(reportedCount: Int) -> Int {
        max(total, reportedCount, replies.count)
    }

    /// Expands the thread or requests the next page.
    /// Returns the cursor to fetch, or `nil` when already loading or when re-expanding cached replies.
    public mutating func beginExpandOrLoadMore() -> String? {
        guard !isLoading else { return nil }
        if !isExpanded, loadedOnce, !replies.isEmpty {
            isExpanded = true
            failed = false
            return nil
        }
        isExpanded = true
        isLoading = true
        failed = false
        if replies.isEmpty {
            cursor = ""
        }
        return cursor
    }

    public mutating func collapse() {
        isExpanded = false
        failed = false
    }

    public mutating func applyPage(
        _ incoming: [Reply],
        total reportedTotal: Int?,
        nextCursor: String,
        hasMore serverHasMore: Bool,
        requestedCursor: String
    ) {
        isLoading = false
        failed = false
        loadedOnce = true
        var seen = Set(replies.map(\.id))
        for item in incoming where seen.insert(item.id).inserted {
            replies.append(item)
        }
        if let reportedTotal, reportedTotal >= 0 {
            total = max(reportedTotal, replies.count)
        } else {
            total = max(total, replies.count)
        }
        let cursorAdvanced = !nextCursor.isEmpty && nextCursor != requestedCursor
        cursor = nextCursor
        hasMore = serverHasMore && cursorAdvanced
    }

    public mutating func fail() {
        isLoading = false
        failed = true
    }
}

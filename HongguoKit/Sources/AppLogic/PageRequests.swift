/// Tracks the filter and refresh that own a list and its pagination cursor.
public struct PageRequests<Filter: Equatable> {
    public private(set) var filter: Filter?
    private var generation = 0
    public private(set) var loadingMore = false

    public init() {}

    public mutating func reload(_ filter: Filter) -> Int {
        self.filter = filter
        generation += 1
        loadingMore = false
        return generation
    }

    public func accepts(_ ticket: Int, showing: Filter) -> Bool {
        generation == ticket && filter == showing
    }

    public mutating func beginMore(showing: Filter) -> Int? {
        guard filter == showing, !loadingMore else { return nil }
        loadingMore = true
        return generation
    }

    public mutating func finishMore(_ ticket: Int) {
        if generation == ticket { loadingMore = false }
    }
}

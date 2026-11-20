import Foundation

/// Background check of watched series for new episodes and later seasons. Port of
/// `refreshWatchHistory` in main.js: unfinished series every 6 hours, finished ones daily,
/// two series at a time, a 10 s budget per request, results written back to the watch records.
public actor WatchUpdateChecker {
    public struct Summary: Equatable, Sendable {
        public var checked = 0
        public var withUpdates = 0
        public var failed = 0
    }

    public static let interval: TimeInterval = 6 * 60 * 60
    public static let finishedInterval: TimeInterval = 24 * 60 * 60
    static let itemTimeout: Duration = .seconds(10)

    private let store: LibraryStore
    private let episodeCount: @Sendable (String) async throws -> Int
    private let searchCandidates: @Sendable (String) async throws -> [SeriesRef]
    private let now: @Sendable () -> Date
    private let concurrency: Int
    private var running: Task<Summary, Never>?

    public init(store: LibraryStore = .shared,
                episodeCount: (@Sendable (String) async throws -> Int)? = nil,
                searchCandidates: (@Sendable (String) async throws -> [SeriesRef])? = nil,
                now: @escaping @Sendable () -> Date = { Date() }, concurrency: Int = 2) {
        self.store = store
        self.now = now
        self.concurrency = max(1, concurrency)
        let series = SeriesService(), search = AppSearchService()
        self.episodeCount = episodeCount ?? { try await series.episodes(seriesId: $0, force: true).total }
        self.searchCandidates = searchCandidates ?? { keyword in
            try await search.search(keyword).results.map { SeriesRef(seriesId: $0.seriesId, title: $0.title) }
        }
    }

    /// Whether a record is due for a check.
    /// `every` is the check interval for unfinished series (settings: 检查频率); finished ones use at least a day.
    public static func isDue(_ record: WatchRecord, now: Date, every: TimeInterval = interval) -> Bool {
        guard let last = record.lastCheckedAt else { return true }
        return now.timeIntervalSince(last) >= (record.isFinished ? max(finishedInterval, every) : every)
    }

    /// Checks due records (all with `force`). Concurrent calls share one run.
    @discardableResult
    public func refresh(force: Bool = false, includeSequels: Bool = true, every: TimeInterval = interval) async -> Summary {
        if let running { return await running.value }
        let task = Task { await self.run(force: force, includeSequels: includeSequels, every: every) }
        running = task
        let result = await task.value
        running = nil
        return result
    }

    /// Checks one series now (opening its history row).
    public func check(seriesId: String, includeSequels: Bool = true) async -> WatchRecord? {
        guard let record = store.record(for: seriesId) else { return nil }
        _ = await checkOne(record, includeSequels: includeSequels)
        return store.record(for: seriesId)
    }

    private func run(force: Bool, includeSequels: Bool, every: TimeInterval) async -> Summary {
        let at = now()
        let due = store.history().filter { force || Self.isDue($0, now: at, every: every) }
        var summary = Summary()
        await withTaskGroup(of: Bool?.self) { group in
            var iterator = due.makeIterator()
            var started = 0
            while started < concurrency, let record = iterator.next() {
                group.addTask { await self.checkOne(record, includeSequels: includeSequels) }
                started += 1
            }
            while let outcome = await group.next() {
                summary.checked += 1
                switch outcome {
                case .some(true): summary.withUpdates += 1
                case .none: summary.failed += 1
                default: break
                }
                if let record = iterator.next() {
                    group.addTask { await self.checkOne(record, includeSequels: includeSequels) }
                }
            }
        }
        return summary
    }

    /// Returns true when the record has updates, false when not, nil when the check failed.
    private func checkOne(_ record: WatchRecord, includeSequels: Bool) async -> Bool? {
        let id = record.seriesId
        var failure: String?
        do {
            let total = try await Self.withTimeout { try await self.episodeCount(id) }
            store.updateRecord(id) { $0.applyingEpisodeUpdate(freshTotal: total, now: self.now()) }
        } catch {
            failure = "分集更新检查失败"
        }
        if includeSequels, WatchHistory.source(of: id) == .hongguo {
            let keyword = WatchHistory.sequelKeyword(record.title)
            if !keyword.isEmpty {
                do {
                    let candidates = try await Self.withTimeout { try await self.searchCandidates(keyword) }
                    let current = store.record(for: id)
                    let sequels = WatchHistory.findSequels(of: SeriesRef(seriesId: id, title: record.title), in: candidates)
                    if current != nil { store.updateRecord(id) { $0.applyingSequels(sequels, now: self.now()) } }
                } catch {
                    failure = failure.map { $0 + "；续集检查失败" } ?? "续集检查失败"
                }
            }
        }
        let stamp = now()
        let updated = store.updateRecord(id) {
            var copy = $0
            copy.lastCheckedAt = stamp
            copy.lastCheckError = failure
            return copy
        }
        if failure != nil, updated?.hasUpdates != true { return nil }
        return updated?.hasUpdates ?? false
    }

    static func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: itemTimeout)
                throw HongguoError(.timeout, "检查超时")
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

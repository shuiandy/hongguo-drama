import Foundation

/// The official website, only as the target of share links and "open the source page" links. No
/// page of it is read for data.
public enum Site {
    public static let origin = "https://hongguoduanju.com"
    public static let referer = origin + "/"
    public static func detailURL(_ seriesId: String) -> URL { URL(string: "\(origin)/detail?series_id=\(seriesId)")! }
    public static func playerURL(_ seriesId: String, _ vid: String? = nil) -> URL {
        URL(string: vid.map { "\(origin)/player/\(seriesId)/\($0)" } ?? "\(origin)/player/\(seriesId)")!
    }
}

/// Short-lived in-memory response cache shared by the services, with cancellation-safe single-flight
/// coalescing so concurrent callers for the same uncached key share one upstream request.
public actor TTLCache<Value: Sendable> {
    private final class Inflight {
        let id = UUID()
        let generation: UInt64
        let task: Task<Value, Error>
        var waiters: Set<UUID> = []
        init(generation: UInt64, task: Task<Value, Error>) {
            self.generation = generation
            self.task = task
        }
    }

    private var entries: [String: (Value, Date)] = [:]
    private var order: [String] = []
    private var inflight: [String: Inflight] = [:]
    private var generation: UInt64 = 0
    private let limit: Int
    public init(limit: Int) { self.limit = limit }

    public func get(_ key: String) -> Value? {
        guard let (value, expires) = entries[key], expires > Date() else {
            if entries.removeValue(forKey: key) != nil {
                order.removeAll { $0 == key }
            }
            return nil
        }
        return value
    }

    public func set(_ key: String, _ value: Value, ttl: TimeInterval) {
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = (value, Date().addingTimeInterval(ttl))
        while order.count > limit {
            entries[order.removeFirst()] = nil
        }
    }

    /// Returns a cached value if fresh; otherwise coalesces concurrent callers for `key` onto a
    /// single `loader` task and caches successful results for `ttl` seconds. Cancelling one caller
    /// only cancels the shared `loader` when no other waiters remain.
    public func load(
        _ key: String,
        ttl: TimeInterval,
        loader: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let cached = get(key) { return cached }
        let waiterID = UUID()
        let entry: Inflight
        if let existing = inflight[key] {
            entry = existing
        } else {
            let gen = generation
            let entryID = UUID()
            let task = Task<Value, Error> {
                do {
                    let value = try await loader()
                    self.finish(key: key, entryID: entryID, generation: gen, value: value, ttl: ttl)
                    return value
                } catch {
                    self.finish(key: key, entryID: entryID, generation: gen, value: nil, ttl: ttl)
                    throw error
                }
            }
            let created = Inflight(generation: gen, task: task)
            // Keep lookup id aligned with the cleanup id captured by `task`.
            inflight[key] = created
            inflightIDs[entryID] = created.id
            entry = created
        }
        entry.waiters.insert(waiterID)
        defer { releaseWaiter(waiterID, key: key, entryID: entry.id, cancelIfEmpty: false) }
        return try await withTaskCancellationHandler {
            try await entry.task.value
        } onCancel: {
            Task { await self.releaseWaiter(waiterID, key: key, entryID: entry.id, cancelIfEmpty: true) }
        }
    }

    private var inflightIDs: [UUID: UUID] = [:]

    private func finish(key: String, entryID: UUID, generation: UInt64, value: Value?, ttl: TimeInterval) {
        let targetID = inflightIDs.removeValue(forKey: entryID)
        if let current = inflight[key], current.id == targetID {
            inflight[key] = nil
        }
        if let value, ttl > 0, self.generation == generation {
            set(key, value, ttl: ttl)
        }
    }

    private func releaseWaiter(_ waiterID: UUID, key: String, entryID: UUID, cancelIfEmpty: Bool) {
        guard let current = inflight[key], current.id == entryID else { return }
        current.waiters.remove(waiterID)
        if current.waiters.isEmpty {
            if cancelIfEmpty { current.task.cancel() }
            inflight[key] = nil
        }
    }

    public func remove(_ key: String) {
        generation &+= 1
        inflight[key] = nil
        if entries.removeValue(forKey: key) != nil {
            order.removeAll { $0 == key }
        }
    }

    func clear() {
        generation &+= 1
        inflight.removeAll()
        inflightIDs.removeAll()
        entries.removeAll()
        order.removeAll()
    }
}

/// Shared single-retry policy for idempotent read requests (matching `AccountDataAccess.get`):
/// retries once after 250 ms only on transient network/timeout drops, never on HTTP errors,
/// business rejections, invalid responses, or cancellation.
enum TransientReadRetry {
    static let defaultDelayNanoseconds: UInt64 = 250_000_000

    static func shouldRetry(_ error: Error) -> Bool {
        if let appError = error as? AppSourceError {
            return appError.code == .network || appError.code == .timeout
        }
        if let hongguoError = error as? HongguoError {
            return hongguoError.kind == .network || hongguoError.kind == .timeout
        }
        return false
    }

    static func run<T: Sendable>(
        deadline: Date? = nil,
        delayNanoseconds: UInt64 = TransientReadRetry.defaultDelayNanoseconds,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                if attempt == 0, shouldRetry(error), !Task.isCancelled {
                    let remaining = deadline?.timeIntervalSinceNow ?? .infinity
                    if remaining > 0.5 {
                        if delayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: delayNanoseconds)
                        }
                        continue
                    }
                }
                throw error
            }
        }
        throw HongguoError(.network, "网络请求失败，请稍后重试")
    }
}

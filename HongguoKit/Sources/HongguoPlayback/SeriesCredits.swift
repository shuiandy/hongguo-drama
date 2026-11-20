import Foundation

/// Who holds a series' rights, as the App's own feed and catalogue rows say (their `copyright`
/// field). No lookup of its own: the name is noted whenever such a row is parsed and shown later
/// on the series page. Kept for the series seen most recently, across launches.
public final class SeriesCredits: @unchecked Sendable {
    public static let shared = SeriesCredits()

    private static let key = "seriesCopyrights"
    private static let limit = 600
    private let lock = NSLock()
    private var names: [String: String]
    private var order: [String]
    private var dirty = false

    init() {
        let saved = UserDefaults.standard.array(forKey: Self.key) as? [[String]] ?? []
        order = saved.compactMap { $0.count == 2 ? $0[0] : nil }
        names = Dictionary(saved.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, uniquingKeysWith: { _, new in new })
    }

    public func note(seriesId: String, copyright: String) {
        let name = copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seriesId.isEmpty, !name.isEmpty, name.count <= 60 else { return }
        lock.withLock {
            guard names[seriesId] != name else { return }
            if names[seriesId] == nil { order.append(seriesId) }
            names[seriesId] = name
            while order.count > Self.limit { names[order.removeFirst()] = nil }
            dirty = true
        }
    }

    public func copyright(for seriesId: String) -> String? {
        lock.withLock { names[seriesId] }
    }

    /// Writes what was noted since the last call. Called when a page of rows has been parsed.
    public func save() {
        let rows: [[String]]? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return order.compactMap { id in names[id].map { [id, $0] } }
        }
        if let rows { UserDefaults.standard.set(rows, forKey: Self.key) }
    }
}

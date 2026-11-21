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

/// Short-lived in-memory response cache shared by the services.
actor TTLCache<Value: Sendable> {
    private var entries: [String: (Value, Date)] = [:]
    private var order: [String] = []
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    func get(_ key: String) -> Value? {
        guard let (value, expires) = entries[key], expires > Date() else {
            if entries.removeValue(forKey: key) != nil {
                order.removeAll { $0 == key }
            }
            return nil
        }
        return value
    }

    func set(_ key: String, _ value: Value, ttl: TimeInterval) {
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = (value, Date().addingTimeInterval(ttl))
        while order.count > limit {
            entries[order.removeFirst()] = nil
        }
    }

    func clear() { entries.removeAll(); order.removeAll() }
}

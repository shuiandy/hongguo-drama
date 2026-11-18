import Foundation

/// Watch history entry for one series.
public struct WatchRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String { seriesId }
    public var seriesId: String
    public var title: String
    public var cover: String
    public var total: Int
    /// 1-based episode last played.
    public var episodeIndex: Int
    public var vid: String
    public var position: Double
    public var duration: Double
    public var updatedAt: Date
    /// Highest episode played to the end.
    public var completedEpisode: Int

    public var isFinished: Bool { total > 0 && completedEpisode >= total }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public var theme: Theme = .system
    public var autoNext: Bool = true
    public var rememberSpeed: Bool = true
    public var playbackRate: Float = 1.0
    public var volume: Float = 1.0
    /// Speed step for the S / D shortcuts.
    public var speedStep: Float = 0.25
    /// Hold Space for temporary 2x.
    public var holdToSpeedUp: Bool = true
    public var miniWindowFrame: String?
    public var playerWindowFrame: String?
    public var searchHistory: [String] = []
    /// Preferred video short side in pixels (1080, 720…); nil = automatic (best tier).
    public var preferredQuality: Int?

    public init() {}

    // Tolerates missing keys so adding a setting never invalidates an existing file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme
        autoNext = (try? c.decodeIfPresent(Bool.self, forKey: .autoNext)) ?? d.autoNext
        rememberSpeed = (try? c.decodeIfPresent(Bool.self, forKey: .rememberSpeed)) ?? d.rememberSpeed
        playbackRate = (try? c.decodeIfPresent(Float.self, forKey: .playbackRate)) ?? d.playbackRate
        volume = (try? c.decodeIfPresent(Float.self, forKey: .volume)) ?? d.volume
        speedStep = (try? c.decodeIfPresent(Float.self, forKey: .speedStep)) ?? d.speedStep
        holdToSpeedUp = (try? c.decodeIfPresent(Bool.self, forKey: .holdToSpeedUp)) ?? d.holdToSpeedUp
        miniWindowFrame = try? c.decodeIfPresent(String.self, forKey: .miniWindowFrame)
        playerWindowFrame = try? c.decodeIfPresent(String.self, forKey: .playerWindowFrame)
        searchHistory = (try? c.decodeIfPresent([String].self, forKey: .searchHistory)) ?? d.searchHistory
        preferredQuality = try? c.decodeIfPresent(Int.self, forKey: .preferredQuality)
    }
}

/// JSON persistence in `~/Library/Application Support/HongguoDrama`.
/// Writes are atomic; a damaged file is moved aside instead of crashing the app.
public final class LibraryStore: @unchecked Sendable {
    public static let shared = LibraryStore()

    private struct Snapshot: Codable {
        var version = 1
        var history: [String: WatchRecord] = [:]
        var settings = AppSettings()
    }

    private let url: URL
    private let queue = DispatchQueue(label: "HongguoDrama.LibraryStore")
    private var snapshot: Snapshot

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoDrama", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        url = base.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder.library.decode(Snapshot.self, from: data) {
                snapshot = decoded
            } else {
                let backup = base.appendingPathComponent("library.damaged-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: backup)
                snapshot = Snapshot()
            }
        } else {
            snapshot = Snapshot()
        }
    }

    public var settings: AppSettings {
        get { queue.sync { snapshot.settings } }
        set { queue.sync { snapshot.settings = newValue; persistLocked() } }
    }

    public func history() -> [WatchRecord] {
        queue.sync { snapshot.history.values.sorted { $0.updatedAt > $1.updatedAt } }
    }

    public func record(for seriesId: String) -> WatchRecord? {
        queue.sync { snapshot.history[seriesId] }
    }

    public func savePosition(seriesId: String, title: String, cover: String, total: Int,
                             episodeIndex: Int, vid: String, position: Double, duration: Double, finished: Bool) {
        queue.sync {
            var record = snapshot.history[seriesId] ?? WatchRecord(
                seriesId: seriesId, title: title, cover: cover, total: total, episodeIndex: episodeIndex,
                vid: vid, position: 0, duration: 0, updatedAt: Date(), completedEpisode: 0)
            record.title = title.isEmpty ? record.title : title
            record.cover = cover.isEmpty ? record.cover : cover
            record.total = max(total, record.total)
            record.episodeIndex = episodeIndex
            record.vid = vid
            record.position = position.isFinite ? max(0, position) : 0
            record.duration = duration.isFinite ? max(0, duration) : 0
            record.updatedAt = Date()
            if finished { record.completedEpisode = max(record.completedEpisode, episodeIndex) }
            snapshot.history[seriesId] = record
            persistLocked()
        }
    }

    public func removeHistory(_ seriesId: String) {
        queue.sync { snapshot.history[seriesId] = nil; persistLocked() }
    }

    public func clearHistory() {
        queue.sync { snapshot.history.removeAll(); persistLocked() }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder.library.encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

extension JSONEncoder {
    static var library: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var library: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

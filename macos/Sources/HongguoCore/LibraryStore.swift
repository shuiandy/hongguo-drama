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
    // Update tracking (see WatchHistory.swift). Optional so older files decode unchanged.
    /// Largest episode count seen so far.
    public var knownTotal: Int?
    /// Episode count the user has acknowledged; the difference to `knownTotal` is "new episodes".
    public var acknowledgedTotal: Int?
    public var sequels: [SeriesRef]?
    public var seenSequelIds: [String]?
    public var lastCheckedAt: Date?
    public var lastCheckError: String?

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
    public var muted: Bool = false
    /// Picture mode remembered per series id (Electron keeps it per series too).
    public var pictureModes: [String: PictureMode] = [:]
    public var danmaku = DanmakuSettings()
    /// Download folder; nil means ~/Downloads.
    public var downloadRoot: String?
    /// Naming template, see `DownloadNaming`.
    public var downloadNameFormat: String = DownloadNaming.defaultFormat
    /// 1...10.
    public var maxConcurrentDownloads: Int = 3
    /// Delete a downloaded episode's file once it has been watched to the end.
    public var autoDeleteWatched: Bool = false
    /// Prepare the next episode while the current one plays.
    public var cacheNextEpisode: Bool = true
    /// Check watched series for new episodes and sequels.
    public var watchUpdatesEnabled: Bool = true
    public var watchSequelsEnabled: Bool = true

    public init() {}

    public func pictureMode(for seriesId: String) -> PictureMode { pictureModes[seriesId] ?? .fit }

    public var downloadConfiguration: DownloadConfiguration {
        DownloadConfiguration(root: downloadRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
                                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
                              nameFormat: downloadNameFormat, maxConcurrent: maxConcurrentDownloads)
    }

    /// Clamps values a hand-edited or older file could carry out of range.
    public func normalized() -> AppSettings {
        var copy = self
        copy.playbackRate = PlaybackRate.clamp(playbackRate)
        copy.volume = VolumeState.clamp(volume)
        if !PlaybackRate.speedSteps.contains(speedStep) { copy.speedStep = 0.25 }
        copy.maxConcurrentDownloads = min(10, max(1, maxConcurrentDownloads))
        copy.danmaku = danmaku.normalized()
        if copy.downloadNameFormat.trimmingCharacters(in: .whitespaces).isEmpty { copy.downloadNameFormat = DownloadNaming.defaultFormat }
        copy.searchHistory = Array(searchHistory.prefix(20))
        return copy
    }

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
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? d.muted
        pictureModes = (try? c.decodeIfPresent([String: PictureMode].self, forKey: .pictureModes)) ?? d.pictureModes
        danmaku = (try? c.decodeIfPresent(DanmakuSettings.self, forKey: .danmaku)) ?? d.danmaku
        downloadRoot = try? c.decodeIfPresent(String.self, forKey: .downloadRoot)
        downloadNameFormat = (try? c.decodeIfPresent(String.self, forKey: .downloadNameFormat)) ?? d.downloadNameFormat
        maxConcurrentDownloads = (try? c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads)) ?? d.maxConcurrentDownloads
        autoDeleteWatched = (try? c.decodeIfPresent(Bool.self, forKey: .autoDeleteWatched)) ?? d.autoDeleteWatched
        cacheNextEpisode = (try? c.decodeIfPresent(Bool.self, forKey: .cacheNextEpisode)) ?? d.cacheNextEpisode
        watchUpdatesEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .watchUpdatesEnabled)) ?? d.watchUpdatesEnabled
        watchSequelsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .watchSequelsEnabled)) ?? d.watchSequelsEnabled
        preferredQuality = try? c.decodeIfPresent(Int.self, forKey: .preferredQuality)
        self = normalized()
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

    /// Applies a change to one record (update checks, acknowledging new episodes or sequels).
    @discardableResult
    public func updateRecord(_ seriesId: String, _ transform: (WatchRecord) -> WatchRecord) -> WatchRecord? {
        queue.sync {
            guard let record = snapshot.history[seriesId] else { return nil }
            let next = transform(record)
            snapshot.history[seriesId] = next
            persistLocked()
            return next
        }
    }

    /// Where "continue watching" should start for a series.
    public func resumePoint(for seriesId: String, episodeCount: Int) -> ResumePoint {
        ResumePoint.from(record(for: seriesId), episodeCount: episodeCount)
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

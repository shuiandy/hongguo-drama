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
    /// Preferred video short side in pixels (1080, 720…); nil = automatic (best tier).
    public var preferredQuality: Int?
    /// 西饭/河马 (on unless false) and ReelShort/DramaBox (off unless true); Hongguo is always on.
    public var builtinSources: [String: Bool] = [:]
    /// Apple CMS (`/api.php/provide/vod/`) endpoints added by the user.
    public var customSources: [CustomSourceConfig] = []

    // Settings window (2026-11 redesign).
    /// Page shown when the main window opens: "last", "discover", "history", "library" or "downloads".
    public var startPage: String = "last"
    /// Sidebar page open when the app last quit (`SidebarItem.persistKey`), for startPage "last".
    public var lastPage: String?
    /// Playback cache cap in GB; the oldest decrypted episodes are removed beyond it. 0 = no cap.
    public var playbackCacheLimitGB: Int = 5
    /// Picture mode for series that have none remembered.
    public var defaultPictureMode: PictureMode = .fit
    /// Volume (percent) applied each time the player opens; nil keeps the last volume.
    public var startVolume: Int?
    /// Also search the enabled other sources from the search page.
    public var searchOtherSources: Bool = true
    /// Hours between new-episode checks for unfinished series (1...48).
    public var watchCheckHours: Int = 6
    /// Post a macOS notification when a check finds new episodes or sequels.
    public var watchNotifications: Bool = false
    /// Check for a new app version at launch (manual checks always work).
    public var checkUpdatesAtLaunch: Bool = true
    /// Export danmaku and episode comments next to the videos when a series finishes downloading.
    public var autoExportText: Bool = false
    /// Merge the signed-in account's cloud watch history into 观看记录.
    public var cloudHistorySync: Bool = true

    public static let startPages = ["last", "discover", "history", "library", "downloads"]
    public static let cacheLimits = [2, 5, 10, 20, 0]
    public static let watchCheckChoices = [1, 3, 6, 12, 24]
    public static let startVolumes = [10, 25, 50, 75, 100]

    public init() {}

    /// Sources shown in the switcher, in order.
    public var mediaSources: [MediaSources.Entry] { MediaSources.enabled(builtinSources, custom: customSources) }

    /// Turns a built-in source on or off (`setBuiltinSourceEnabled`). Hongguo cannot be turned off.
    public mutating func setBuiltinSource(_ id: String, enabled: Bool) throws {
        if id == "hongguo" { throw HongguoError(.input, "红果来源固定开启，不能关闭") }
        guard ["xifan", "hema", "reelshort", "dramabox"].contains(id) else { throw HongguoError(.input, "来源开关无效") }
        builtinSources[id] = enabled
    }

    /// Adds or replaces a custom source after validation; returns the stored entry.
    @discardableResult
    public mutating func saveCustomSource(_ draft: CustomSourceConfig) throws -> CustomSourceConfig {
        var source = try CustomSource.validate(draft)
        if let index = customSources.firstIndex(where: { $0.id == source.id }) { customSources[index] = source }
        else {
            if source.id.isEmpty { source.id = UUID().uuidString.lowercased() }
            customSources.append(source)
        }
        return source
    }

    public mutating func removeCustomSource(id: String) throws {
        guard customSources.contains(where: { $0.id == id.lowercased() }) else { throw HongguoError(.input, "播放源不存在") }
        customSources.removeAll { $0.id == id.lowercased() }
    }

    public func pictureMode(for seriesId: String) -> PictureMode { pictureModes[seriesId] ?? defaultPictureMode }

    public var downloadConfiguration: DownloadConfiguration {
        DownloadConfiguration(root: downloadRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
                                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
                              nameFormat: downloadNameFormat, maxConcurrent: maxConcurrentDownloads,
                              preferredQuality: preferredQuality)
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
        if !Self.startPages.contains(startPage) { copy.startPage = "last" }
        copy.playbackCacheLimitGB = min(200, max(0, playbackCacheLimitGB))
        copy.startVolume = startVolume.map { min(100, max(0, $0)) }
        copy.watchCheckHours = min(48, max(1, watchCheckHours))
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
        builtinSources = (try? c.decodeIfPresent([String: Bool].self, forKey: .builtinSources)) ?? d.builtinSources
        // An entry that no longer validates is dropped instead of failing the whole file.
        customSources = ((try? c.decodeIfPresent([Lenient<CustomSourceConfig>].self, forKey: .customSources)) ?? []).compactMap { entry in
            entry.value.flatMap { try? CustomSource.validate($0) }.flatMap { $0.id.isEmpty ? nil : $0 }
        }
        startPage = (try? c.decodeIfPresent(String.self, forKey: .startPage)) ?? d.startPage
        lastPage = try? c.decodeIfPresent(String.self, forKey: .lastPage)
        playbackCacheLimitGB = (try? c.decodeIfPresent(Int.self, forKey: .playbackCacheLimitGB)) ?? d.playbackCacheLimitGB
        defaultPictureMode = (try? c.decodeIfPresent(PictureMode.self, forKey: .defaultPictureMode)) ?? d.defaultPictureMode
        startVolume = try? c.decodeIfPresent(Int.self, forKey: .startVolume)
        searchOtherSources = (try? c.decodeIfPresent(Bool.self, forKey: .searchOtherSources)) ?? d.searchOtherSources
        watchCheckHours = (try? c.decodeIfPresent(Int.self, forKey: .watchCheckHours)) ?? d.watchCheckHours
        watchNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .watchNotifications)) ?? d.watchNotifications
        checkUpdatesAtLaunch = (try? c.decodeIfPresent(Bool.self, forKey: .checkUpdatesAtLaunch)) ?? d.checkUpdatesAtLaunch
        autoExportText = (try? c.decodeIfPresent(Bool.self, forKey: .autoExportText)) ?? d.autoExportText
        cloudHistorySync = (try? c.decodeIfPresent(Bool.self, forKey: .cloudHistorySync)) ?? d.cloudHistorySync
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

    /// Merges imported records (from the Electron app). A record already here wins when it is newer.
    @discardableResult
    public func importRecords(_ records: [WatchRecord]) -> Int {
        queue.sync {
            var count = 0
            for record in records {
                if let existing = snapshot.history[record.seriesId], existing.updatedAt >= record.updatedAt { continue }
                snapshot.history[record.seriesId] = record
                count += 1
            }
            if count > 0 { persistLocked() }
            return count
        }
    }

    /// Merges the account's cloud watch history (read only upstream). For each series the newer
    /// side wins by last-watched time; an older cloud row only fills an empty title, cover or total.
    /// Returns how many local records were added or moved forward.
    @discardableResult
    public func mergeCloudHistory(_ items: [AccountHistoryItem]) -> Int {
        queue.sync {
            var count = 0
            for item in items {
                if var existing = snapshot.history[item.seriesId] {
                    if existing.updatedAt >= item.updatedAt {
                        var filled = existing
                        if filled.title.isEmpty || filled.title.hasPrefix("剧集 ") { filled.title = item.seriesTitle }
                        if filled.cover.isEmpty { filled.cover = item.cover }
                        filled.total = max(filled.total, item.total)
                        if filled != existing { snapshot.history[item.seriesId] = filled }
                        continue
                    }
                    if !item.seriesTitle.isEmpty && !item.seriesTitle.hasPrefix("剧集 ") { existing.title = item.seriesTitle }
                    if !item.cover.isEmpty { existing.cover = item.cover }
                    existing.total = max(existing.total, item.total)
                    if item.episodeIndex > 0 {
                        existing.episodeIndex = item.episodeIndex
                        existing.vid = item.episodeId
                        existing.position = item.position
                        existing.duration = item.duration
                    }
                    existing.updatedAt = item.updatedAt
                    snapshot.history[item.seriesId] = existing
                } else {
                    // Without an episode number the position cannot be placed: start that series at episode 1.
                    let known = item.episodeIndex > 0
                    snapshot.history[item.seriesId] = WatchRecord(
                        seriesId: item.seriesId, title: item.seriesTitle, cover: item.cover, total: item.total,
                        episodeIndex: known ? item.episodeIndex : 1, vid: known ? item.episodeId : "",
                        position: known ? item.position : 0, duration: known ? item.duration : 0,
                        updatedAt: item.updatedAt, completedEpisode: known ? max(0, item.episodeIndex - 1) : 0)
                }
                count += 1
            }
            persistLocked()
            return count
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

/// Decodes one array element without failing the whole array.
struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

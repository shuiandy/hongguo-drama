import Foundation

/// One-time import of the Electron app's data (`~/Library/Application Support/红果短剧/data.json`):
/// watch progress, opened series, settings that still apply, and finished downloads. The source
/// file is only read, never changed. Secrets such as the proxy password are not imported.
public struct ElectronImport: Sendable {
    public struct Result: Equatable, Sendable {
        public var records: [WatchRecord] = []
        public var series: [LibrarySeries] = []
        public var downloads: [DownloadTask] = []
        public var settings: AppSettings?
        /// Values that were present but unusable, for a short note to the user.
        public var skipped = 0
    }

    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("红果短剧/data.json")
    }

    public static func exists(at file: URL = defaultFile) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    public static func read(_ file: URL = defaultFile, base: AppSettings = AppSettings()) throws -> Result {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw HongguoError(.input, "无法读取旧版数据文件") }
        guard data.count <= 64 * 1024 * 1024, let json = try? JSONValue.parse(data), json.object != nil else {
            throw HongguoError(.format, "旧版数据文件格式不正确，未导入")
        }
        return parse(json, base: base)
    }

    static func date(_ value: JSONValue) -> Date? {
        guard let ms = value.number, ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static func int(_ value: JSONValue) -> Int? {
        guard let n = value.number, n.isFinite, n >= 0, n < 1e9 else { return nil }
        return Int(n)
    }

    public static func parse(_ json: JSONValue, base: AppSettings = AppSettings()) -> Result {
        var result = Result()
        // Series registry: titles, covers and episode lists by id.
        var registry: [String: JSONValue] = [:]
        for entry in json["series"].array ?? [] {
            guard let id = entry["series_id"].idString, id.matchesDigits(min: 6, max: 30) else { continue }
            registry[id] = entry
        }
        for (id, entry) in registry where entry["forgotten"].bool != true {
            let title = (entry["series_title"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { result.skipped += 1; continue }
            let cover = entry["cover"].string ?? ""
            let episodes = max(int(entry["total"]) ?? 0, entry["episodes"].array?.count ?? 0)
            let at = date(entry["updatedAt"]) ?? Date(timeIntervalSince1970: 0)
            result.series.append(LibrarySeries(seriesId: id, title: title, cover: URLGuard.isPublicURL(cover) ? cover : "",
                                               episodeCount: episodes, favorite: false, likedEpisodeIds: [], publishedAt: nil,
                                               addedAt: at, lastOpenedAt: at, favoritedAt: nil))
        }
        // Playback map: series_id -> { vid_index, currentTime, updatedAt, completedEpisode, ... }.
        for (id, record) in json["playback"].object ?? [:] {
            guard id.matchesDigits(min: 6, max: 30), let index = int(record["vid_index"]), index >= 1,
                  let updated = date(record["updatedAt"]) else { result.skipped += 1; continue }
            let entry = registry[id]
            let episodes = entry?["episodes"].array ?? []
            let vid = episodes.first { int($0["vid_index"]) == index }?["vid"].idString ?? ""
            let total = max(int(record["knownTotal"]) ?? 0, int(entry?["total"] ?? .null) ?? 0, episodes.count)
            let sequels = (record["sequels"].array ?? []).compactMap { item -> SeriesRef? in
                guard let sid = item["series_id"].idString, let title = item["series_title"].string else { return nil }
                return SeriesRef(seriesId: sid, title: title)
            }
            let position = record["currentTime"].number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            result.records.append(WatchRecord(
                seriesId: id, title: entry?["series_title"].string ?? "", cover: entry?["cover"].string ?? "", total: total,
                episodeIndex: index, vid: vid, position: position, duration: 0, updatedAt: updated,
                completedEpisode: int(record["completedEpisode"]) ?? 0, knownTotal: int(record["knownTotal"]),
                acknowledgedTotal: int(record["acknowledgedTotal"]), sequels: sequels.isEmpty ? nil : sequels,
                seenSequelIds: record["seenSequelIds"].array?.compactMap(\.idString), lastCheckedAt: date(record["lastCheckedAt"]),
                lastCheckError: nil))
        }
        // Finished downloads with a known episode.
        for task in json["tasks"].array ?? [] {
            let info = task["hongguoInfo"]
            guard task["status"].string == "completed", let path = task["savePath"].string, path.hasPrefix("/"),
                  let vid = info["vid"].idString, vid.matchesDigits(min: 1, max: 30),
                  let sid = info["series_id"].idString, sid.matchesDigits(min: 6, max: 30),
                  let index = int(info["vid_index"]), index >= 1 else { continue }
            let created = date(task["startTime"]) ?? Date(timeIntervalSince1970: 0)
            result.downloads.append(DownloadTask(
                id: UUID().uuidString, seriesId: sid, seriesTitle: info["series_title"].string ?? "", vid: vid,
                episodeIndex: index, episodeTitle: info["ep_title"].string ?? "", cover: task["videoInfo"]["cover"].string ?? "",
                status: .completed, phase: nil, receivedBytes: 0, totalBytes: 0, savePath: path, error: nil,
                createdAt: created, finishedAt: date(task["endTime"]) ?? created, retryCount: 0, retryAt: nil, validator: nil))
        }
        // Settings that have a native counterpart.
        let saved = json["settings"]
        if saved.object != nil {
            var settings = base
            if let root = saved["root"].string, root.hasPrefix("/") { settings.downloadRoot = root }
            if let format = saved["name_format"].string, !format.trimmingCharacters(in: .whitespaces).isEmpty { settings.downloadNameFormat = format }
            if let max = int(saved["max_concurrent"]) { settings.maxConcurrentDownloads = max }
            if let value = saved["auto_delete_watched"].bool { settings.autoDeleteWatched = value }
            if let value = saved["cache_next_episode"].bool { settings.cacheNextEpisode = value }
            if let value = saved["watch_updates_enabled"].bool { settings.watchUpdatesEnabled = value }
            if let value = saved["watch_sequels_enabled"].bool { settings.watchSequelsEnabled = value }
            result.settings = settings.normalized()
        }
        result.records.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    /// Applies an import. Existing native data wins where it is newer; returns counts.
    @discardableResult
    public static func apply(_ result: Result, store: LibraryStore = .shared, library: SeriesLibrary = .shared,
                             downloads: DownloadManager? = nil, applySettings: Bool = true) async throws -> (records: Int, series: Int, downloads: Int) {
        let records = store.importRecords(result.records)
        var seriesCount = 0
        for item in result.series where library.series(item.seriesId) == nil {
            try library.recordOpened(seriesId: item.seriesId, title: item.title, cover: item.cover,
                                     episodeCount: item.episodeCount, now: item.lastOpenedAt)
            seriesCount += 1
        }
        var downloadCount = 0
        if let downloads { downloadCount = try await downloads.importCompleted(result.downloads) }
        if applySettings, let settings = result.settings { store.settings = settings }
        return (records, seriesCount, downloadCount)
    }
}

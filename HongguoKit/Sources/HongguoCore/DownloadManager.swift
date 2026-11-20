import Foundation

public enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    case pending, downloading, paused, failed, completed
}

public enum DownloadPhase: String, Codable, Sendable {
    case resolving, transferring, decrypting, converting
}

/// One episode download. Persisted in `downloads.json`.
public struct DownloadTask: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var seriesId: String
    public var seriesTitle: String
    public var vid: String
    public var episodeIndex: Int
    public var episodeTitle: String
    public var cover: String
    public var status: DownloadStatus
    public var phase: DownloadPhase?
    public var receivedBytes: Int64
    /// -1 or 0 while unknown.
    public var totalBytes: Int64
    /// Final file. The partial download sits next to it as `<savePath>.part`.
    public var savePath: String
    public var error: String?
    public var createdAt: Date
    public var finishedAt: Date?
    public var retryCount: Int
    public var retryAt: Date?
    /// ETag / Last-Modified of the partial file, for `If-Range` on resume.
    public var validator: String?

    public var title: String { "《\(seriesTitle)》第\(String(format: "%03d", episodeIndex))集" }
    public var progress: Double {
        if status == .completed { return 1 }
        return totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
    }
    public var fileURL: URL { URL(fileURLWithPath: savePath) }
    public var partialURL: URL { URL(fileURLWithPath: savePath + ".part") }
    public var isActive: Bool { status == .pending || status == .downloading }
}

public struct DownloadConfiguration: Sendable, Equatable {
    public var root: URL
    public var nameFormat: String
    /// 1...10, default 3 (as in Electron).
    public var maxConcurrent: Int
    /// Minimum gap between two play-URL lookups; the App source refuses bursts.
    public var lookupSpacing: Duration
    /// Automatic retry delays for transient network and CDN failures.
    public var retryDelays: [Duration]
    /// Preferred video short side (1080, 720…), shared with the player; nil picks the best tier.
    public var preferredQuality: Int?

    public init(root: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
                nameFormat: String = DownloadNaming.defaultFormat, maxConcurrent: Int = 3,
                lookupSpacing: Duration = .seconds(1), retryDelays: [Duration] = [.seconds(10), .seconds(30), .seconds(60)],
                preferredQuality: Int? = nil) {
        self.root = root
        self.preferredQuality = preferredQuality
        self.nameFormat = nameFormat
        self.maxConcurrent = min(10, max(1, maxConcurrent))
        self.lookupSpacing = lookupSpacing
        self.retryDelays = retryDelays
    }
}

/// Resolves a playable source for one episode. `SeriesService` conforms.
public protocol PlayInfoResolving: Sendable {
    func playInfo(vid: String, seriesId: String?, force: Bool) async throws -> PlayInfo
}

extension SeriesService: PlayInfoResolving {}

public struct DownloadQueueStatus: Sendable, Equatable {
    public var downloading = 0
    public var pending = 0
    public var paused = 0
    public var failed = 0
    public var completed = 0
    public var maxConcurrent = 3
}

/// Download queue with a concurrency cap, pause/resume with HTTP range continuation, progress
/// reporting, automatic retry for transient failures, and decryption of CENC sources before the
/// file is published. Behaviour follows the Electron queue in main.js (`enqueueEpisodes`,
/// `pumpQueue`, `executeHongguoDownload`); range resume is new (Electron restarts from zero).
public actor DownloadManager {
    private var tasks: [DownloadTask]
    private var configuration: DownloadConfiguration
    private let store: JSONFileStore<[DownloadTask]>?
    private let resolver: PlayInfoResolving
    private let transfer: MediaTransferring
    private let decrypt: @Sendable (Data, [UInt8]) throws -> Data
    private var running: [String: Task<Void, Never>] = [:]
    private var retryTimers: [String: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[DownloadTask]>.Continuation] = [:]
    private var nextLookup = ContinuousClock.now
    private var lastPersist = Date.distantPast

    public init(configuration: DownloadConfiguration = DownloadConfiguration(),
                store: JSONFileStore<[DownloadTask]>? = JSONFileStore(directory: JSONFileStore<[DownloadTask]>.defaultDirectory, name: "downloads.json"),
                resolver: PlayInfoResolving = SeriesService(),
                transfer: MediaTransferring = URLSessionMediaTransfer(),
                decrypt: @escaping @Sendable (Data, [UInt8]) throws -> Data = { try CencDecryptor.decryptMP4($0, key: $1) }) {
        self.configuration = configuration
        self.store = store
        self.resolver = resolver
        self.transfer = transfer
        self.decrypt = decrypt
        // Work that was running when the app quit becomes paused; its partial file is kept.
        tasks = (store?.load(default: []) ?? []).map { saved in
            var task = saved
            if task.status == .downloading || task.status == .pending {
                task.status = .paused
                task.phase = nil
                task.error = "应用关闭时任务中断，可继续下载"
            }
            if task.status == .failed, task.retryAt != nil {
                task.retryAt = nil
                task.error = (task.error ?? "下载失败") + "；已取消自动重试，请手动重试"
            }
            return task
        }
    }

    // MARK: Reading

    public func allTasks() -> [DownloadTask] { tasks }

    public func task(_ id: String) -> DownloadTask? { tasks.first { $0.id == id } }

    public func queueStatus() -> DownloadQueueStatus {
        var status = DownloadQueueStatus(maxConcurrent: configuration.maxConcurrent)
        for task in tasks {
            switch task.status {
            case .downloading: status.downloading += 1
            case .pending: status.pending += 1
            case .paused: status.paused += 1
            case .failed: status.failed += 1
            case .completed: status.completed += 1
            }
        }
        return status
    }

    /// The downloaded file for an episode, if it is complete and still on disk. The player can
    /// play it directly instead of fetching the episode again.
    public func localFile(vid: String) -> URL? {
        guard let task = tasks.first(where: { $0.vid == vid && $0.status == .completed }),
              FileManager.default.fileExists(atPath: task.savePath) else { return nil }
        return task.fileURL
    }

    /// Completed and on-disk files of one series, keyed by episode index.
    public func localFiles(seriesId: String) -> [Int: URL] {
        var out: [Int: URL] = [:]
        for task in tasks where task.seriesId == seriesId && task.status == .completed
            && FileManager.default.fileExists(atPath: task.savePath) {
            out[task.episodeIndex] = task.fileURL
        }
        return out
    }

    public func storageUsage() -> Int64 {
        tasks.reduce(0) { sum, task in
            let paths = [task.savePath, task.savePath + ".part"]
            return sum + paths.reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1)[.size]) as? NSNumber)?.int64Value ?? 0) }
        }
    }

    /// Every change to the task list, starting with the current list.
    public func updates() -> AsyncStream<[DownloadTask]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[DownloadTask]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(tasks)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    // MARK: Configuration

    public func setConfiguration(_ value: DownloadConfiguration) {
        configuration = value
        pump()
    }

    // MARK: Enqueue

    /// Adds episodes of one series. Episodes already queued or downloaded (file present) are
    /// skipped; stopped, failed or missing-file ones are queued again. Returns how many were queued.
    @discardableResult
    public func enqueue(seriesId: String, seriesTitle: String, cover: String = "", episodes: [Episode],
                        destination: (@Sendable (Episode) -> URL)? = nil) throws -> Int {
        guard !episodes.isEmpty else { return 0 }
        guard seriesId.matchesDigits(min: 1, max: 30) else { throw HongguoError(.input, "无效的剧集编号") }
        let cleanTitle = DownloadNaming.sanitizeFolderName(seriesTitle).isEmpty ? "红果短剧" : DownloadNaming.sanitizeFolderName(seriesTitle)
        let directory = DownloadNaming.seriesDirectory(root: configuration.root, seriesId: seriesId, seriesTitle: cleanTitle)
        let batchTime = Date()
        var queued = 0
        for episode in episodes {
            guard episode.vid.matchesDigits(min: 1, max: 30), episode.index >= 1 else { throw HongguoError(.input, "无效的分集编号") }
            if let index = tasks.firstIndex(where: { $0.vid == episode.vid }) {
                var task = tasks[index]
                let fileMissing = task.status == .completed && !FileManager.default.fileExists(atPath: task.savePath)
                guard task.status == .paused || task.status == .failed || fileMissing else { continue }
                retryTimers.removeValue(forKey: task.id)?.cancel()
                if let target = destination?(episode).path, target != task.savePath {
                    // 下载到 NAS: an unfinished task moves to the new place and starts over there.
                    try? FileManager.default.removeItem(at: task.partialURL)
                    task.savePath = target
                    task.receivedBytes = 0; task.totalBytes = 0; task.validator = nil; task.finishedAt = nil
                }
                task.status = .pending
                task.error = nil
                task.retryAt = nil
                task.retryCount = 0
                if fileMissing { task.receivedBytes = 0; task.totalBytes = 0; task.validator = nil; task.finishedAt = nil }
                tasks[index] = task
                queued += 1
                continue
            }
            var filename = DownloadNaming.episodeFilename(format: configuration.nameFormat, seriesTitle: cleanTitle,
                                                          index: episode.index, episodeTitle: episode.title)
            var path = destination?(episode).path ?? directory.appendingPathComponent(filename).path
            if destination == nil, tasks.contains(where: { $0.savePath == path && $0.vid != episode.vid }) {
                filename = DownloadNaming.conflictSuffixed(filename, vid: episode.vid)
                path = directory.appendingPathComponent(filename).path
            }
            let task = DownloadTask(id: UUID().uuidString, seriesId: seriesId, seriesTitle: cleanTitle, vid: episode.vid,
                                    episodeIndex: episode.index, episodeTitle: episode.title, cover: cover,
                                    status: .pending, phase: nil, receivedBytes: 0, totalBytes: 0, savePath: path,
                                    error: nil, createdAt: batchTime, finishedAt: nil, retryCount: 0, retryAt: nil, validator: nil)
            tasks.insert(task, at: 0)
            queued += 1
        }
        try persist(force: true)
        changed()
        pump()
        return queued
    }

    /// Adds finished downloads made elsewhere (the Electron app) so the files show up and play
    /// offline. Only files that exist are taken; episodes already known are skipped.
    @discardableResult
    public func importCompleted(_ imported: [DownloadTask]) throws -> Int {
        var count = 0
        for var task in imported where task.status == .completed && FileManager.default.fileExists(atPath: task.savePath) {
            guard !tasks.contains(where: { $0.vid == task.vid || $0.savePath == task.savePath }) else { continue }
            let size = Self.fileSize(task.fileURL)
            task.receivedBytes = size
            task.totalBytes = size
            tasks.append(task)
            count += 1
        }
        if count > 0 {
            try persist(force: true)
            changed()
        }
        return count
    }

    // MARK: Storage

    public struct SeriesUsage: Equatable, Sendable, Identifiable {
        public var id: String { seriesId }
        public var seriesId: String
        public var seriesTitle: String
        public var bytes: Int64
        public var files: Int
    }

    /// Files that belong to one episode: the video, its partial download and exported text.
    static func fileFamily(_ task: DownloadTask) -> [URL] {
        let video = task.fileURL
        var family = [video, task.partialURL]
        if let danmaku = TextExport.sidecar(video, "danmaku") { family.append(danmaku) }
        if let comments = TextExport.sidecar(video, "comments") { family.append(comments) }
        return family
    }

    /// Disk use per series (videos, partial files and exported text), largest first.
    public func seriesUsage() -> [SeriesUsage] {
        var bySeries: [String: SeriesUsage] = [:]
        for task in tasks {
            var usage = bySeries[task.seriesId] ?? SeriesUsage(seriesId: task.seriesId, seriesTitle: task.seriesTitle, bytes: 0, files: 0)
            for file in Self.fileFamily(task) where Self.isRegularFile(file) {
                usage.bytes += Self.fileSize(file)
                usage.files += 1
            }
            bySeries[task.seriesId] = usage
        }
        return bySeries.values.filter { $0.files > 0 }.sorted { ($0.bytes, $0.seriesId) > ($1.bytes, $1.seriesId) }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    /// Deletes every downloaded file of a series and its task records. Refused while one of its
    /// episodes is downloading. Records whose files could not be deleted are kept.
    @discardableResult
    public func deleteSeries(_ seriesId: String) throws -> (count: Int, freed: Int64) {
        let owned = tasks.filter { $0.seriesId == seriesId }
        guard !owned.contains(where: { running[$0.id] != nil || $0.status == .downloading }) else {
            throw HongguoError(.input, "该剧正在下载，暂不删除")
        }
        var freed: Int64 = 0, count = 0, failed = 0
        var removed = Set<String>()
        for task in owned {
            retryTimers.removeValue(forKey: task.id)?.cancel()
            var ok = true
            for file in Self.fileFamily(task) where FileManager.default.fileExists(atPath: file.path) {
                let size = Self.fileSize(file)
                do { try FileManager.default.removeItem(at: file); freed += size; if file == task.fileURL { count += 1 } }
                catch { ok = false }
            }
            if ok { removed.insert(task.id) } else { failed += 1 }
        }
        tasks.removeAll { removed.contains($0.id) }
        // Drop the series folder when nothing else is left in it.
        for directory in Set(owned.map { $0.fileURL.deletingLastPathComponent() }) {
            if let left = try? FileManager.default.contentsOfDirectory(atPath: directory.path), left.allSatisfy({ $0 == ".DS_Store" }) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try persist(force: true)
        changed()
        if failed > 0 { throw HongguoError(.input, "部分文件删除失败，对应记录已保留") }
        return (count, freed)
    }

    /// Deletes the downloads of every series that is not downloading right now.
    @discardableResult
    public func deleteAllDownloaded() -> (count: Int, freed: Int64, skipped: Int, failed: Int) {
        var count = 0, freed: Int64 = 0, skipped = 0, failed = 0
        for seriesId in Set(tasks.map(\.seriesId)) {
            do {
                let result = try deleteSeries(seriesId)
                count += result.count
                freed += result.freed
            } catch let error as HongguoError where error.message == "该剧正在下载，暂不删除" {
                skipped += 1
            } catch { failed += 1 }
        }
        return (count, freed, skipped, failed)
    }

    /// Finds episode files already in a series folder that have no task (downloads from another
    /// session, or a cleared list) and adds them as completed. Port of `rescanDownloadsFromDisk`.
    @discardableResult
    public func rescan(seriesId: String, seriesTitle: String, cover: String = "", episodes: [Episode]) throws -> Int {
        let cleanTitle = DownloadNaming.sanitizeFolderName(seriesTitle).isEmpty ? "红果短剧" : DownloadNaming.sanitizeFolderName(seriesTitle)
        let directory = DownloadNaming.seriesDirectory(root: configuration.root, seriesId: seriesId, seriesTitle: cleanTitle)
        let formats = [configuration.nameFormat, "剧名 集数", "剧名 集数 标题", "剧名"]
        var added = 0
        for episode in episodes where episode.index >= 1 && episode.vid.matchesDigits(min: 1, max: 30) {
            guard !tasks.contains(where: { $0.vid == episode.vid || ($0.seriesId == seriesId && $0.episodeIndex == episode.index) }) else { continue }
            var seen = Set<String>()
            for format in formats {
                let name = DownloadNaming.episodeFilename(format: format, seriesTitle: cleanTitle, index: episode.index, episodeTitle: episode.title)
                guard seen.insert(name).inserted else { continue }
                let file = directory.appendingPathComponent(name)
                // A tiny or non-regular file is not a finished episode.
                guard Self.isRegularFile(file), Self.fileSize(file) > 100 * 1024,
                      !tasks.contains(where: { $0.savePath == file.path }) else { continue }
                let size = Self.fileSize(file)
                tasks.append(DownloadTask(id: UUID().uuidString, seriesId: seriesId, seriesTitle: cleanTitle, vid: episode.vid,
                                          episodeIndex: episode.index, episodeTitle: episode.title, cover: cover, status: .completed,
                                          phase: nil, receivedBytes: size, totalBytes: size, savePath: file.path, error: nil,
                                          createdAt: Date(), finishedAt: Date(), retryCount: 0, retryAt: nil, validator: nil))
                added += 1
                break
            }
        }
        if added > 0 {
            try persist(force: true)
            changed()
        }
        return added
    }

    // MARK: Control

    /// Pauses a pending, running or retry-scheduled task. The partial file stays for resume.
    public func pause(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        guard task.isActive || (task.status == .failed && task.retryAt != nil) else { return }
        tasks[index].status = .paused
        tasks[index].phase = nil
        tasks[index].retryAt = nil
        tasks[index].error = "已手动暂停"
        retryTimers.removeValue(forKey: id)?.cancel()
        running[id]?.cancel()
        try? persist(force: true)
        changed()
    }

    @discardableResult
    public func pauseAll() -> Int {
        let ids = tasks.filter { $0.isActive || ($0.status == .failed && $0.retryAt != nil) }.map(\.id)
        for id in ids { pause(id) }
        return ids.count
    }

    /// Continues a paused or failed task from where its partial file ends.
    public func resume(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        let fileMissing = task.status == .completed && !FileManager.default.fileExists(atPath: task.savePath)
        guard task.status == .paused || task.status == .failed || fileMissing else { return }
        retryTimers.removeValue(forKey: id)?.cancel()
        tasks[index].status = .pending
        tasks[index].error = nil
        tasks[index].retryAt = nil
        tasks[index].retryCount = 0
        if fileMissing { tasks[index].receivedBytes = 0; tasks[index].totalBytes = 0; tasks[index].validator = nil }
        try? persist(force: true)
        changed()
        pump()
    }

    @discardableResult
    public func resumeAll() -> Int {
        let ids = tasks.filter { $0.status == .paused || $0.status == .failed }.map(\.id)
        for id in ids { resume(id) }
        return ids.count
    }

    /// Starts over from zero, discarding the partial file.
    public func restart(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status != .downloading else { return }
        try? FileManager.default.removeItem(at: tasks[index].partialURL)
        tasks[index].receivedBytes = 0
        tasks[index].totalBytes = 0
        tasks[index].validator = nil
        if tasks[index].status == .completed { tasks[index].status = .failed }
        resume(id)
    }

    /// Removes tasks. The partial file always goes; the finished video only with `deleteFile`.
    public func remove(_ ids: [String], deleteFile: Bool = false) throws {
        for id in ids {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { continue }
            running.removeValue(forKey: id)?.cancel()
            retryTimers.removeValue(forKey: id)?.cancel()
            let task = tasks.remove(at: index)
            try? FileManager.default.removeItem(at: task.partialURL)
            if deleteFile { try? FileManager.default.removeItem(at: task.fileURL) }
        }
        try persist(force: true)
        changed()
        pump()
    }

    /// Deletes the video file of a completed episode (for "delete after watching") but keeps
    /// the record so the episode can be downloaded again.
    @discardableResult
    public func deleteFile(seriesId: String, episodeIndex: Int) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.seriesId == seriesId && $0.episodeIndex == episodeIndex && $0.status == .completed })
        else { return false }
        do { try FileManager.default.removeItem(at: tasks[index].fileURL) } catch { return false }
        tasks[index].status = .paused
        tasks[index].receivedBytes = 0
        tasks[index].totalBytes = 0
        tasks[index].validator = nil
        tasks[index].error = "视频文件已删除，可重新下载"
        try? persist(force: true)
        changed()
        return true
    }

    // MARK: Scheduling

    private func pump() {
        let free = configuration.maxConcurrent - running.count
        guard free > 0 else { return }
        // Oldest submission first; inside one submission, episodes in order.
        let next = tasks.filter { $0.status == .pending && running[$0.id] == nil }
            .sorted { ($0.createdAt, $0.episodeIndex) < ($1.createdAt, $1.episodeIndex) }
            .prefix(free)
        for task in next {
            update(task.id) { $0.status = .downloading; $0.phase = .resolving; $0.error = nil }
            running[task.id] = Task { await self.run(task.id) }
        }
        if !next.isEmpty { try? persist(force: true); changed() }
    }

    private func waitForLookupSlot() async throws {
        let now = ContinuousClock.now
        let start = max(now, nextLookup)
        nextLookup = start + configuration.lookupSpacing
        if start > now { try await Task.sleep(until: start, clock: .continuous) }
    }

    private func run(_ id: String) async {
        defer {
            running[id] = nil
            pump()
        }
        guard let task = self.task(id) else { return }
        do {
            try await waitForLookupSlot()
            try Task.checkCancellation()
            let finalURL = task.fileURL
            let fm = FileManager.default
            try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Never overwrite a finished file; it is the same episode under the same name.
            if fm.fileExists(atPath: finalURL.path), !fm.fileExists(atPath: task.partialURL.path) {
                complete(id, size: Self.fileSize(finalURL))
                return
            }
            // Same tier rule as the player. A resumed file whose tier changed fails If-Range and restarts.
            let info = try await resolver.playInfo(vid: task.vid, seriesId: task.seriesId,
                                                   force: task.receivedBytes > 0 || task.retryCount > 0)
                .selecting(shortSide: configuration.preferredQuality)
            try Task.checkCancellation()
            update(id) { $0.phase = .transferring }
            changed()
            let result = try await transferWithRestart(id: id, info: info)
            try Task.checkCancellation()
            if info.isByteVC2 {
                // ByteVC2 兼容转换: the helper decrypts and converts to H.264 in one pass.
                update(id) { $0.phase = .converting }
                changed()
                let key = info.contentKey ?? info.spadeA.flatMap(CencDecryptor.deriveKey)
                if info.isEncrypted, key == nil { throw HongguoError(.decrypt, "片源密钥无法解析") }
                let partial = self.task(id)?.partialURL ?? task.partialURL
                let staging = finalURL.appendingPathExtension("converting")
                try await ByteVC2Converter.shared.convert(input: partial, output: staging, key: key)
                try Task.checkCancellation()
                try Self.publish(fileAt: staging, to: finalURL)
                try? fm.removeItem(at: partial)
                complete(id, size: Self.fileSize(finalURL))
            } else if info.isEncrypted {
                update(id) { $0.phase = .decrypting }
                changed()
                guard let key = info.contentKey ?? info.spadeA.flatMap(CencDecryptor.deriveKey) else {
                    throw HongguoError(.decrypt, "片源密钥无法解析")
                }
                let partial = self.task(id)?.partialURL ?? task.partialURL
                let decrypt = self.decrypt
                // Decrypt off the actor; episodes are tens of megabytes.
                let plain = try await Task.detached(priority: .utility) {
                    try decrypt(try Data(contentsOf: partial, options: [.mappedIfSafe]), key)
                }.value
                try Task.checkCancellation()
                try Self.publish(plain, to: finalURL)
                try? fm.removeItem(at: partial)
                complete(id, size: Int64(plain.count))
            } else {
                try Self.publish(fileAt: task.partialURL, to: finalURL)
                complete(id, size: result.totalBytes)
            }
        } catch {
            fail(id, error)
        }
    }

    private func transferWithRestart(id: String, info: PlayInfo) async throws -> MediaTransferResult {
        guard let task = task(id) else { throw CancellationError() }
        var request = MediaTransferRequest(url: info.url, headers: info.httpHeaders, validator: task.validator,
                                           expectedTotal: task.totalBytes > 0 ? task.totalBytes : nil)
        let onResponse: @Sendable (Int64, String?) -> Void = { total, validator in
            Task { await self.recordResponse(id, total: total, validator: validator) }
        }
        let progress: @Sendable (Int64, Int64) -> Void = { received, total in
            Task { await self.report(id, received: received, total: total) }
        }
        do {
            return try await transfer.transfer(request, to: task.partialURL, onResponse: onResponse, progress: progress)
        } catch is MediaTransferRestart {
            try? FileManager.default.removeItem(at: task.partialURL)
            update(id) { $0.receivedBytes = 0; $0.totalBytes = 0; $0.validator = nil }
            request.validator = nil
            request.expectedTotal = nil
            return try await transfer.transfer(request, to: task.partialURL, onResponse: onResponse, progress: progress)
        }
    }

    private func recordResponse(_ id: String, total: Int64, validator: String?) {
        guard task(id)?.status == .downloading else { return }
        update(id) { $0.totalBytes = total; $0.validator = validator }
        try? persist(force: true)
    }

    private func report(_ id: String, received: Int64, total: Int64) {
        guard task(id)?.status == .downloading else { return }
        update(id) { $0.receivedBytes = received; if total > 0 { $0.totalBytes = total } }
        try? persist(force: false)
        changed()
    }

    private func complete(_ id: String, size: Int64) {
        update(id) {
            $0.status = .completed
            $0.phase = nil
            $0.error = nil
            $0.receivedBytes = size
            $0.totalBytes = size
            $0.finishedAt = Date()
            $0.retryAt = nil
            $0.validator = nil
        }
        try? persist(force: true)
        changed()
    }

    private func fail(_ id: String, _ error: Error) {
        guard let task = task(id) else { return }
        // pause() already set the final state; a cancelled run must not overwrite it.
        if task.status == .paused { return }
        let message = Self.describe(error)
        if error is CancellationError || (error as? HongguoError)?.kind == .cancelled {
            update(id) { $0.status = .paused; $0.phase = nil; $0.error = "已暂停" }
        } else if Self.isTransient(error), task.retryCount < configuration.retryDelays.count {
            let delay = configuration.retryDelays[task.retryCount]
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            let at = Date().addingTimeInterval(seconds)
            update(id) {
                $0.status = .failed
                $0.phase = nil
                $0.retryCount += 1
                $0.retryAt = at
                $0.error = "\(message) 将在 \(Int(seconds.rounded())) 秒后自动重试（\($0.retryCount)/\(self.configuration.retryDelays.count)）。"
            }
            retryTimers[id] = Task {
                try? await Task.sleep(for: delay)
                self.fireRetry(id, at: at)
            }
        } else {
            update(id) { $0.status = .failed; $0.phase = nil; $0.retryAt = nil; $0.error = message }
        }
        try? persist(force: true)
        changed()
    }

    private func fireRetry(_ id: String, at: Date) {
        retryTimers[id] = nil
        guard let task = task(id), task.status == .failed, task.retryAt == at else { return }
        update(id) { $0.status = .pending; $0.retryAt = nil; $0.error = nil }
        try? persist(force: true)
        changed()
        pump()
    }

    // MARK: Helpers

    private func update(_ id: String, _ body: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        body(&tasks[index])
    }

    private func changed() {
        for continuation in observers.values { continuation.yield(tasks) }
    }

    private func persist(force: Bool) throws {
        guard let store else { return }
        if !force, Date().timeIntervalSince(lastPersist) < 2 { return }
        lastPersist = Date()
        try store.save(tasks)
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Writes next to the target and renames, so a half-written file is never visible as the video.
    static func publish(_ data: Data, to target: URL) throws {
        let staging = target.appendingPathExtension("decrypting")
        try data.write(to: staging, options: [.atomic])
        try publish(fileAt: staging, to: target)
    }

    static func publish(fileAt source: URL, to target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            throw HongguoError(.input, "目标位置已有同名视频，未覆盖，请检查后重试")
        }
        try fm.moveItem(at: source, to: target)
    }

    static func isTransient(_ error: Error) -> Bool {
        if let status = error as? HTTPMediaStatusError { return status.isTransient }
        if let status = error as? HTTPStatusError { return status.status == 408 || status.status >= 500 }
        if let error = error as? HongguoError { return [.timeout, .network].contains(error.kind) }
        return false
    }

    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "已取消" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

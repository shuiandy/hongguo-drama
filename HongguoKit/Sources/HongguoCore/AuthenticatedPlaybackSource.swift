// SPDX-License-Identifier: GPL-3.0-only
// The play source of every app (Mac, iOS, tvOS): the official iOS 7.4.3 client's logic.
// Mirrors official iOS 7.4.3 `BDInstall` + `FQVPlayerApiService` + `FQVShortVideoVideoModelCacheManager`:
// - uses the Keychain-persisted, 6-hour-renewed & activated `PersistentAppDevice` with `x-tt-dt`,
//   and never the website login Cookie: since 2026-11-20 a play request carrying it comes back
//   empty on every path (the account's own requests still use it),
// - caches resolved `PlayInfo` on disk respecting server `expire_time`,
// - targets official iOS 7.4.3 `mGetVideoModel` (`/novel/player/multi_video_model/v1/`),
// - proactively upgrades ByteVC2-only episodes to H.264/HEVC via `CodecFallback` when available,
// - self-heals on empty replies with one BDInstall renewal of the persistent device, nothing else.
// There is no other source: no Android profile, website channel or web page.
import Foundation

/// Disk-backed cache for resolved `PlayInfo` records, mirroring `FQVShortVideoVideoModelCacheManager`.
/// Holds signed URLs and content keys inside the app's Caches directory; never logged.
public final class VideoModelDiskCache: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public let archive: Data
        public let expiresAt: Date
        public let cachedAt: Date
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var loaded = false

    public init(fileURL: URL? = VideoModelDiskCache.defaultFileURL(), maxEntries: Int = 128) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
    }

    private static var isMacTestRunner: Bool { MacTestRunner.isActive }

    public static func defaultFileURL() -> URL? {
        guard !isMacTestRunner else { return nil }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        #if os(macOS)
        // Not sandboxed on the Mac: keep it with the app's other caches.
        let folder = caches.appendingPathComponent("HongguoDrama", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent("video-model-cache.json")
        #else
        return caches.appendingPathComponent("video-model-cache.json")
        #endif
    }

    public func load(vid: String, now: Date = Date()) -> PlayInfo? {
        loadWithExpiry(vid: vid, now: now)?.info
    }

    public func loadWithExpiry(vid: String, now: Date = Date()) -> (info: PlayInfo, expiresAt: Date)? {
        lock.withLock {
            loadLockedIfNeeded()
            guard let entry = entries[vid] else { return nil }
            guard entry.expiresAt > now else {
                entries[vid] = nil
                saveLocked()
                return nil
            }
            guard let info = PlayInfoArchive.decode(entry.archive) else { return nil }
            return (info, entry.expiresAt)
        }
    }

    public func store(vid: String, info: PlayInfo, expiresAt: Date, now: Date = Date()) {
        storeBatch([(vid: vid, info: info, expiresAt: expiresAt)], now: now)
    }

    /// Persists multiple resolved `PlayInfo` entries in a single lock acquisition and atomic write.
    public func storeBatch(_ items: [(vid: String, info: PlayInfo, expiresAt: Date)], now: Date = Date()) {
        let encoded: [(String, Entry)] = items.compactMap { item in
            guard item.expiresAt > now, let archive = PlayInfoArchive.encode(item.info) else { return nil }
            return (item.vid, Entry(archive: archive, expiresAt: item.expiresAt, cachedAt: now))
        }
        guard !encoded.isEmpty else { return }
        lock.withLock {
            loadLockedIfNeeded()
            for (vid, entry) in encoded {
                entries[vid] = entry
            }
            pruneLocked(now: now)
            saveLocked()
        }
    }

    public func remove(vid: String) {
        lock.withLock {
            loadLockedIfNeeded()
            guard entries.removeValue(forKey: vid) != nil else { return }
            saveLocked()
        }
    }

    /// Computes a safe expiration timestamp from a server `expire_time` value (Unix seconds or
    /// relative seconds), leaving a 60-second safety margin and clamping to [120 s, 3600 s].
    public static func computeExpiry(serverExpireTime: Double?, now: Date = Date(), defaultTTL: TimeInterval = 15 * 60) -> Date {
        guard let raw = serverExpireTime, raw.isFinite, raw > 0 else {
            return now.addingTimeInterval(defaultTTL)
        }
        let ttl: TimeInterval
        if raw > 1_000_000_000 {
            ttl = raw - now.timeIntervalSince1970 - 60
        } else {
            ttl = raw - 60
        }
        let clamped = min(max(ttl, 120), 3600)
        return now.addingTimeInterval(clamped)
    }

    private func loadLockedIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        let now = Date()
        entries = decoded.filter { $0.value.expiresAt > now }
    }

    private func pruneLocked(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
        while entries.count > maxEntries,
              let oldest = entries.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
            entries[oldest] = nil
        }
    }

    private func saveLocked() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

public actor AuthenticatedPlaybackSource {
    public static let shared = AuthenticatedPlaybackSource()

    public static let cacheLifetime: TimeInterval = 15 * 60
    private static let maxCachedEntries = 256
    private static let maxBatchSize = 6
    private static let batchCooldownSeconds: TimeInterval = 45

    private struct CachedPlayInfo {
        let info: PlayInfo
        let expiresAt: Date
    }

    private struct PendingFallback {
        let fallbackURL: String
        let videoId: String?
        let duration: Double?
        let minimumPixels: Int
        let requireEncryptionMetadata: Bool
        let expiresAt: Date
    }

    private final class InflightEntry {
        let id = UUID()
        let task: Task<(PlayInfo, Date, String), Error>
        var waiters: Set<UUID> = []
        init(task: Task<(PlayInfo, Date, String), Error>) { self.task = task }
    }

    private let transport: AppTransport
    private let diskCache: VideoModelDiskCache
    private var cached: [String: CachedPlayInfo] = [:]
    private var cacheOrder: [String] = []
    private var pendingFallbacks: [String: PendingFallback] = [:]
    private var vidEpochs: [String: UInt64] = [:]
    private var inflightSingle: [String: InflightEntry] = [:]
    private var inflightBatchTask: Task<Void, Never>?
    private var batchCooldownUntil = Date.distantPast

    public init(http: HTTPClient = .shared, diskCache: VideoModelDiskCache = VideoModelDiskCache()) {
        self.transport = AppTransport(http: http)
        self.diskCache = diskCache
    }

    public func warmUpIdentity() async {
        await PersistentAppDevice.shared.ensureFresh(http: transport.http)
    }

    public func cachedPlayInfo(vid: String) -> PlayInfo? {
        cachedPlayInfoWithMeta(vid: vid)?.info
    }

    public func cachedPlayInfoWithRoute(vid: String) -> (info: PlayInfo, route: String)? {
        cachedPlayInfoWithMeta(vid: vid).map { ($0.info, $0.route) }
    }

    public func cachedPlayInfoWithMeta(vid: String) -> (info: PlayInfo, expiresAt: Date, route: String)? {
        let now = Date()
        if let hit = cached[vid], hit.expiresAt > now {
            return (hit.info, hit.expiresAt, "auth-mem")
        }
        if let diskHit = diskCache.loadWithExpiry(vid: vid, now: now) {
            storeMemory(vid: vid, info: diskHit.info, expiresAt: diskHit.expiresAt)
            return (diskHit.info, diskHit.expiresAt, "auth-disk")
        }
        return nil
    }

    private func bumpVidEpoch(_ vid: String) -> UInt64 {
        let next = (vidEpochs[vid] ?? 0) &+ 1
        vidEpochs[vid] = next
        return next
    }

    public func forget(vid: String) {
        _ = bumpVidEpoch(vid)
        inflightSingle.removeValue(forKey: vid)?.task.cancel()
        cached[vid] = nil
        cacheOrder.removeAll { $0 == vid }
        pendingFallbacks[vid] = nil
        diskCache.remove(vid: vid)
    }

    public func playInfo(vid: String, force: Bool = false) async throws -> PlayInfo {
        try await resolveWithMeta(vid: vid, force: force).info
    }

    public func resolveWithRoute(vid: String, force: Bool = false, allowRecovery: Bool = true) async throws -> (info: PlayInfo, route: String) {
        let resolved = try await resolveWithMeta(vid: vid, force: force, allowRecovery: allowRecovery)
        return (resolved.info, resolved.route)
    }

    public func resolveWithMeta(vid: String, force: Bool = false, allowRecovery: Bool = true) async throws -> (info: PlayInfo, expiresAt: Date, route: String) {
        do {
            return try await resolve(vid: vid, force: force, allowRecovery: allowRecovery)
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
    }

    public func prefetchBatch(vids: [String]) async {
        let epochs = Dictionary(vids.map { ($0, vidEpochs[$0, default: 0]) }, uniquingKeysWith: { first, _ in first })
        while !Task.isCancelled, Date() >= batchCooldownUntil {
            if let (vid, single) = inflightSingle.first {
                _ = await single.task.result
                if inflightSingle[vid] === single { inflightSingle[vid] = nil }
                continue
            }
            if let batch = inflightBatchTask {
                await batch.value
                if inflightBatchTask == batch { inflightBatchTask = nil }
                continue
            }
            let remaining = vids.filter { epochs[$0] == (vidEpochs[$0] ?? 0) }
            guard await runPrefetchBatch(vids: remaining, epochs: epochs) else { return }
        }
    }

    /// Returns true when the foreground preempted the batch and its caller can reconsider the remaining IDs.
    private func runPrefetchBatch(vids: [String], epochs: [String: UInt64]) async -> Bool {
        let now = Date()
        var unique: [String] = []
        var seen: Set<String> = []
        for vid in vids {
            guard vid.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil,
                  seen.insert(vid).inserted else { continue }
            if let hit = cached[vid], hit.expiresAt > now { continue }
            if diskCache.load(vid: vid, now: now) != nil { continue }
            if let fb = pendingFallbacks[vid], fb.expiresAt > now { continue }
            unique.append(vid)
            if unique.count >= Self.maxBatchSize { break }
        }
        guard !unique.isEmpty else { return false }

        let chunk = unique
        let task = Task<Void, Never> {
            guard !Task.isCancelled else { return }
            do {
                let identity = try await PersistentAppDevice.shared.get(transport: self.transport)
                let dToken = await PersistentAppDevice.shared.dTokenHeaders()
                let entries = try await self.requestModels(
                    vids: chunk,
                    channels: [.videoModel],
                    identity: identity,
                    extraHeaders: dToken,
                    deadline: Date().addingTimeInterval(8)
                )
                guard !Task.isCancelled else { return }
                var fallbacksToWarm: [(String, PendingFallback)] = []
                var diskBatch: [(vid: String, info: PlayInfo, expiresAt: Date)] = []
                for vid in chunk {
                    guard let epoch = epochs[vid], (self.vidEpochs[vid] ?? 0) == epoch else { continue }
                    if let cachedItem = self.ingestBatchEntry(entries[vid], vid: vid, epoch: epoch) {
                        diskBatch.append(cachedItem)
                    }
                    if let fb = self.pendingFallbacks[vid], fallbacksToWarm.count < 3 {
                        fallbacksToWarm.append((vid, fb))
                    }
                }
                if !diskBatch.isEmpty {
                    self.diskCache.storeBatch(diskBatch)
                }
                // Eagerly resolve fallback_api for the first 3 upcoming episodes so tapping them
                // hits `auth-mem`/`auth-disk` in 0 ms instead of paying a 2nd RTT.
                for (vid, fb) in fallbacksToWarm {
                    guard !Task.isCancelled, self.inflightSingle.isEmpty else { break }
                    guard self.cached[vid] == nil else { continue }
                    if let resolved = try? await self.resolveFallback(fb, vid: vid, deadline: Date().addingTimeInterval(6)) {
                        guard !Task.isCancelled, let epoch = epochs[vid], (self.vidEpochs[vid] ?? 0) == epoch else { continue }
                        self.pendingFallbacks[vid] = nil
                        self.storeCached(vid: vid, info: resolved.info, expiresAt: fb.expiresAt, expectedEpoch: epoch)
                    }
                }
            } catch let error as AppSourceError where error.code == .emptyResponse {
                if !Task.isCancelled {
                    self.batchCooldownUntil = Date().addingTimeInterval(Self.batchCooldownSeconds)
                }
            } catch {
                // Background batch prefetch is best-effort.
            }
        }
        inflightBatchTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if inflightBatchTask == task { inflightBatchTask = nil }
        return task.isCancelled
    }

    // MARK: - Core Resolution

    private func resolve(vid: String, force: Bool, allowRecovery: Bool) async throws -> (PlayInfo, Date, String) {
        guard vid.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else {
            throw AppSourceError(.input, "分集编号无效")
        }
        if !force, let hit = cachedPlayInfoWithMeta(vid: vid) { return hit }

        let waiterID = UUID()
        let entry: InflightEntry
        if !force, let existing = inflightSingle[vid] {
            entry = existing
        } else {
            inflightBatchTask?.cancel()
            if force {
                forget(vid: vid)
            }
            let epoch = bumpVidEpoch(vid)
            let task = Task<(PlayInfo, Date, String), Error> {
                try await self.resolveSingle(vid: vid, force: force, allowRecovery: allowRecovery, epoch: epoch)
            }
            entry = InflightEntry(task: task)
            inflightSingle[vid] = entry
        }
        entry.waiters.insert(waiterID)
        defer { releaseWaiter(waiterID, vid: vid, entryID: entry.id, cancelIfEmpty: false) }
        return try await withTaskCancellationHandler {
            try await entry.task.value
        } onCancel: {
            Task { await self.releaseWaiter(waiterID, vid: vid, entryID: entry.id, cancelIfEmpty: true) }
        }
    }

    private func releaseWaiter(_ waiterID: UUID, vid: String, entryID: UUID, cancelIfEmpty: Bool) {
        guard let current = inflightSingle[vid], current.id == entryID else { return }
        current.waiters.remove(waiterID)
        if current.waiters.isEmpty {
            if cancelIfEmpty { current.task.cancel() }
            inflightSingle[vid] = nil
        }
    }

    private func resolveSingle(vid: String, force: Bool, allowRecovery: Bool, epoch: UInt64) async throws -> (PlayInfo, Date, String) {
        let deadline = Date().addingTimeInterval(10)
        if !force, let pending = pendingFallbacks.removeValue(forKey: vid),
           pending.expiresAt > Date() {
            if let resolved = try? await resolveFallback(pending, vid: vid, deadline: deadline) {
                storeCached(vid: vid, info: resolved.info, expiresAt: pending.expiresAt, expectedEpoch: epoch)
                return (resolved.info, pending.expiresAt, resolved.upgraded ? "auth-fb-h264" : "auth-fb")
            }
        }

        let startGen = await PersistentAppDevice.shared.currentGeneration()
        var identity = try await PersistentAppDevice.shared.get(transport: transport)
        var dToken = await PersistentAppDevice.shared.dTokenHeaders()

        var entries: JSONValue?
        var routeTag = "auth-app"
        var lastError: Error?

        // Pass 1: single-episode `/novel/player/video_model/v1/` with phone-layout `x-medusa`
        // (since 2026-11-23 `/multi_video_model/v1/` returns empty 200 and is not asked on the hot path).
        do {
            entries = try await requestModels(
                vids: [vid],
                channels: [.videoModel],
                identity: identity,
                extraHeaders: dToken,
                deadline: deadline
            )
        } catch let error as AppSourceError {
            if error.code == .cancelled { throw error }
            lastError = error
            if error.code == .emptyResponse {
                batchCooldownUntil = Date().addingTimeInterval(Self.batchCooldownSeconds)
            }
            if error.isHardRejection && error.status != 403 {
                throw error
            }
        } catch {
            lastError = error
        }

        // Prefetches never trigger device renewal so they cannot consume the viewer's
        // recovery rate limits or race with an active viewer lookup.
        func isDeviceRecoverable(_ error: Error?) -> Bool {
            guard let appError = error as? AppSourceError else { return false }
            return appError.code == .emptyResponse || appError.status == 403
        }
        if entries == nil, allowRecovery, isDeviceRecoverable(lastError) {
            // A) Renew persisted device_id + refresh device_token + activate (app_alert_check).
            if deadline.timeIntervalSinceNow >= 2,
               let refreshed = try? await PersistentAppDevice.shared.refreshForRecovery(transport: transport),
               refreshed.refreshed {
                identity = refreshed.identity
                dToken = await PersistentAppDevice.shared.dTokenHeaders()
                do {
                    entries = try await requestModels(
                        vids: [vid],
                        channels: [.videoModel],
                        identity: identity,
                        extraHeaders: dToken,
                        deadline: deadline
                    )
                    routeTag = "auth-renew"
                } catch let error as AppSourceError {
                    if error.code == .cancelled { throw error }
                    lastError = error
                } catch {
                    lastError = error
                }
            }
            // B) If renewing the existing device_id still gets an empty/403 reply, register one
            // fresh activated device (coalesced across concurrent failures, 120 s cooldown).
            if entries == nil, isDeviceRecoverable(lastError), deadline.timeIntervalSinceNow >= 2,
               let reset = try? await PersistentAppDevice.shared.resetFreshForRecovery(
                   fromGeneration: startGen,
                   transport: transport
               ),
               reset.reset {
                identity = reset.identity
                dToken = await PersistentAppDevice.shared.dTokenHeaders()
                do {
                    entries = try await requestModels(
                        vids: [vid],
                        channels: [.videoModel],
                        identity: identity,
                        extraHeaders: dToken,
                        deadline: deadline
                    )
                    routeTag = "auth-reset"
                } catch let error as AppSourceError {
                    if error.code == .cancelled { throw error }
                    lastError = error
                } catch {
                    lastError = error
                }
            }
        }

        guard let entries else {
            throw lastError ?? AppSourceError(.emptyResponse, "App 接口返回空响应（HTTP 200），原因尚未确认")
        }

        let entry = entries[vid]
        let model = extractModel(from: entry)
        guard model.object != nil else {
            throw AppSourceError(entry["video_model"].isNull ? .missingModel : .invalidResponse,
                                 "App 接口未返回所选分集，已停止取址")
        }
        let expiresAt = VideoModelDiskCache.computeExpiry(
            serverExpireTime: entry["expire_time"].number ?? model["expire_time"].number
        )
        let inline = !(model["video_list"].object?.isEmpty ?? true) || !(model["video_list"].array?.isEmpty ?? true)
        if !inline {
            guard let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty else {
                throw AppSourceError(.missingModel, "App 接口未返回本集片源地址")
            }
            let pending = PendingFallback(fallbackURL: fallback, videoId: model["video_id"].string,
                                          duration: model["video_duration"].number,
                                          minimumPixels: 0, requireEncryptionMetadata: false, expiresAt: expiresAt)
            let resolved = try await resolveFallback(pending, vid: vid, deadline: deadline)
            storeCached(vid: vid, info: resolved.info, expiresAt: expiresAt, expectedEpoch: epoch)
            return (resolved.info, expiresAt, resolved.upgraded ? "\(routeTag)-h264" : routeTag)
        }
        do {
            var resolved = try AppSource.parsePlayModel(model, vid: vid, inline: true)
            var finalTag = routeTag
            if resolved.isByteVC2,
               let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty,
               deadline.timeIntervalSinceNow >= 2 {
                let extra = dToken
                if let hw = await CodecFallback.tryHardwareCodecFallback(
                    fallbackURL: fallback,
                    expectedVideoId: model["video_id"].string,
                    expectedDuration: model["video_duration"].number,
                    vid: vid,
                    transport: transport,
                    extraHeaders: extra,
                    deadline: deadline
                ) {
                    resolved = hw
                    finalTag = "\(routeTag)-h264"
                }
            }
            storeCached(vid: vid, info: resolved, expiresAt: expiresAt, expectedEpoch: epoch)
            return (resolved, expiresAt, finalTag)
        } catch let error as AppSourceError {
            if error.code == .noCompatibleSource,
               AppSource.containsByteVC2(model),
               let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty,
               deadline.timeIntervalSinceNow >= 2,
               let hw = await CodecFallback.tryHardwareCodecFallback(
                   fallbackURL: fallback,
                   expectedVideoId: model["video_id"].string,
                   expectedDuration: model["video_duration"].number,
                   vid: vid,
                   transport: transport,
                   extraHeaders: dToken,
                   deadline: deadline
               ) {
                storeCached(vid: vid, info: hw, expiresAt: expiresAt, expectedEpoch: epoch)
                return (hw, expiresAt, "\(routeTag)-h264")
            }
            let duration = model["video_duration"].number ?? .nan
            guard error.incompleteEncryptionMetadata,
                  let videoId = model["video_id"].string,
                  !videoId.trimmingCharacters(in: .whitespaces).isEmpty,
                  duration.isFinite, duration > 0,
                  error.minimumPixels > 0,
                  let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty else {
                throw error
            }
            let pending = PendingFallback(fallbackURL: fallback, videoId: videoId, duration: duration,
                                          minimumPixels: error.minimumPixels, requireEncryptionMetadata: true, expiresAt: expiresAt)
            let resolved = try await resolveFallback(pending, vid: vid, deadline: deadline)
            storeCached(vid: vid, info: resolved.info, expiresAt: expiresAt, expectedEpoch: epoch)
            return (resolved.info, expiresAt, resolved.upgraded ? "\(routeTag)-h264" : routeTag)
        }
    }

    private func resolveFallback(_ pending: PendingFallback, vid: String, deadline: Date) async throws -> (info: PlayInfo, upgraded: Bool) {
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
        let extra = dToken
        let outer = try await transport.requestJSON(
            pending.fallbackURL,
            headers: [("User-Agent", AppSource.iosPlayerUA)] + extra,
            deadline: deadline
        )
        for value in [outer, outer["video_info"]]
        where !value["Code"].isZeroOrMissingStatusCode || !value["code"].isZeroOrMissingStatusCode {
            throw AppSourceError(.businessRejected, "App 接口暂未提供本集播放信息")
        }
        let info = outer["video_info"]["data"]
        if let expectedId = pending.videoId, !expectedId.isEmpty,
           let expectedDuration = pending.duration, expectedDuration.isFinite, expectedDuration > 0 {
            let fallbackDuration = info["video_duration"].number ?? .nan
            guard info["video_id"].string == expectedId, fallbackDuration.isFinite, fallbackDuration > 0,
                  abs(fallbackDuration - expectedDuration) <= 0.5 else {
                throw AppSourceError(.invalidResponse, "备用片源编号或完整时长无法确认，已停止取址")
            }
        }
        do {
            let parsed = try AppSource.parsePlayModel(info, vid: vid, inline: false,
                                                      requireEncryptionMetadata: pending.requireEncryptionMetadata,
                                                      minimumPixels: pending.minimumPixels)
            if parsed.isByteVC2, deadline.timeIntervalSinceNow >= 2 {
                let expectedId = info["video_id"].string ?? pending.videoId
                let expectedDur = info["video_duration"].number ?? pending.duration
                if let hw = await CodecFallback.tryHardwareCodecFallback(
                    fallbackURL: pending.fallbackURL,
                    expectedVideoId: expectedId,
                    expectedDuration: expectedDur,
                    vid: vid,
                    transport: transport,
                    extraHeaders: extra,
                    deadline: deadline,
                    requireEncryptionMetadata: pending.requireEncryptionMetadata,
                    minimumPixels: pending.minimumPixels
                ) {
                    return (hw, true)
                }
            }
            return (parsed, false)
        } catch let error as AppSourceError where error.code == .noCompatibleSource && AppSource.containsByteVC2(info) {
            if deadline.timeIntervalSinceNow >= 2 {
                let expectedId = info["video_id"].string ?? pending.videoId
                let expectedDur = info["video_duration"].number ?? pending.duration
                if let hw = await CodecFallback.tryHardwareCodecFallback(
                    fallbackURL: pending.fallbackURL,
                    expectedVideoId: expectedId,
                    expectedDuration: expectedDur,
                    vid: vid,
                    transport: transport,
                    extraHeaders: extra,
                    deadline: deadline,
                    requireEncryptionMetadata: pending.requireEncryptionMetadata,
                    minimumPixels: pending.minimumPixels
                ) {
                    return (hw, true)
                }
            }
            throw error
        }
    }

    private enum Channel {
        /// Single-episode `/novel/player/video_model/v1/` with phone-layout `x-medusa` (v04.10.03).
        case videoModel
        /// Official iOS 7.4.3 `FQVPlayerApiService.mGetVideoModel` (`/multi_video_model/v1/`).
        case multiPlainIOS
    }

    /// Maximum episodes resolved per prefetch batch, and maximum concurrent requests per batch.
    private static let singleBatchLimit = 4
    private static let singleBatchConcurrency = 3

    private static let multiPlainPath = "/novel/player/multi_video_model/v1/"

    private func requestModels(vids: [String], channels: [Channel], identity: PlaybackIdentity,
                               extraHeaders: [(String, String)], deadline: Date) async throws -> JSONValue {
        try Task.checkCancellationAsApp()

        var lastError: Error?
        var response: JSONValue = .null
        var succeededChannel: Channel?

        for channel in channels {
            try Task.checkCancellationAsApp()
            guard deadline.timeIntervalSinceNow >= 1 else { break }
            if channel == .videoModel {
                do {
                    return try await requestVideoModels(vids: vids, identity: identity, deadline: deadline)
                } catch let error as AppSourceError {
                    if error.code == .cancelled { throw error }
                    lastError = error
                    continue
                }
            }
            do {
                let multiPayload = try AppSource.modelPayload(vids: vids)
                let req = try buildRequest(channel: channel, multiPayload: multiPayload, identity: identity)
                let reply = try await transport.requestJSON(
                    req.url,
                    method: "POST",
                    headers: req.headers + extraHeaders,
                    body: req.body,
                    deadline: deadline
                )
                if !reply["Code"].isZeroOrMissingStatusCode || !reply["code"].isZeroOrMissingStatusCode {
                    throw AppSourceError(.businessRejected, "App 接口暂未提供本集播放信息")
                }
                response = reply
                succeededChannel = channel
                break
            } catch let error as AppSourceError {
                if error.code == .cancelled { throw error }
                lastError = error
                if error.isHardRejection && error.status != 403 {
                    throw error
                }
                continue
            } catch {
                lastError = error
                continue
            }
        }

        guard succeededChannel != nil else {
            throw lastError ?? AppSourceError(.emptyResponse, "App 接口返回空响应（HTTP 200），原因尚未确认")
        }

        let data = response["data"]
        var merged: [String: JSONValue] = [:]
        for key in ["video_model_data", "1001", "1004"] {
            if let obj = data[key].object {
                for (k, v) in obj { merged[k] = v }
            }
        }
        if !merged.isEmpty { return .object(merged) }
        return data
    }

    private func buildRequest(channel: Channel, multiPayload: [UInt8], identity: PlaybackIdentity)
        throws -> (url: String, headers: [(String, String)], body: [UInt8]) {
        let base = "https://api5-normal-sinfonlineb.fqnovel.com\(Self.multiPlainPath)"
        return try AppSource.modelRequest(base: base, payload: multiPayload, identity: identity)
    }

    /// Resolves one episode (or a bounded concurrent prefetch slice of up to `singleBatchLimit`
    /// episodes) through `/novel/player/video_model/v1/`, returning `{vid: entry}`.
    private func requestVideoModels(vids: [String], identity: PlaybackIdentity, deadline: Date) async throws -> JSONValue {
        let ctx = await PersistentAppDevice.shared.playSessionContext()
        let targets = Array(vids.prefix(Self.singleBatchLimit))
        let transport = self.transport

        func fetchOne(_ vid: String) async -> (String, Result<JSONValue, AppSourceError>) {
            do {
                try Task.checkCancellationAsApp()
                guard deadline.timeIntervalSinceNow >= 1 else {
                    return (vid, .failure(AppSourceError(.timeout, "请求超时，请稍后重试")))
                }
                let req = try VideoModelRequest.request(
                    vid: vid,
                    identity: identity,
                    openudid: ctx.openudid,
                    guest: ctx.cookies,
                    dToken: ctx.dToken,
                    installMillis: ctx.firstInstallTimeMs
                )
                let reply = try await transport.requestJSON(
                    req.url,
                    method: "POST",
                    headers: req.headers,
                    body: req.body,
                    deadline: deadline
                )
                if !reply["Code"].isZeroOrMissingStatusCode || !reply["code"].isZeroOrMissingStatusCode {
                    return (vid, .failure(AppSourceError(.businessRejected, "App 接口暂未提供本集播放信息")))
                }
                let data = reply["data"]
                guard !data["video_model"].isNull else {
                    return (vid, .failure(AppSourceError(.missingModel, "App 接口未返回所选分集，已停止取址")))
                }
                return (vid, .success(data))
            } catch let error as AppSourceError {
                return (vid, .failure(error))
            } catch {
                return (vid, .failure(AppSourceError(.invalidResponse, "App 接口未返回有效数据")))
            }
        }

        if targets.count == 1, let only = targets.first {
            let (_, outcome) = await fetchOne(only)
            switch outcome {
            case .success(let data): return .object([only: data])
            case .failure(let error): throw error
            }
        }

        var merged: [String: JSONValue] = [:]
        var lastError: AppSourceError?
        var cancelled = false
        await withTaskGroup(of: (String, Result<JSONValue, AppSourceError>).self) { group in
            var nextIndex = 0
            let initial = min(Self.singleBatchConcurrency, targets.count)
            while nextIndex < initial {
                let vid = targets[nextIndex]
                nextIndex += 1
                group.addTask { await fetchOne(vid) }
            }
            while let (vid, outcome) = await group.next() {
                switch outcome {
                case .success(let data):
                    merged[vid] = data
                case .failure(let error):
                    if error.code == .cancelled {
                        cancelled = true
                        group.cancelAll()
                        continue
                    }
                    lastError = error
                    if merged.isEmpty, error.code == .emptyResponse {
                        group.cancelAll()
                        continue
                    }
                }
                if nextIndex < targets.count, !Task.isCancelled, deadline.timeIntervalSinceNow >= 1 {
                    let nextVid = targets[nextIndex]
                    nextIndex += 1
                    group.addTask { await fetchOne(nextVid) }
                }
            }
        }
        if cancelled { throw AppSourceError(.cancelled, "已取消 App 片源请求") }
        guard !merged.isEmpty else {
            throw lastError ?? AppSourceError(.emptyResponse, "App 接口返回空响应（HTTP 200），原因尚未确认")
        }
        return .object(merged)
    }

    private func extractModel(from entry: JSONValue) -> JSONValue {
        if let text = entry["video_model"].string {
            return (try? JSONValue.parse(text)) ?? .null
        }
        return entry["video_model"]
    }

    private func ingestBatchEntry(_ entry: JSONValue, vid: String, epoch: UInt64) -> (vid: String, info: PlayInfo, expiresAt: Date)? {
        let model = extractModel(from: entry)
        guard model.object != nil else { return nil }
        let expiresAt = VideoModelDiskCache.computeExpiry(
            serverExpireTime: entry["expire_time"].number ?? model["expire_time"].number
        )
        let inline = !(model["video_list"].object?.isEmpty ?? true) || !(model["video_list"].array?.isEmpty ?? true)
        if inline {
            do {
                let resolved = try AppSource.parsePlayModel(model, vid: vid, inline: true)
                if resolved.isByteVC2,
                   let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty {
                    pendingFallbacks[vid] = PendingFallback(fallbackURL: fallback, videoId: model["video_id"].string,
                                                            duration: model["video_duration"].number,
                                                            minimumPixels: 0, requireEncryptionMetadata: false,
                                                            expiresAt: expiresAt)
                    return nil
                }
                guard (vidEpochs[vid] ?? 0) == epoch else { return nil }
                storeMemory(vid: vid, info: resolved, expiresAt: expiresAt)
                return (vid: vid, info: resolved, expiresAt: expiresAt)
            } catch let error as AppSourceError {
                if error.code == .noCompatibleSource,
                   AppSource.containsByteVC2(model),
                   let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty {
                    pendingFallbacks[vid] = PendingFallback(fallbackURL: fallback, videoId: model["video_id"].string,
                                                            duration: model["video_duration"].number,
                                                            minimumPixels: 0, requireEncryptionMetadata: false,
                                                            expiresAt: expiresAt)
                    return nil
                }
                if error.incompleteEncryptionMetadata,
                   let videoId = model["video_id"].string, !videoId.isEmpty,
                   let duration = model["video_duration"].number, duration.isFinite, duration > 0,
                   error.minimumPixels > 0,
                   let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty {
                    pendingFallbacks[vid] = PendingFallback(fallbackURL: fallback, videoId: videoId, duration: duration,
                                                            minimumPixels: error.minimumPixels, requireEncryptionMetadata: true,
                                                            expiresAt: expiresAt)
                }
                return nil
            } catch {
                return nil
            }
        }
        if let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty {
            pendingFallbacks[vid] = PendingFallback(fallbackURL: fallback, videoId: model["video_id"].string,
                                                    duration: model["video_duration"].number,
                                                    minimumPixels: 0, requireEncryptionMetadata: false, expiresAt: expiresAt)
        }
        return nil
    }

    private func storeMemory(vid: String, info: PlayInfo, expiresAt: Date) {
        cached[vid] = CachedPlayInfo(info: info, expiresAt: expiresAt)
        cacheOrder.removeAll { $0 == vid }
        cacheOrder.append(vid)
        while cacheOrder.count > Self.maxCachedEntries {
            cached[cacheOrder.removeFirst()] = nil
        }
    }

    private func storeCached(vid: String, info: PlayInfo, expiresAt: Date, expectedEpoch: UInt64) {
        guard (vidEpochs[vid] ?? 0) == expectedEpoch else { return }
        storeMemory(vid: vid, info: info, expiresAt: expiresAt)
        diskCache.store(vid: vid, info: info, expiresAt: expiresAt)
    }
}

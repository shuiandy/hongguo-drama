import AVFoundation
import Foundation
import HongguoCore

/// Everything needed to start one episode: the signed source, ordered CDN candidates, and for
/// encrypted media the rebuilt MP4 header that lets it play while it downloads.
public struct PreparedEpisode: Sendable {
    public let info: PlayInfo
    /// Complete ordered CDN candidate list starting with `info.url` (e.g. `[B, C, A]` after
    /// failover to `B`), so downstream loaders never lose remaining backup edges.
    public let mediaURLs: [URL]
    /// nil for plain media, and for encrypted media whose layout cannot be decrypted on the fly.
    public let map: CencStreamMap?
    /// Trailing encrypted media bytes fetched alongside `moov` in the initial ranged request.
    public let initialMedia: MediaPrefixCache.Prefix?
    /// Full `[0 ..< N]` encrypted bytes starting from offset 0 (used by `MediaPrefixCache.prefetch`
    /// to continue downloading without re-fetching `moov` or opening media bytes).
    public let rawPrefixData: Data?
    public let sourceObtainedAt: Date
    public let resolvedAt: Date
    /// Server-derived expiration time for the signed media URL (replaces hardcoded 15-minute TTL).
    public let expiresAt: Date
    /// Seconds spent resolving the source and opening the header (0 when served from memory).
    public let sourceSeconds: Double
    public let headerSeconds: Double
    public let fromPrefetch: Bool

    public init(info: PlayInfo, mediaURLs: [URL]? = nil, map: CencStreamMap?,
                initialMedia: MediaPrefixCache.Prefix? = nil, rawPrefixData: Data? = nil,
                sourceObtainedAt: Date? = nil, resolvedAt: Date, expiresAt: Date? = nil,
                sourceSeconds: Double, headerSeconds: Double, fromPrefetch: Bool) {
        self.info = info
        if let mediaURLs, !mediaURLs.isEmpty {
            self.mediaURLs = mediaURLs
        } else {
            self.mediaURLs = PlayBackupURLs.shared.allCandidates(startingWith: info.url)
        }
        self.map = map
        self.initialMedia = initialMedia
        self.rawPrefixData = rawPrefixData
        self.sourceObtainedAt = sourceObtainedAt ?? resolvedAt.addingTimeInterval(-headerSeconds)
        self.resolvedAt = resolvedAt
        self.expiresAt = expiresAt ?? resolvedAt.addingTimeInterval(EpisodeResolver.lifetime)
        self.sourceSeconds = sourceSeconds
        self.headerSeconds = headerSeconds
        self.fromPrefetch = fromPrefetch
    }
}

public enum PlaybackProblem: LocalizedError, Equatable {
    /// The episode is only offered in ByteVC2, which no Apple decoder plays.
    case unsupportedCodec
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCodec: return "此剧集暂不支持"
        case .message(let text): return text
        }
    }

    public static func from(_ error: Error) -> PlaybackProblem {
        if let problem = error as? PlaybackProblem { return problem }
        let text = describeError(error)
        // With the iOS stand-in for ByteVC2Converter the App source refuses such rows by message.
        return text.contains("ByteVC2") ? .unsupportedCodec : .message(text)
    }
}

/// Resolves and remembers episode sources. One place does it for the player and for prefetch,
/// so a prefetched episode is not resolved twice and requests are counted in one spot.
/// Uses reference-counted waiters per in-flight lookup so cancelling a background prefetch
/// never cancels a lookup that the foreground viewer has already joined.
public actor EpisodeResolver {
    public static let shared = EpisodeResolver()

    /// Fallback signed URL lifetime when a source does not provide an explicit `expire_time`.
    public static let lifetime: TimeInterval = 15 * 60

    private final class InflightEntry {
        let id = UUID()
        let epoch: UInt64
        let task: Task<(PreparedEpisode, String), Error>
        var waiters: Set<UUID> = []
        var isViewerOwned: Bool
        init(epoch: UInt64, task: Task<(PreparedEpisode, String), Error>, isViewerOwned: Bool) {
            self.epoch = epoch
            self.task = task
            self.isViewerOwned = isViewerOwned
        }
    }

    private struct SeedEntry {
        let info: PlayInfo
        let expiresAt: Date
    }

    typealias LookupOverride = @Sendable (_ vid: String, _ seriesId: String, _ preferredShortSide: Int?, _ force: Bool, _ prefetch: Bool) async throws -> (PlayInfo, Date, String)

    private let series: SeriesService
    private let lookupOverride: LookupOverride?
    private let foregroundLock = NSLock()
    private nonisolated(unsafe) var foregroundTarget: String?
    private var ready: [String: PreparedEpisode] = [:]
    private var order: [String] = []
    /// Per-key monotonic generation counter so a slow older prefetch can never overwrite a newer
    /// `force: true` refresh or a `forget(vid:)` invalidation in `ready`.
    private var keyEpochs: [String: UInt64] = [:]
    private var inflight: [String: InflightEntry] = [:]
    private var episodeLists: [String: SeriesEpisodes] = [:]
    /// Sources saved by an earlier run, each tried once in place of a lookup while unexpired.
    private var seeds: [String: SeedEntry] = [:]
    /// Source lookups actually sent (cache hits not counted), for reporting.
    public private(set) var sourceLookups = 0
    public private(set) var episodeListLookups = 0
    /// Where a line about each lookup goes (the app's playback log). Set once at launch.
    public nonisolated(unsafe) static var note: (@Sendable (String) -> Void)?

    public init(series: SeriesService = SeriesService()) {
        self.series = series
        self.lookupOverride = nil
    }

    init(series: SeriesService = SeriesService(), lookupOverride: LookupOverride?) {
        self.series = series
        self.lookupOverride = lookupOverride
    }

    /// Synchronously marks the viewer's newly selected `(vid, preferredShortSide)` before any
    /// background prefetch task is cancelled, so an in-flight prefetch for that exact episode
    /// survives cancellation and is handed off cleanly to the foreground viewer (Codex #6).
    public nonisolated func markForegroundTarget(vid: String?, preferredShortSide: Int?) {
        let key = vid.map { Self.key($0, preferredShortSide) }
        foregroundLock.withLock { foregroundTarget = key }
    }

    private nonisolated func currentForegroundTarget() -> String? {
        foregroundLock.withLock { foregroundTarget }
    }

    /// Rotates `candidates` so `winner` sits at index 0 while preserving every other candidate
    /// in original priority order (`[A, B, C]` promoting `B` -> `[B, C, A]`).
    public static func rotateCandidates(_ candidates: [URL], promoting winner: URL) -> [URL] {
        var list = candidates.filter { $0 != winner }
        if let idx = candidates.firstIndex(of: winner) {
            let tail = Array(candidates[(idx + 1)...])
            let head = Array(candidates[..<idx])
            list = tail + head
        }
        return [winner] + list
    }

    public func episodes(seriesId: String) async throws -> SeriesEpisodes {
        if let list = episodeLists[seriesId] { return list }
        episodeListLookups += 1
        let list: SeriesEpisodes
        do {
            list = try await EpisodeSocialService.episodes(seriesId: seriesId)
        } catch {
            try Task.checkCancellation()
            let expected = (error as? EpisodeSocialService.IncompleteEpisodeList)?.expectedCount ?? 0
            list = try await series.episodes(seriesId: seriesId)
            guard EpisodeSocialService.isCompleteEpisodeList(list.episodes.map(\.index), declaredCount: expected) else {
                throw HongguoError(.format, "分集列表不完整，请稍后重试")
            }
        }
        episodeLists[seriesId] = list
        return list
    }

    public func details(seriesId: String) async throws -> PublicDetails {
        try await series.publicDetails(seriesId: seriesId)
    }

    public func warmUpAppSource() async {
        await AuthenticatedPlaybackSource.shared.warmUpIdentity()
    }

    public func prefetchBatch(vids: [String]) async {
        await AuthenticatedPlaybackSource.shared.prefetchBatch(vids: vids)
    }

    /// Returns true if this episode already has an unexpired resolved PlayInfo in memory or disk.
    public func hasCachedSource(vid: String, preferredShortSide: Int? = nil) async -> Bool {
        let now = Date()
        if let hit = ready[Self.key(vid, preferredShortSide)], now < hit.expiresAt { return true }
        return await AuthenticatedPlaybackSource.shared.cachedPlayInfoWithMeta(vid: vid) != nil
    }

    private static func key(_ vid: String, _ shortSide: Int?) -> String { "\(vid):\(shortSide ?? 0)" }

    /// Attempts to open an encrypted MP4 header purely from the local unified disk prefix cache
    /// (`0 ms` network RTT). Returns nil if no sufficient local prefix exists yet.
    private static func openEncryptedHeaderFromDisk(for info: PlayInfo) throws -> FastCencOpenResult? {
        let prefixKey = MediaPrefixCache.key(for: info)
        guard let cached = MediaPrefixCache.shared.loadRawHeader(key: prefixKey) else { return nil }
        return try FastCencOpener.openFromCachedPrefix(info, rawPrefix: cached.data, totalLength: cached.totalLength)
    }

    /// Opens an encrypted MP4 header: first checks unified disk cache (`0 ms` zero-network hit),
    /// then fetches over CDN with automatic `backup_url` failover across all `candidates`.
    /// Returns nil `map` ONLY when the MP4 container layout cannot be decrypted progressively
    /// (including HTTP 200 ignoring Range), and throws `FastCencOpenError.mediaUnavailable` for
    /// HTTP/403/network failures so expired URLs trigger cache invalidation + re-resolution.
    private static func openEncryptedHeader(for info: PlayInfo, candidates: [URL]) async throws -> FastCencOpenResult? {
        do {
            if let local = try openEncryptedHeaderFromDisk(for: info) {
                return local
            }
        } catch FastCencOpenError.unsupportedLayout {
            return nil
        } catch {
            // Fall through to network header fetch if cached header was somehow unreadable.
        }
        do {
            return try await FastCencOpener.open(info, candidates: candidates)
        } catch FastCencOpenError.unsupportedLayout {
            return nil
        }
    }

    /// Returns a prepared episode, resolving it unless a fresh one is already in memory.
    /// `prefetch` only labels the result for timing reports.
    public func prepare(vid: String, seriesId: String, preferredShortSide: Int? = nil,
                        force: Bool = false, prefetch: Bool = false, automaticRetry: Bool = false) async throws -> PreparedEpisode {
        let key = Self.key(vid, preferredShortSide)
        let now = Date()
        if !force, let hit = ready[key], now < hit.expiresAt {
            return PreparedEpisode(info: hit.info, mediaURLs: hit.mediaURLs, map: hit.map,
                                   initialMedia: hit.initialMedia, rawPrefixData: hit.rawPrefixData,
                                   resolvedAt: hit.resolvedAt, expiresAt: hit.expiresAt,
                                   sourceSeconds: 0, headerSeconds: 0, fromPrefetch: true)
        }
        if !force, let existing = inflight[key] {
            // The viewer wants the very episode a prefetch is fetching: transfer ownership so
            // cancelling the old background prefetch never cancels the viewer's active request.
            if !prefetch {
                markForegroundTarget(vid: vid, preferredShortSide: preferredShortSide)
                existing.isViewerOwned = true
                cancelLookups(except: key)
            }
            let waiterID = UUID()
            existing.waiters.insert(waiterID)
            defer { releaseWaiter(waiterID, key: key, entryID: existing.id, cancelIfEmpty: false) }
            let (prepared, _) = try await withTaskCancellationHandler {
                try await existing.task.value
            } onCancel: {
                Task { await self.releaseWaiter(waiterID, key: key, entryID: existing.id, cancelIfEmpty: true) }
            }
            if ready[key] == nil {
                storeReady(prepared, for: key, epoch: existing.epoch)
            }
            return prepared
        }

        // Cancel any lingering prefetch or superseded episode lookup so the viewer's choice
        // never waits behind background work. On `force: true`, also supersede any in-flight task
        // for the same key and bump its epoch so a late completion can never overwrite `ready[key]`.
        if !prefetch { markForegroundTarget(vid: vid, preferredShortSide: preferredShortSide) }
        if force {
            ready.removeValue(forKey: key)
            seeds.removeValue(forKey: key)
            inflight.removeValue(forKey: key)?.task.cancel()
        }
        let epoch = bumpEpoch(for: key)
        let dropped = prefetch ? 0 : cancelLookups(except: key)
        let ahead = inflight.count
        let rawSeed = force ? nil : seeds.removeValue(forKey: key)
        // Never accept an already-expired seed (Codex #7).
        let seeded: SeedEntry? = (rawSeed != nil && now < rawSeed!.expiresAt) ? rawSeed : nil
        if seeded == nil { sourceLookups += 1 }
        let webAvailable = force && !automaticRetry ? nil : episodeLists[seriesId]?.episodes.first { $0.vid == vid }?.webAvailable
        let service = series
        let overrideLookup = lookupOverride
        let task = Task<(PreparedEpisode, String), Error> {
            let started = Date()
            var info: PlayInfo
            var expiresAt = Date().addingTimeInterval(Self.lifetime)
            var routeTag: String
            var cameFromCache = false
            var savedMap: CencStreamMap?
            var savedInitial: MediaPrefixCache.Prefix?
            var savedRawPrefix: Data?
            var openedFromDisk = false
            var mediaURLs: [URL] = []

            func resolveFresh(forceLookup: Bool) async throws -> (PlayInfo, Date, String) {
                if let overrideLookup {
                    return try await overrideLookup(vid, seriesId, preferredShortSide, forceLookup, prefetch)
                }
                do {
                    let resolved = try await AuthenticatedPlaybackSource.shared.resolveWithMeta(
                        vid: vid, force: forceLookup, allowRecovery: !prefetch
                    )
                    return (resolved.info.selecting(shortSide: preferredShortSide), resolved.expiresAt, resolved.route)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if let hongguo = error as? HongguoError, hongguo.kind == .cancelled { throw hongguo }
                    guard !prefetch else { throw PlaybackProblem.from(error) }
                    do {
                        let fallback = try await service.playInfo(vid: vid, seriesId: seriesId, force: forceLookup, webAvailable: webAvailable)
                            .selecting(shortSide: preferredShortSide)
                        return (fallback, Date().addingTimeInterval(Self.lifetime), "core-\(fallback.source.rawValue)")
                    } catch {
                        throw PlaybackProblem.from(error)
                    }
                }
            }

            if let seeded, !seeded.info.isByteVC2, seeded.info.isEncrypted,
               let opened = try? await Self.openEncryptedHeader(for: seeded.info,
                                                                candidates: PlayBackupURLs.shared.allCandidates(startingWith: seeded.info.url)) {
                info = seeded.info
                expiresAt = seeded.expiresAt
                let all = PlayBackupURLs.shared.allCandidates(startingWith: info.url)
                mediaURLs = Self.rotateCandidates(all, promoting: opened.resolvedURL)
                if opened.resolvedURL != info.url {
                    info.url = opened.resolvedURL
                    PlayBackupURLs.shared.register(primary: opened.resolvedURL, backups: Array(mediaURLs.dropFirst()))
                }
                routeTag = opened.fromDisk ? "seed-disk" : "seed"
                openedFromDisk = opened.fromDisk
                savedMap = opened.map
                savedRawPrefix = opened.rawPrefixData
                if !opened.initialMediaData.isEmpty {
                    savedInitial = MediaPrefixCache.Prefix(start: opened.initialMediaStart, data: opened.initialMediaData, fromDisk: opened.fromDisk)
                }
            } else if overrideLookup == nil, !force, let fastHit = await AuthenticatedPlaybackSource.shared.cachedPlayInfoWithMeta(vid: vid) {
                info = fastHit.info.selecting(shortSide: preferredShortSide)
                expiresAt = fastHit.expiresAt
                routeTag = fastHit.route
                cameFromCache = true
                mediaURLs = PlayBackupURLs.shared.allCandidates(startingWith: info.url)
            } else {
                (info, expiresAt, routeTag) = try await resolveFresh(forceLookup: force)
                mediaURLs = PlayBackupURLs.shared.allCandidates(startingWith: info.url)
            }

            var sourceObtainedAt = savedMap == nil ? Date() : started
            // Playable only where a converter is installed (the app with its decoder library).
            if info.isByteVC2, !ByteVC2Converter.isEnabled { throw PlaybackProblem.unsupportedCodec }
            try Task.checkCancellation()

            var map: CencStreamMap? = savedMap
            var initialMedia: MediaPrefixCache.Prefix? = savedInitial
            var rawPrefix: Data? = savedRawPrefix

            // Fast local disk header check BEFORE any network DNS/DoH check so a cold start with
            // an already-cached unified `[0 ..< 5 MiB]` prefix plays immediately without waiting
            // on network DNS/DoH.
            if map == nil, info.isEncrypted, !info.isByteVC2, PlaybackCache.shared.cachedFile(for: info) == nil {
                if let local = try? Self.openEncryptedHeaderFromDisk(for: info) {
                    map = local.map
                    rawPrefix = local.rawPrefixData
                    if !local.initialMediaData.isEmpty {
                        initialMedia = MediaPrefixCache.Prefix(start: local.initialMediaStart, data: local.initialMediaData, fromDisk: true)
                    }
                    openedFromDisk = true
                    routeTag += "+hdr-disk"
                }
            }

            if overrideLookup == nil {
                guard URLGuard.isPublicURL(info.url) else {
                    throw HongguoError(.security, "片源及其跳转、解析结果必须指向公网")
                }
                if openedFromDisk, URLGuard.allowsUnconfirmed(host: info.url.host ?? "", scheme: info.url.scheme) {
                    // Warm URLGuard DNS/DoH cache in the background while AVPlayer starts from the
                    // local 5 MiB disk prefix with 0 ms network blocking.
                    let urlToWarm = info.url
                    Task.detached(priority: .utility) { _ = try? await URLGuard.check(urlToWarm) }
                } else {
                    try await URLGuard.check(info.url)
                }
            }

            // ByteVC2 is converted as a whole file, never decrypted on the fly.
            if map == nil, info.isEncrypted, !info.isByteVC2, PlaybackCache.shared.cachedFile(for: info) == nil {
                do {
                    if let opened = try await Self.openEncryptedHeader(for: info, candidates: mediaURLs) {
                        mediaURLs = Self.rotateCandidates(mediaURLs, promoting: opened.resolvedURL)
                        if opened.resolvedURL != info.url {
                            info.url = opened.resolvedURL
                            PlayBackupURLs.shared.register(primary: opened.resolvedURL, backups: Array(mediaURLs.dropFirst()))
                        }
                        map = opened.map
                        rawPrefix = opened.rawPrefixData
                        if !opened.initialMediaData.isEmpty {
                            initialMedia = MediaPrefixCache.Prefix(start: opened.initialMediaStart, data: opened.initialMediaData, fromDisk: opened.fromDisk)
                        }
                        if opened.fromDisk { routeTag += "+hdr-disk" }
                    }
                } catch let openErr as FastCencOpenError where cameFromCache {
                    // Cached signed URL expired (e.g. HTTP 403) or stale CDN edge: invalidate and
                    // re-resolve fresh once instead of falling through to whole-file download.
                    _ = openErr
                    await AuthenticatedPlaybackSource.shared.forget(vid: vid)
                    let refreshed = try await resolveFresh(forceLookup: true)
                    info = refreshed.0
                    expiresAt = refreshed.1
                    mediaURLs = PlayBackupURLs.shared.allCandidates(startingWith: info.url)
                    routeTag = "\(refreshed.2)-reopen"
                    sourceObtainedAt = Date()
                    if info.isByteVC2, !ByteVC2Converter.isEnabled { throw PlaybackProblem.unsupportedCodec }
                    try Task.checkCancellation()
                    try await URLGuard.check(info.url)
                    if info.isEncrypted, !info.isByteVC2,
                       let opened = try await Self.openEncryptedHeader(for: info, candidates: mediaURLs) {
                        mediaURLs = Self.rotateCandidates(mediaURLs, promoting: opened.resolvedURL)
                        if opened.resolvedURL != info.url {
                            info.url = opened.resolvedURL
                            PlayBackupURLs.shared.register(primary: opened.resolvedURL, backups: Array(mediaURLs.dropFirst()))
                        }
                        map = opened.map
                        rawPrefix = opened.rawPrefixData
                        if !opened.initialMediaData.isEmpty {
                            initialMedia = MediaPrefixCache.Prefix(start: opened.initialMediaStart, data: opened.initialMediaData, fromDisk: opened.fromDisk)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as HongguoError where error.kind == .cancelled {
                    throw error
                } catch let openErr as FastCencOpenError {
                    throw PlaybackProblem.from(openErr)
                }
            }

            let prepared = PreparedEpisode(info: info, mediaURLs: mediaURLs, map: map,
                                           initialMedia: initialMedia, rawPrefixData: rawPrefix,
                                           sourceObtainedAt: sourceObtainedAt,
                                           resolvedAt: Date(), expiresAt: expiresAt,
                                           sourceSeconds: sourceObtainedAt.timeIntervalSince(started),
                                           headerSeconds: Date().timeIntervalSince(sourceObtainedAt),
                                           fromPrefetch: prefetch || savedMap != nil)
            return (prepared, routeTag)
        }

        let waiterID = UUID()
        let entry = InflightEntry(epoch: epoch, task: task, isViewerOwned: !prefetch)
        entry.waiters.insert(waiterID)
        inflight[key] = entry
        defer { releaseWaiter(waiterID, key: key, entryID: entry.id, cancelIfEmpty: false) }

        let began = Date()
        let label = "source vid=\(vid.suffix(6)) \(prefetch ? "prefetch" : "viewer")\(force ? " retry" : "")"
        let result: PreparedEpisode
        let routeTag: String
        do {
            (result, routeTag) = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.releaseWaiter(waiterID, key: key, entryID: entry.id, cancelIfEmpty: true) }
            }
        } catch {
            if seeded == nil {
                let text = describeError(error)
                let empties = text.components(separatedBy: "空响应").count - 1
                let outcome = empties > 0 ? "empty×\(empties)" : text.contains("取消") || error is CancellationError ? "cancelled" : "failed"
                Self.note?("\(label) \(outcome) ms=\(Int(Date().timeIntervalSince(began) * 1000)) ahead=\(ahead) dropped=\(dropped)")
            }
            throw error
        }
        if seeded == nil {
            Self.note?("\(label) ok via=\(routeTag) ms=\(Int(result.sourceSeconds * 1000)) header=\(Int(result.headerSeconds * 1000)) ahead=\(ahead) dropped=\(dropped)")
        }
        storeReady(result, for: key, epoch: epoch)
        return result
    }

    private func bumpEpoch(for key: String) -> UInt64 {
        let next = (keyEpochs[key] ?? 0) &+ 1
        keyEpochs[key] = next
        return next
    }

    private func storeReady(_ prepared: PreparedEpisode, for key: String, epoch: UInt64) {
        guard keyEpochs[key] == epoch else { return }
        ready[key] = prepared
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 16 { ready[order.removeFirst()] = nil }
    }

    private func releaseWaiter(_ waiterID: UUID, key: String, entryID: UUID, cancelIfEmpty: Bool) {
        guard let current = inflight[key], current.id == entryID else { return }
        current.waiters.remove(waiterID)
        if current.waiters.isEmpty {
            // If the foreground viewer just selected this exact episode before entering `prepare`,
            // keep the in-flight task alive across the brief prefetch-cancel handoff window.
            if cancelIfEmpty, currentForegroundTarget() == key {
                current.isViewerOwned = true
                return
            }
            if cancelIfEmpty { current.task.cancel() }
            inflight[key] = nil
        }
    }

    /// Cancels every lookup in flight but the one for `key`. Returns how many.
    @discardableResult
    private func cancelLookups(except key: String) -> Int {
        let others = inflight.filter { $0.key != key }
        for (other, entry) in others {
            entry.task.cancel()
            inflight[other] = nil
        }
        return others.count
    }

    /// A source saved by an earlier run with its true server expiration timestamp.
    public func seed(_ info: PlayInfo, expiresAt: Date? = nil, preferredShortSide: Int?) {
        let expiry = expiresAt ?? Date().addingTimeInterval(Self.lifetime)
        guard Date() < expiry else { return }
        seeds[Self.key(info.vid, preferredShortSide)] = SeedEntry(info: info, expiresAt: expiry)
    }

    /// The source in memory for an episode, for saving.
    public func resolvedInfo(vid: String, preferredShortSide: Int?) -> PlayInfo? {
        resolvedMeta(vid: vid, preferredShortSide: preferredShortSide)?.info
    }

    /// The source and its true expiration timestamp in memory for an episode, for saving.
    public func resolvedMeta(vid: String, preferredShortSide: Int?) -> (info: PlayInfo, expiresAt: Date)? {
        guard let hit = ready[Self.key(vid, preferredShortSide)], Date() < hit.expiresAt else { return nil }
        return (hit.info, hit.expiresAt)
    }

    public func forget(vid: String) async {
        let prefix = "\(vid):"
        for key in ready.keys where key.hasPrefix(prefix) { ready[key] = nil }
        for key in keyEpochs.keys where key.hasPrefix(prefix) { _ = bumpEpoch(for: key) }
        for (key, entry) in inflight where key.hasPrefix(prefix) {
            entry.task.cancel()
            inflight[key] = nil
        }
        order.removeAll { $0.hasPrefix(prefix) }
        await AuthenticatedPlaybackSource.shared.forget(vid: vid)
        await FastAppPlaybackSource.shared.forget(vid: vid)
    }

    public func markWebFailure(_ info: PlayInfo) async {
        await series.markWebMediaFailure(info)
    }
}

/// How an item reaches AVPlayer.
public enum PlaybackRoute: String, Sendable {
    case stream, progressiveDecrypt, decryptedFile
    /// Converted on the device while it plays (ByteVC2), served as a local stream.
    case convertedStream
}

public enum PlayerItemFactory {
    /// Cap for fully downloaded and decrypted episodes in Caches. Episodes that decrypt while
    /// streaming never land there, so in practice this only bounds the fallback path.
    public static let cacheLimitBytes: Int64 = 1_073_741_824

    public static func configureCache() {
        PlaybackCache.shared.setLimit(bytes: cacheLimitBytes)
    }

    /// Cached decrypted file > decrypt while streaming > download and decrypt everything.
    public static func makeItem(for prepared: PreparedEpisode) async throws
        -> (item: AVPlayerItem, route: PlaybackRoute, loader: StreamingResourceLoader?) {
        let info = prepared.info
        let backups = Array(prepared.mediaURLs.dropFirst())
        guard info.needsLocalFile else {
            let loader = StreamingResourceLoader(source: info.url, backupURLs: backups, headers: info.httpHeaders)
            return (AVPlayerItem(asset: loader.makeAsset()), .stream, loader)
        }
        if let file = PlaybackCache.shared.cachedFile(for: info) {
            return (AVPlayerItem(url: file), .decryptedFile, nil)
        }
        if let map = prepared.map, map.inputLength > 0, !info.isByteVC2 {
            let cacheKey = MediaPrefixCache.key(for: info)
            let prefix = MediaPrefixCache.shared.load(key: cacheKey) ?? prepared.initialMedia
            let loader = StreamingResourceLoader(source: info.url, backupURLs: backups, headers: info.httpHeaders,
                                                 map: map, prefix: prefix, prefixCacheKey: cacheKey)
            return (AVPlayerItem(asset: loader.makeAsset()), .progressiveDecrypt, loader)
        }
        let file = try await PlaybackCache.shared.prepare(info)
        try Task.checkCancellation()
        return (AVPlayerItem(url: file), .decryptedFile, nil)
    }
}

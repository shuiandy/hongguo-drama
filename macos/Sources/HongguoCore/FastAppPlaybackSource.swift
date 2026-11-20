// SPDX-License-Identifier: GPL-3.0-only
// Fast App playback source, shared by the Mac and iOS apps. It keeps one registered anonymous
// PlaybackIdentity in memory (never on disk, never logged) and registers again only after a
// failure, fetches up to 6 play models in one `multi_video_model/player/v1` POST for episodes
// the viewer is likely to pick next, and sends a viewer's own lookup at once instead of
// queueing it behind the one-per-second line in `AppSource`.
// Measurements behind these rules: the iOS repository's docs/SOURCE-LOOKUPS.md.
import Foundation

public actor FastAppPlaybackSource {
    public static let shared = FastAppPlaybackSource()

    /// Signed URLs expire; match EpisodeResolver's 15-minute window.
    public static let cacheLifetime: TimeInterval = 15 * 60
    private static let maxCachedEntries = 256
    /// Keep batch size conservative (one POST of at most 6 vids) to avoid triggering empty replies.
    private static let maxBatchSize = 6
    private static let batchCooldownSeconds: TimeInterval = 30

    private struct CachedPlayInfo {
        let info: PlayInfo
        let at: Date
    }

    private struct PendingFallback {
        let fallbackURL: String
        let videoId: String?
        let duration: Double?
        let minimumPixels: Int
        let requireEncryptionMetadata: Bool
        let at: Date
    }

    private let transport: AppTransport
    /// Memory-only anonymous identity (never persisted to disk, never logged).
    private var identity: PlaybackIdentity?
    private var identityTask: Task<PlaybackIdentity, Error>?
    private var cached: [String: CachedPlayInfo] = [:]
    private var cacheOrder: [String] = []
    private var pendingFallbacks: [String: PendingFallback] = [:]
    private var inflightSingle: [String: Task<PlayInfo, Error>] = [:]
    private var inflightBatchTask: Task<Void, Never>?
    private var inflightBatchVids: Set<String> = []
    private var batchCooldownUntil = Date.distantPast

    public init(http: HTTPClient = .shared) {
        self.transport = AppTransport(http: http)
    }

    /// Pre-registers an anonymous playback identity in the background so the first episode
    /// selection does not pay the ~500 ms device_register round-trip.
    public func warmUpIdentity() async {
        _ = try? await getIdentity(forceFresh: false)
    }

    /// Returns a fresh cached PlayInfo if already resolved by an earlier batch or single lookup.
    public func cachedPlayInfo(vid: String) -> PlayInfo? {
        guard let hit = cached[vid], Date().timeIntervalSince(hit.at) < Self.cacheLifetime else { return nil }
        return hit.info
    }

    public func forget(vid: String) {
        cached[vid] = nil
        cacheOrder.removeAll { $0 == vid }
        pendingFallbacks[vid] = nil
    }

    /// Resolves a single episode immediately for the viewer, reusing the cached identity and
    /// skipping the 1 s serial throttle.
    public func playInfo(vid: String, force: Bool = false) async throws -> PlayInfo {
        do {
            return try await resolve(vid: vid, force: force)
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
    }

    /// `playInfo` with the App error kept, so callers inside the core can tell an empty reply
    /// from a refusal.
    func resolve(vid: String, force: Bool = false) async throws -> PlayInfo {
        guard vid.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else {
            throw AppSourceError(.input, "分集编号无效")
        }
        if !force, let hit = cachedPlayInfo(vid: vid) {
            return hit
        }
        if !force, let task = inflightSingle[vid] {
            return try await task.value
        }
        // Viewer choice preempts any background batch prefetch.
        inflightBatchTask?.cancel()
        inflightBatchTask = nil
        let task = Task<PlayInfo, Error> {
            try await self.resolveSingle(vid: vid, force: force)
        }
        inflightSingle[vid] = task
        defer { if inflightSingle[vid] == task { inflightSingle[vid] = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Conservatively batch-fetches up to `maxBatchSize` (6) video models in a single POST.
    /// Skips while a viewer lookup is active or during empty-reply cool-down.
    public func prefetchBatch(vids: [String]) async {
        let now = Date()
        guard now >= batchCooldownUntil, inflightSingle.isEmpty else { return }
        var unique: [String] = []
        var seen: Set<String> = []
        for vid in vids {
            guard vid.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil,
                  seen.insert(vid).inserted else { continue }
            if let hit = cached[vid], now.timeIntervalSince(hit.at) < Self.cacheLifetime { continue }
            if let fb = pendingFallbacks[vid], now.timeIntervalSince(fb.at) < Self.cacheLifetime { continue }
            if inflightBatchVids.contains(vid) || inflightSingle[vid] != nil { continue }
            unique.append(vid)
            if unique.count >= Self.maxBatchSize { break }
        }
        guard !unique.isEmpty else { return }

        inflightBatchTask?.cancel()
        let chunk = unique
        let task = Task<Void, Never> {
            chunk.forEach { self.inflightBatchVids.insert($0) }
            defer { chunk.forEach { self.inflightBatchVids.remove($0) } }
            do {
                let entries = try await self.requestModels(vids: chunk, deadline: Date().addingTimeInterval(10))
                guard !Task.isCancelled else { return }
                for vid in chunk {
                    self.ingestBatchEntry(entries[vid], vid: vid)
                }
            } catch {
                // Background batch prefetch is best-effort.
            }
        }
        inflightBatchTask = task
        await task.value
        if inflightBatchTask == task { inflightBatchTask = nil }
    }

    // MARK: Internals

    private func getIdentity(forceFresh: Bool) async throws -> (identity: PlaybackIdentity, reused: Bool) {
        if !forceFresh, let identity { return (identity, true) }
        if forceFresh {
            // Clear the cached identity without cancelling an already in-flight fresh registration
            // so concurrent callers sharing that fresh registration are not disrupted.
            identity = nil
        }
        if let existing = identityTask {
            return (try await existing.value, false)
        }
        let transport = self.transport
        let task = Task<PlaybackIdentity, Error> {
            try await PlaybackDevice.registerOnce(transport: transport)
        }
        identityTask = task
        do {
            let fresh = try await task.value
            identity = fresh
            if identityTask == task { identityTask = nil }
            return (fresh, false)
        } catch {
            if identityTask == task { identityTask = nil }
            throw error
        }
    }

    private func resolveSingle(vid: String, force: Bool) async throws -> PlayInfo {
        let deadline = Date().addingTimeInterval(12)
        // If a batch prefetch already retrieved a fallback_api for this vid, skip multi_video_model.
        if !force, let pending = pendingFallbacks.removeValue(forKey: vid),
           Date().timeIntervalSince(pending.at) < Self.cacheLifetime {
            if let resolved = try? await resolveFallback(pending, vid: vid, deadline: deadline) {
                storeCached(vid: vid, info: resolved)
                return resolved
            }
        }

        let entries = try await requestModels(vids: [vid], deadline: deadline)
        let entry = entries[vid]
        let model = extractModel(from: entry)
        guard model.object != nil else {
            throw AppSourceError(entry["video_model"].isNull ? .missingModel : .invalidResponse,
                                 "App 接口未返回所选分集，已停止取址")
        }
        let inline = !(model["video_list"].object?.isEmpty ?? true)
        if !inline {
            guard let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty else {
                throw AppSourceError(.missingModel, "App 接口未返回本集片源地址")
            }
            let pending = PendingFallback(fallbackURL: fallback, videoId: nil, duration: nil,
                                          minimumPixels: 0, requireEncryptionMetadata: false, at: Date())
            let resolved = try await resolveFallback(pending, vid: vid, deadline: deadline)
            storeCached(vid: vid, info: resolved)
            return resolved
        }
        do {
            let resolved = try AppSource.parsePlayModel(model, vid: vid, inline: true)
            storeCached(vid: vid, info: resolved)
            return resolved
        } catch let error as AppSourceError {
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
                                          minimumPixels: error.minimumPixels, requireEncryptionMetadata: true, at: Date())
            let resolved = try await resolveFallback(pending, vid: vid, deadline: deadline)
            storeCached(vid: vid, info: resolved)
            return resolved
        }
    }

    private func resolveFallback(_ pending: PendingFallback, vid: String, deadline: Date) async throws -> PlayInfo {
        let outer = try await transport.requestJSON(pending.fallbackURL,
                                                    headers: [("User-Agent", AppSource.videoUA)],
                                                    deadline: deadline)
        for value in [outer, outer["video_info"]] where (value["Code"].number ?? value["code"].number ?? 0) != 0 {
            throw AppSourceError(.businessRejected, "App 接口暂未提供本集播放信息")
        }
        let info = outer["video_info"]["data"]
        if let expectedId = pending.videoId, let expectedDuration = pending.duration {
            let fallbackDuration = info["video_duration"].number ?? .nan
            guard info["video_id"].string == expectedId, fallbackDuration.isFinite, fallbackDuration > 0,
                  abs(fallbackDuration - expectedDuration) <= 0.5 else {
                throw AppSourceError(.invalidResponse, "备用片源编号或完整时长无法确认，已停止取址")
            }
        }
        return try AppSource.parsePlayModel(info, vid: vid, inline: false,
                                            requireEncryptionMetadata: pending.requireEncryptionMetadata,
                                            minimumPixels: pending.minimumPixels)
    }

    func requestModels(vids: [String], deadline: Date) async throws -> JSONValue {
        let payloadObject: [String: Any] = [
            "biz_param": ["detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
                          "disable_video_relate_book": false, "need_all_video_definition": true, "need_mp4_align": false,
                          "use_os_player": false, "use_server_dns": false, "video_platform": 1024],
            "mixed_video_id_map": ["1004": vids],
            "dr_scene": "player",
        ]
        let payload = Array(try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]))
        if let viaAccount = await requestModelsWithAccount(payload: payload, deadline: deadline) {
            return viaAccount
        }
        var obtained = try await getIdentity(forceFresh: false)
        try Task.checkCancellationAsApp()

        var response: JSONValue = .null
        for attempt in 0..<2 {
            try Task.checkCancellationAsApp()
            do {
                let signed = try await AppSource.shared.playbackRequest(payload: payload, identity: obtained.identity,
                                                                        modern: true, alternate: attempt == 1)
                do {
                    response = try await transport.requestJSON(signed.url, method: "POST", headers: signed.headers,
                                                               body: signed.body, deadline: deadline)
                } catch let error as AppSourceError where error.code == .emptyResponse && !obtained.reused && deadline.timeIntervalSinceNow >= 1 {
                    // Only retry the alternate host with the same identity when the identity is fresh;
                    // if a reused identity returned empty, skip straight to rotating it below.
                    let alternate = try await AppSource.shared.playbackRequest(payload: payload, identity: obtained.identity,
                                                                               modern: true, alternate: attempt == 0)
                    response = try await transport.requestJSON(alternate.url, method: "POST", headers: alternate.headers,
                                                               body: alternate.body, deadline: deadline)
                }
                if (response["Code"].number ?? response["code"].number ?? 0) != 0 {
                    throw AppSourceError(.businessRejected, "App 接口暂未提供本集播放信息")
                }
                break
            } catch let error as AppSourceError {
                if error.code == .cancelled { throw error }
                // Only rotate when the failing attempt used a cached identity; a fresh identity
                // already tried both hosts, so surfacing directly avoids stacking a second registration
                // inside the same call before PlayerEngine's immediate retry.
                let shouldRotate = attempt == 0 && obtained.reused
                if shouldRotate, deadline.timeIntervalSinceNow >= 2 {
                    obtained = try await getIdentity(forceFresh: true)
                    continue
                }
                if error.code == .emptyResponse || error.isHardRejection {
                    batchCooldownUntil = Date().addingTimeInterval(Self.batchCooldownSeconds)
                    identity = nil
                }
                throw error
            }
        }

        return Self.modelData(response)
    }

    private static func modelData(_ response: JSONValue) -> JSONValue {
        let data = response["data"]
        if !data["1004"].isNull { return data["1004"] }
        if !data["video_model_data"].isNull { return data["video_model_data"] }
        return data
    }

    /// After the signed-in path came back empty or refused, use the anonymous device only for a while.
    private var accountPlaybackPausedUntil = Date.distantPast

    /// When signed in: the same request with the account's registered device (the one account reads
    /// use) and the login cookie, as the official app sends it. nil when signed out, paused, or the
    /// reply was not usable; the caller then uses the anonymous playback device.
    private func requestModelsWithAccount(payload: [UInt8], deadline: Date) async -> JSONValue? {
        guard Date() >= accountPlaybackPausedUntil,
              let saved = try? KeychainCredentialStore().load(), !saved.cookie.isEmpty,
              let identity = try? await AppSearchIdentity.shared.get(transport: transport) else { return nil }
        do {
            let signed = try await AppSource.shared.playbackRequest(payload: payload, identity: identity, modern: true)
            let response = try await transport.requestJSON(signed.url, method: "POST",
                                                           headers: signed.headers + [("Cookie", saved.cookie)],
                                                           body: signed.body, deadline: deadline)
            guard (response["Code"].number ?? response["code"].number ?? 0) == 0 else {
                throw AppSourceError(.businessRejected, "App 接口暂未提供本集播放信息")
            }
            AccountDataAccess.onWriteLog?("play via account ok")
            return Self.modelData(response)
        } catch let error as AppSourceError where error.code == .cancelled {
            return nil
        } catch {
            AccountDataAccess.onWriteLog?("play via account failed: \((error as? AppSourceError)?.code.rawValue ?? "other")")
            accountPlaybackPausedUntil = Date().addingTimeInterval(120)
            return nil
        }
    }

    private func extractModel(from entry: JSONValue) -> JSONValue {
        if let text = entry["video_model"].string {
            return (try? JSONValue.parse(text)) ?? .null
        }
        return entry["video_model"]
    }

    private func ingestBatchEntry(_ entry: JSONValue, vid: String) {
        let model = extractModel(from: entry)
        guard model.object != nil else { return }
        let inline = !(model["video_list"].object?.isEmpty ?? true)
        if inline {
            do {
                let resolved = try AppSource.parsePlayModel(model, vid: vid, inline: true)
                storeCached(vid: vid, info: resolved)
                return
            } catch let error as AppSourceError {
                let duration = model["video_duration"].number ?? .nan
                if error.incompleteEncryptionMetadata,
                   let videoId = model["video_id"].string,
                   !videoId.trimmingCharacters(in: .whitespaces).isEmpty,
                   duration.isFinite, duration > 0,
                   error.minimumPixels > 0,
                   let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty {
                    storePendingFallback(vid: vid, PendingFallback(fallbackURL: fallback, videoId: videoId, duration: duration,
                                                                   minimumPixels: error.minimumPixels, requireEncryptionMetadata: true,
                                                                   at: Date()))
                }
                return
            } catch {
                return
            }
        }
        if let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty {
            storePendingFallback(vid: vid, PendingFallback(fallbackURL: fallback, videoId: nil, duration: nil,
                                                           minimumPixels: 0, requireEncryptionMetadata: false, at: Date()))
        }
    }

    private func storePendingFallback(vid: String, _ fallback: PendingFallback) {
        let now = Date()
        pendingFallbacks[vid] = fallback
        if pendingFallbacks.count > Self.maxCachedEntries {
            pendingFallbacks = pendingFallbacks.filter { now.timeIntervalSince($0.value.at) < Self.cacheLifetime }
            while pendingFallbacks.count > Self.maxCachedEntries,
                  let oldest = pendingFallbacks.min(by: { $0.value.at < $1.value.at })?.key {
                pendingFallbacks[oldest] = nil
            }
        }
    }

    private func storeCached(vid: String, info: PlayInfo) {
        cached[vid] = CachedPlayInfo(info: info, at: Date())
        pendingFallbacks[vid] = nil
        cacheOrder.removeAll { $0 == vid }
        cacheOrder.append(vid)
        while cacheOrder.count > Self.maxCachedEntries {
            let evicted = cacheOrder.removeFirst()
            cached[evicted] = nil
        }
    }
}

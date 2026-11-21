#if canImport(UIKit)
import AppLogic
import HongguoCore
import HongguoModels
import HongguoPlayback
import Observation
import SwiftUI

/// One series being watched in the player page: its episode list, which episode is on, the
/// sleep timer, and saving the position to the local history.
@MainActor
@Observable
public final class PlaybackSession {
    public let engine: PlayerEngine
    public let target: PlayerTarget

    public private(set) var series: DramaSeries?
    public private(set) var synopsis = ""
    /// Multi-season / same-IP series list (系列剧), loaded in the background when the series opens.
    public private(set) var sameIPSeries: DiscoveryAccess.SameIPSeriesResult?
    public private(set) var loadError: String?
    public private(set) var flow = FeedFlow()
    public private(set) var sleep = SleepTimer()
    /// Set when the sleep timer stopped playback, for a one-line notice.
    public private(set) var stoppedBySleepTimer = false
    public private(set) var danmaku: [DanmakuItem] = []

    @ObservationIgnored private let app: any PlayerHost
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var batchPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var skipTask: Task<Void, Never>?
    @ObservationIgnored private var danmakuKey = ""
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var offlineOnly = false

    public init(target: PlayerTarget, app: any PlayerHost) {
        self.target = target
        self.app = app
        engine = app.player
    }

    /// Takes the shared player's callbacks. Done when the page opens rather than in `init`:
    /// SwiftUI may create and discard several sessions for one page, and the last one created
    /// would otherwise leave the player calling back into a session that no longer exists,
    /// so nothing happened when an episode ended.
    private func takeEngine() {
        engine.activeOwner = self
        engine.rate = app.library.settings.rememberSpeed ? PlaybackRate.clamp(app.library.settings.playbackRate) : 1
        engine.onEnded = { [weak self] in self?.episodeEnded() }
        engine.onUnsupported = { [weak self] in self?.episodeUnsupported() }
    }

    /// The episode is only offered in an encoding iOS cannot decode: say so, and after a moment
    /// go on to the next one. The last episode just stays on the note.
    private func episodeUnsupported() {
        let number = episodeNumber
        guard hasNext else { return }
        skipTask?.cancel()
        skipTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !isClosed, episodeNumber == number, engine.phase == .unsupported else { return }
            if case .playEpisode(let next) = flow.skipUnplayable() { begin(episode: next, at: leftAt[next] ?? 0) }
        }
    }

    /// The series' episodes, once loaded (for 缓存 in the 选集 panel).
    public var episodes: [DramaEpisode] { series?.episodes ?? [] }
    public var title: String { series?.title.isEmpty == false ? series!.title : target.title }
    public var cover: String { series?.cover.isEmpty == false ? series!.cover : target.cover }
    public var total: Int { series?.total ?? 0 }
    public var episodeNumber: Int {
        if case .series(let episode, _) = flow.mode { return episode }
        return 1
    }
    public func episode(number: Int) -> DramaEpisode? {
        guard let series, !series.episodes.isEmpty else { return nil }
        return series.episodes.first(where: { $0.index == number }) ?? series.episodes[safe: number - 1]
    }

    private func isPlayable(_ ep: DramaEpisode) -> Bool {
        !ep.disabled && (!offlineOnly || ep.vid != "0")
    }

    private func nextPlayableEpisode(after number: Int) -> Int? {
        guard let series else { return nil }
        return series.episodes.first(where: { $0.index > number && isPlayable($0) })?.index
    }

    public var hasNext: Bool { nextPlayableEpisode(after: episodeNumber) != nil }
    public var currentEpisode: DramaEpisode? { episode(number: episodeNumber) }
    public var shareURL: URL { Site.detailURL(target.seriesId) }

    // MARK: Opening

    public func open() async {
        guard series == nil else { return }
        takeEngine()
        loadError = nil
        if !app.backend.isOffline {
            Task { await EpisodeResolver.shared.warmUpAppSource() }
        }
        // Continuing (no episode given, a history row, or feed watchFullSeries): read the account's
        // row for this series while the episode list loads, so a newer position from another device wins.
        let continues = (target.startEpisode == nil || target.resumeHintAt != nil || target.resumeIfAheadOfCurrentClip) && !app.backend.isOffline
        let account = app.account, lookupId = target.seriesId
        let accountToken = account.session.current
        async let freshRow = Self.freshAccountRow(account, seriesId: lookupId, enabled: continues)
        do {
            let loaded: DramaSeries
            var firstOfflineIndex: Int?
            do {
                loaded = try await app.backend.series(seriesId: target.seriesId)
                offlineOnly = false
            } catch {
                // No network: a series with downloaded episodes (离线缓存) opens on those. Episode
                // numbers stay as they are; one not downloaded has no address and cannot play.
                let offline = app.player.hooks.localFiles?.offlineEpisodes(seriesId: target.seriesId) ?? []
                guard let first = offline.first, let last = offline.last else { throw error }
                offlineOnly = true
                firstOfflineIndex = first.episodeIndex
                let byIndex = Dictionary(offline.map { ($0.episodeIndex, $0) }, uniquingKeysWith: { a, _ in a })
                loaded = DramaSeries(seriesId: target.seriesId, title: first.seriesTitle, cover: first.cover,
                                     episodes: (1...last.episodeIndex).map { number in
                                         let task = byIndex[number]
                                         return DramaEpisode(vid: task?.vid ?? "0", index: number,
                                                             title: task?.episodeTitle ?? "", disabled: task == nil)
                                     })
            }
            // The page may have been closed while the episode list was on its way.
            guard !isClosed else { return }
            guard !loaded.episodes.isEmpty else { throw HongguoError(.unavailable, "这部剧暂时没有可播放的分集") }
            series = loaded
            // What earlier visits left for this series' episodes.
            leftAt = app.library.episodePositions.positions(seriesId: target.seriesId)
            let row = await freshRow
            guard !isClosed else { return }
            if let row, let accountToken, account.session.accepts(accountToken) {
                app.library.store.mergeCloudHistory([row], accountId: accountToken.accountId)
            }
            var start = target.startEpisode ?? 1
            var position = target.startAt
            // This device's record (now including the fresh account row) wins over a history row's
            // hint when it is newer.
            let newerHere = target.resumeHintAt.map { hint in (app.library.store.record(for: target.seriesId)?.updatedAt ?? .distantPast) > hint } ?? false
            if target.resumeIfAheadOfCurrentClip {
                // Official rule: stay on the current feed clip unless history is ahead on a later episode.
                let resume = app.library.store.resumePoint(for: target.seriesId, episodeCount: loaded.total)
                if resume.episodeIndex > start {
                    start = resume.episodeIndex
                    position = resume.position
                }
            } else if target.startEpisode == nil || newerHere {
                let resume = app.library.store.resumePoint(for: target.seriesId, episodeCount: loaded.total)
                start = resume.episodeIndex
                position = resume.position
            }
            if offlineOnly, let firstOfflineIndex,
               let chosen = episode(number: start), !isPlayable(chosen) {
                start = firstOfflineIndex
                position = 0
            } else if let chosen = episode(number: start), !isPlayable(chosen),
                      let firstPlayable = loaded.episodes.first(where: { isPlayable($0) })?.index {
                start = firstPlayable
                position = 0
            }
            _ = try? app.library.seriesLibrary.recordOpened(seriesId: loaded.seriesId, title: title, cover: cover, episodeCount: loaded.total)
            if case .playEpisode(let episode) = flow.enterSeries(total: loaded.total, startEpisode: start) {
                begin(episode: episode, at: position)
            }
            if !app.backend.isOffline, !offlineOnly, start < loaded.total {
                let lower = start + 1
                let upper = min(loaded.total, start + 6)
                prefetchRange(lower...upper, delayMilliseconds: 300)
            }
            saveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.periodicTick() }
            }
            if !app.backend.isOffline {
                let seriesId = target.seriesId
                Task { [weak self] in
                    guard let result = try? await DiscoveryAccess.sameIPSeries(seriesId: seriesId) else { return }
                    guard let self, !self.isClosed, self.target.seriesId == seriesId else { return }
                    self.sameIPSeries = result
                }
            }
            synopsis = (try? await app.backend.synopsis(seriesId: target.seriesId)) ?? ""
        } catch {
            loadError = describeError(error)
        }
    }

    private nonisolated static func freshAccountRow(_ account: AccountModel, seriesId: String, enabled: Bool) async -> AccountHistoryItem? {
        guard enabled else { return nil }
        return await account.latestHistoryRow(seriesId: seriesId)
    }

    /// Conservatively batch-fetches play models for up to 6 episodes in `range` (debounced so
    /// fast tab switching does not spam requests).
    public func prefetchRange(_ range: ClosedRange<Int>, delayMilliseconds: Int = 300) {
        guard !app.backend.isOffline, !offlineOnly, series != nil else { return }
        let start = range.contains(episodeNumber) ? max(range.lowerBound, episodeNumber - 1) : range.lowerBound
        let end = min(range.upperBound, start + 5)
        let vids = (start...end).compactMap { number -> String? in
            guard let ep = episode(number: number), isPlayable(ep), ep.vid != "0" else { return nil }
            return ep.vid
        }
        guard !vids.isEmpty else { return }
        batchPrefetchTask?.cancel()
        batchPrefetchTask = Task {
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            await EpisodeResolver.shared.prefetchBatch(vids: vids)
        }
    }

    /// Where each episode was left during this visit, so going back to one carries on from
    /// there. An episode played to its end starts over.
    @ObservationIgnored private var leftAt: [Int: Double] = [:]

    private func rememberPosition(finished: Bool = false) {
        guard let episode = currentEpisode,
              engine.currentVid == episode.vid,
              engine.phase == .ready || engine.phase == .offline else { return }
        let nearEnd = engine.duration > 0 && engine.currentTime >= engine.duration - 3
        leftAt[episodeNumber] = finished || nearEnd ? nil : engine.currentTime
        // Kept across visits and launches too.
        app.library.rememberEpisode(seriesId: target.seriesId, episode: episodeNumber, position: leftAt[episodeNumber])
    }

    public func select(episode: Int) {
        if let chosen = self.episode(number: episode), !isPlayable(chosen) { return }
        rememberPosition()
        persist(forceSync: true)
        if case .playEpisode(let number) = flow.selectEpisode(episode) { begin(episode: number, at: leftAt[number] ?? 0) }
    }

    public func next() {
        guard let nextNumber = nextPlayableEpisode(after: episodeNumber) else { return }
        select(episode: nextNumber)
    }

    private func begin(episode number: Int, at position: Double) {
        guard let series, let episode = self.episode(number: number), isPlayable(episode) else { return }
        stoppedBySleepTimer = false
        danmaku = []
        danmakuKey = ""
        let atEOF = engine.duration > 0 && engine.currentTime >= engine.duration - 0.5 && !engine.isPlaying
        let alreadyOn = engine.currentVid == episode.vid && [.ready, .loading, .offline].contains(engine.phase)
        if alreadyOn && atEOF, let nextNumber = nextPlayableEpisode(after: number) {
            if case .playEpisode(let advanced) = flow.selectEpisode(nextNumber) {
                begin(episode: advanced, at: leftAt[advanced] ?? 0)
            }
            return
        }
        if alreadyOn {
            // Came in from the clip that is playing (观看完整剧集): same player, same position.
            engine.play()
            if !app.backend.isOffline, !offlineOnly { prefetchNext(after: number) }
        } else if app.backend.isOffline {
            engine.loadOffline(vid: episode.vid)
        } else {
            EpisodeResolver.shared.markForegroundTarget(vid: episode.vid, preferredShortSide: app.library.settings.preferredQuality)
            engine.load(vid: episode.vid, seriesId: series.seriesId, startAt: position,
                        preferredShortSide: app.library.settings.preferredQuality)
            if !offlineOnly { prefetchNext(after: number) }
        }
        loadDanmaku(for: episode)
    }

    /// Pre-renders N+1 and N-1 as soon as the current episode has its first frame (no 2s dead
    /// sleep), maintains a watermarked multi-vid batch cache ahead of playback, and only pulls
    /// the 5 MiB disk prefix once the foreground player has comfortable forward buffer.
    private func prefetchNext(after number: Int) {
        prefetchTask?.cancel()
        guard !offlineOnly, let series else { return }
        // The episode after this one first, then the one before (a swipe can go either way).
        let neighbours = [episode(number: number + 1), number >= 2 ? episode(number: number - 1) : nil]
            .compactMap { $0 }
            .filter { isPlayable($0) && $0.vid != "0" }
        guard !neighbours.isEmpty else { return }
        let preferred = app.library.settings.preferredQuality
        let engine = engine
        let resumePositions = leftAt
        prefetchTask = Task {
            // Start immediately once the active episode is showing video (cap at 400ms on cold loads).
            if !engine.hasFirstFrame {
                let deadline = Date().addingTimeInterval(0.4)
                while !engine.hasFirstFrame, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled else { return }
                }
            }
            var diskTargets: [PreparedEpisode] = []
            for episode in neighbours {
                guard !Task.isCancelled else { return }
                let resumeAt = resumePositions[episode.index] ?? 0
                if engine.hasWarmItem(vid: episode.vid, preferredShortSide: preferred) {
                    continue
                }
                var found: PreparedEpisode?
                do {
                    found = try await EpisodeResolver.shared.prepare(vid: episode.vid, seriesId: series.seriesId,
                                                                     preferredShortSide: preferred, prefetch: true)
                } catch {
                    PlaybackLog.note("prefetch failed vid=\(episode.vid.suffix(6)) \(PlaybackLog.brief(error))")
                }
                guard let prepared = found else { continue }
                guard !Task.isCancelled else { return }
                if prepared.info.isByteVC2 {
                    await engine.hooks.convertedStreams?.prepareAhead(prepared)
                    continue
                }
                // Pre-render frame #0 first so immediate swipe hits 0ms swap; the warmed loader
                // automatically consumes newly written disk prefix bytes afterward (Codex #1).
                await engine.warmUp(prepared, preferredShortSide: preferred, startAt: resumeAt)
                diskTargets.append(prepared)
            }

            // Run watermark batch prefetch after adjacent single lookups complete so single and
            // batch never cancel or skip each other inside `AuthenticatedPlaybackSource`.
            await ensureBatchPrefetchWatermark(around: number, preferredShortSide: preferred)
            guard !Task.isCancelled else { return }

            // Bandwidth-aware disk prefix fill: wait briefly until foreground playback has > 3s buffered.
            for prepared in diskTargets {
                guard !Task.isCancelled else { return }
                let bufferDeadline = Date().addingTimeInterval(2.5)
                while Date() < bufferDeadline {
                    let healthy = engine.phase == .ready &&
                        (engine.buffered - engine.currentTime > 3 || (engine.duration > 0 && engine.buffered >= engine.duration - 1))
                    if healthy { break }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                }
                guard !Task.isCancelled else { return }
                let healthy = engine.phase == .ready &&
                    (engine.buffered - engine.currentTime > 3 || (engine.duration > 0 && engine.buffered >= engine.duration - 1))
                if healthy {
                    await MediaPrefixCache.shared.prefetch(prepared)
                }
            }
        }
    }

    /// Triggers a single multi-vid batch lookup whenever fewer than 3 of the next 5 episodes
    /// already have an unexpired video model cached.
    private func ensureBatchPrefetchWatermark(around number: Int, preferredShortSide: Int?) async {
        guard !app.backend.isOffline, let series, number < series.total else { return }
        let upper = min(series.total, number + 5)
        let lookahead = (number + 1)...upper
        var cachedCount = 0
        for idx in lookahead {
            guard !Task.isCancelled else { return }
            guard let ep = series.episodes.first(where: { $0.index == idx }) ?? series.episodes[safe: idx - 1] else { continue }
            if await EpisodeResolver.shared.hasCachedSource(vid: ep.vid, preferredShortSide: preferredShortSide) {
                cachedCount += 1
            }
        }
        if cachedCount < 3 {
            let batchUpper = min(series.total, number + 6)
            prefetchRange((number + 1)...batchUpper, delayMilliseconds: 200)
        }
    }

    private func loadDanmaku(for episode: DramaEpisode) {
        guard app.library.settings.danmaku.enabled, let series else { return }
        let key = "\(series.seriesId):\(episode.vid)"
        danmakuKey = key
        Task {
            let items = await app.backend.danmaku(seriesId: series.seriesId, vid: episode.vid)
            if danmakuKey == key { danmaku = items }
        }
    }

    /// Called when the danmaku switch is turned on mid-episode.
    public func reloadDanmakuIfNeeded() {
        if danmaku.isEmpty, let episode = currentEpisode { loadDanmaku(for: episode) }
    }

    // MARK: Ending and timers

    private func episodeEnded() {
        rememberPosition(finished: true)
        persist(finished: true)
        if sleep.stopsAtEpisodeEnd() {
            stopForSleepTimer()
            return
        }
        if let nextNumber = nextPlayableEpisode(after: episodeNumber),
           case .playEpisode(let number) = flow.selectEpisode(nextNumber) {
            begin(episode: number, at: 0)
        } else {
            engine.pause()
        }
    }

    public func setSleepTimer(_ setting: SleepTimer.Setting) {
        sleep.set(setting)
        stoppedBySleepTimer = false
    }

    private func stopForSleepTimer() {
        engine.pause()
        sleep.set(.off)
        stoppedBySleepTimer = true
    }

    private func periodicTick() {
        if sleep.isDue() { stopForSleepTimer() }
        // Every five seconds while playing, so a killed app still knows where the episode was.
        if engine.isPlaying { rememberPosition(); persist() }
    }

    // MARK: History

    public func persist(finished: Bool = false, forceSync: Bool = false) {
        guard let series, let episode = currentEpisode,
              engine.currentVid == episode.vid,
              engine.phase == .ready || engine.phase == .offline else { return }
        // Opened and closed without watching: keep the old record, so it cannot beat (or overwrite
        // in the account) a newer position from another device.
        guard finished || engine.phase == .offline || engine.watch.shouldSave else { return }
        let pos = finished ? 0 : engine.currentTime
        app.library.store.savePosition(seriesId: series.seriesId, title: title, cover: cover, total: series.total,
                               episodeIndex: episode.index, vid: episode.vid,
                               position: pos, duration: engine.duration, finished: finished,
                               accountId: app.account.profile?.id)
        app.library.libraryChanged()
        app.library.syncWatchHistory(seriesId: series.seriesId, title: title, cover: cover, total: series.total,
                             vid: episode.vid, episodeIndex: episode.index, position: pos,
                             duration: engine.duration, finished: finished, force: forceSync || finished)
    }

    public func setRate(_ rate: Float) {
        engine.rate = rate
        if app.library.settings.rememberSpeed { app.library.settings.playbackRate = rate }
    }

    public func close() {
        guard !isClosed else { return }
        rememberPosition()
        persist(forceSync: true)
        isClosed = true
        saveTimer?.invalidate()
        prefetchTask?.cancel()
        batchPrefetchTask?.cancel()
        skipTask?.cancel()
        // Only touch the shared engine if this session still owns it (switching to another
        // series inside PlayerPage transfers ownership to the new session before onDisappear runs).
        guard engine.activeOwner === self else { return }
        engine.activeOwner = nil
        engine.onEnded = nil
        engine.onUnsupported = nil
        engine.endHoldSpeed()
        engine.rate = 1
        // Opened from the feed's clip: the feed carries on with whatever episode is on now, in
        // the same player, without a pause. Opened from anywhere else: stop here.
        if target.continuesCurrentClip, let episode = currentEpisode, engine.currentVid == episode.vid {
            app.playerHandoff = .init(seriesId: target.seriesId, episode: episodeNumber, vid: episode.vid)
        } else {
            app.playerHandoff = nil
            engine.pause()
        }
    }
}

extension Array {
    public subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif

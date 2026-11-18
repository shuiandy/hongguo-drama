import AVFoundation
import AppKit
import HongguoCore

/// How the current episode reaches AVPlayer.
enum PlaybackPipeline: String, Sendable {
    /// Plain media streamed through `StreamingResourceLoader`.
    case stream
    /// Encrypted media streamed and decrypted range by range (no full download first).
    case progressiveDecrypt
    /// Encrypted media downloaded and decrypted to a cache file before playback (fallback).
    case decryptedFile
    /// A downloaded episode played from disk.
    case localFile
}

/// Video scaling inside the player surface.
enum VideoFillMode: String, CaseIterable, Identifiable, Sendable {
    case fit, fill, stretch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "填充"
        case .stretch: return "拉伸"
        }
    }
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
}

/// The single app-wide player: episode queue, source resolution, progressive decryption,
/// auto-next, speed and position persistence. Views only read state and call the methods
/// in the "Public playback API" section; they never touch sources or the network.
@MainActor
@Observable
final class PlayerController {
    static let shared = PlayerController()

    /// Speed choices offered by menus.
    static let rateOptions: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    let player = AVPlayer()

    // MARK: Observable state

    private(set) var episodes: SeriesEpisodes?
    private(set) var cover = ""
    /// 1-based index of the current episode.
    private(set) var index = 0
    private(set) var isLoading = false
    private(set) var loadingText = ""
    private(set) var errorMessage: String?
    private(set) var isPlaying = false
    /// Playing is requested but AVPlayer is waiting for data.
    private(set) var isBuffering = false
    private(set) var videoSize = CGSize(width: 9, height: 16)
    private(set) var currentSource: PlaySource?
    private(set) var pipeline: PlaybackPipeline?
    /// Seconds, refreshed 4 times per second.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// End of the loaded range that contains the playhead, in seconds.
    private(set) var bufferedTime: Double = 0
    /// Milliseconds from episode request to `readyToPlay` (diagnostics).
    private(set) var startupMilliseconds: Int?
    /// Short message shown over the video (speed changes, auto-next toggles).
    private(set) var toast: String?
    /// Resolution tiers of the current episode, highest first. Empty when the source has one stream (web).
    private(set) var qualityOptions: [QualityOption] = []
    /// Tier actually playing; nil when unknown (web, local files).
    private(set) var currentQuality: QualityOption?

    private var storedRate: Float = 1.0
    var rate: Float {
        get { storedRate }
        set {
            storedRate = max(0.25, min(4, newValue))
            if isPlaying, !holdingSpeed { player.rate = storedRate }
            if AppModel.shared.settings.rememberSpeed { AppModel.shared.settings.playbackRate = storedRate }
        }
    }
    private var storedVolume: Float = 1.0
    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = max(0, min(1, newValue))
            player.volume = storedVolume
            AppModel.shared.settings.volume = storedVolume
        }
    }
    private var storedMuted = false
    var isMuted: Bool {
        get { storedMuted }
        set { storedMuted = newValue; player.isMuted = newValue }
    }
    /// Views apply `fillMode.gravity` to their AVPlayerView / AVPlayerLayer.
    var fillMode: VideoFillMode = .fit
    /// Preferred tier (`QualityOption.id`, the short side in px); nil = automatic best.
    /// Persisted. Setting it switches the current episode at the same position without re-resolving.
    var preferredQuality: QualityOption.ID? {
        get { storedPreferredQuality }
        set {
            guard newValue != storedPreferredQuality else { return }
            storedPreferredQuality = newValue
            AppModel.shared.settings.preferredQuality = newValue
            preparedMaps.removeAll()
            guard let info = currentInfo, !info.variants.isEmpty else { return }
            let resumeAt = player.currentTime().seconds.isFinite ? player.currentTime().seconds : currentTime
            guard let newValue else {
                // Automatic: resolve again so the source's default tier is used.
                show(toast: "画质：自动")
                load(startAt: resumeAt, force: false)
                return
            }
            let target = info.selecting(shortSide: newValue)
            guard target.url != info.url else { return }
            show(toast: "画质：\(target.quality?.label ?? "自动")")
            load(startAt: resumeAt, force: false, resolved: target)
        }
    }
    private var storedPreferredQuality: Int?
    var autoNext: Bool {
        get { AppModel.shared.settings.autoNext }
        set { AppModel.shared.settings.autoNext = newValue }
    }

    /// Optional hook for the download manager: return a local file for an episode to play it from disk.
    @ObservationIgnored var localFileProvider: ((Episode) -> URL?)?

    @ObservationIgnored private var loader: StreamingResourceLoader?
    @ObservationIgnored private var currentInfo: PlayInfo?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var retriedWithoutWeb = false
    @ObservationIgnored private var retriedWithFile = false
    @ObservationIgnored private var retriedFresh = false
    @ObservationIgnored private var usedPrefetched = false
    /// Source of the next episode resolved while the current one plays (all tiers), so auto-next
    /// does not wait for the signed App request (3 to 5 s).
    @ObservationIgnored private var prefetched: (vid: String, info: PlayInfo, at: Date)?
    /// Signed media URLs stay valid far longer; a stale one is re-resolved on failure anyway.
    private static let prefetchLifetime: TimeInterval = 15 * 60
    @ObservationIgnored private var holdingSpeed = false
    @ObservationIgnored private var loadStarted = Date()
    /// Header maps prepared ahead of time for the next episode, keyed by `mapKey`.
    @ObservationIgnored private var preparedMaps: [String: CencStreamMap] = [:]

    var currentEpisode: Episode? {
        guard let episodes, index >= 1, index <= episodes.episodes.count else { return nil }
        return episodes.episodes[index - 1]
    }

    var title: String {
        guard let episodes else { return "红果短剧" }
        return "\(episodes.title) · 第 \(index) 集"
    }

    var hasNext: Bool { (episodes?.episodes.count ?? 0) > index }
    var hasPrevious: Bool { index > 1 }
    var hasItem: Bool { player.currentItem != nil }

    private init() {
        let settings = AppModel.shared.settings
        storedRate = settings.rememberSpeed ? max(0.25, min(4, settings.playbackRate)) : 1
        storedVolume = max(0, min(1, settings.volume))
        storedPreferredQuality = settings.preferredQuality
        player.volume = storedVolume
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                self?.isPlaying = status != .paused
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        })
        // Volume changed from AVPlayerView's own slider.
        observations.append(player.observe(\.volume, options: [.new]) { [weak self] player, _ in
            let value = player.volume
            Task { @MainActor in
                guard let self, abs(self.storedVolume - value) > 0.001 else { return }
                self.storedVolume = value
                AppModel.shared.settings.volume = value
            }
        })
        observations.append(player.observe(\.isMuted, options: [.new]) { [weak self] player, _ in
            let muted = player.isMuted
            Task { @MainActor in if self?.storedMuted != muted { self?.storedMuted = muted } }
        })
    }

    // MARK: Opening

    /// Opens a series by id (history, context menus). Loads the episode list first.
    func open(seriesId: String, title: String, cover: String, index: Int = 1, startAt: Double = 0) async {
        PlayerWindows.shared.showPlayer()
        isLoading = true
        loadingText = "正在加载《\(title)》分集…"
        errorMessage = nil
        do {
            let list = try await SourceRouter.episodes(seriesId: seriesId)
            open(episodes: list, cover: cover, index: index, startAt: startAt)
        } catch {
            isLoading = false
            errorMessage = describe(error)
        }
    }

    func open(episodes list: SeriesEpisodes, cover: String, index: Int, startAt: Double = 0) {
        persistPosition()
        if episodes?.seriesId != list.seriesId {
            preparedMaps.removeAll()
            prefetched = nil
            // Per-series picture mode, else the default from settings; 打开播放器时的音量.
            let settings = AppModel.shared.settings
            fillMode = settings.pictureMode(for: list.seriesId) == .width ? .fill : .fit
            if let start = settings.startVolume { volume = Float(start) / 100 }
        }
        episodes = list
        self.cover = cover.isEmpty ? list.cover : cover
        PlayerWindows.shared.showPlayer()
        play(index: index, startAt: startAt)
    }

    func play(index target: Int, startAt: Double = 0, force: Bool = false) {
        guard let list = episodes, target >= 1, target <= list.episodes.count else { return }
        if target != index { persistPosition() }
        index = target
        retriedWithoutWeb = false
        retriedWithFile = false
        retriedFresh = false
        load(startAt: startAt, force: force)
    }

    /// `resolved` replays an already resolved source (quality switch, decrypt fallback) without a new request.
    private func load(startAt: Double, force: Bool, preferFile: Bool = false, resolved: PlayInfo? = nil) {
        guard let episode = currentEpisode, let list = episodes else { return }
        loadTask?.cancel()
        loader?.cancelAll()
        player.pause()
        isLoading = true
        errorMessage = nil
        startupMilliseconds = nil
        loadStarted = Date()
        currentTime = max(0, startAt)
        duration = 0
        bufferedTime = 0

        if !force, let file = localFileProvider?(episode), FileManager.default.isReadableFile(atPath: file.path) {
            loader = nil
            pipeline = .localFile
            currentSource = nil
            currentInfo = nil
            qualityOptions = []
            currentQuality = nil
            start(item: AVPlayerItem(url: file), info: nil, startAt: startAt)
            return
        }

        loadingText = resolved == nil ? "正在获取第 \(episode.index) 集片源…" : "正在切换…"
        let preferred = storedPreferredQuality
        let maps = preparedMaps
        var ready = resolved
        usedPrefetched = false
        if ready == nil, !force, let p = prefetched, p.vid == episode.vid, Date().timeIntervalSince(p.at) < Self.prefetchLifetime {
            ready = p.info.selecting(shortSide: preferred)
            usedPrefetched = true
        }
        loadTask = Task { [weak self] in
            do {
                var info: PlayInfo
                if let ready {
                    info = ready
                } else {
                    info = try await SourceRouter.playInfo(vid: episode.vid, seriesId: list.seriesId, force: force)
                        .selecting(shortSide: preferred)
                }
                try Task.checkCancellation()
                try await URLGuard.check(info.url)
                let prepared = maps[Self.mapKey(info)]
                let (item, pipeline, streaming) = try await Self.makeItem(for: info, episode: episode, prepared: force ? nil : prepared,
                                                                          preferFile: preferFile) { text in
                    Task { @MainActor in self?.loadingText = text }
                }
                try Task.checkCancellation()
                streaming?.onMediaFailure = { message in
                    Task { @MainActor in self?.mediaFailed(message) }
                }
                guard let self else { return }
                self.loader = streaming
                self.pipeline = pipeline
                self.qualityOptions = info.qualityOptions
                self.currentQuality = info.quality
                self.start(item: item, info: info, startAt: startAt)
            } catch is CancellationError {
            } catch let error as HongguoError where error.kind == .cancelled {
            } catch {
                self?.isLoading = false
                self?.errorMessage = describe(error)
            }
        }
    }

    /// Chooses the pipeline: cached decrypted file > progressive decrypt > full decrypt; plain media streams.
    private nonisolated static func makeItem(for info: PlayInfo, episode: Episode, prepared: CencStreamMap?, preferFile: Bool,
                                             progress: @escaping @Sendable (String) -> Void) async throws
        -> (AVPlayerItem, PlaybackPipeline, StreamingResourceLoader?) {
        guard info.needsLocalFile else {
            let streaming = StreamingResourceLoader(source: info.url, headers: info.httpHeaders)
            return (AVPlayerItem(asset: streaming.makeAsset()), .stream, streaming)
        }
        if let file = PlaybackCache.shared.cachedFile(for: info) {
            return (AVPlayerItem(url: file), .decryptedFile, nil)
        }
        if info.isByteVC2 {
            // ByteVC2 兼容转换: download the whole episode, then decode it to H.264 locally.
            progress("正在下载第 \(episode.index) 集，随后进行 ByteVC2 兼容转换…")
            let file = try await PlaybackCache.shared.prepare(info, progress: progress)
            try Task.checkCancellation()
            return (AVPlayerItem(url: file), .decryptedFile, nil)
        }
        if !preferFile {
            do {
                let map: CencStreamMap
                if let prepared, prepared.inputLength > 0 { map = prepared } else { map = try await CencStreamLoader.open(info) }
                try Task.checkCancellation()
                let streaming = StreamingResourceLoader(source: info.url, headers: info.httpHeaders, map: map)
                return (AVPlayerItem(asset: streaming.makeAsset()), .progressiveDecrypt, streaming)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Unsupported layout or no range support: fall through to the full download.
            }
        }
        progress("正在下载并解密第 \(episode.index) 集…")
        let file = try await PlaybackCache.shared.prepare(info)
        try Task.checkCancellation()
        return (AVPlayerItem(url: file), .decryptedFile, nil)
    }

    private func start(item: AVPlayerItem, info: PlayInfo?, startAt: Double) {
        currentInfo = info
        currentSource = info?.source
        item.preferredForwardBufferDuration = 20
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.episodeEnded() }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error.map(describeError)
            let size = item.presentationSize
            Task { @MainActor in self?.itemStatusChanged(status, error: message, size: size) }
        }
        player.replaceCurrentItem(with: item)
        if startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.playImmediately(atRate: rate)
        prefetchNext()
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?, size: CGSize) {
        switch status {
        case .readyToPlay:
            isLoading = false
            if startupMilliseconds == nil { startupMilliseconds = Int(Date().timeIntervalSince(loadStarted) * 1000) }
            if size.width > 0, size.height > 0 {
                videoSize = size
                PlayerWindows.shared.videoSizeChanged(size)
            }
        case .failed:
            mediaFailed(error ?? "无法播放此片源")
        default:
            break
        }
    }

    /// Recovery: a failed web URL is penalised and re-resolved once; a failed progressive
    /// stream falls back once to the full download-and-decrypt path.
    private func mediaFailed(_ message: String) {
        let resumeAt = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        if let info = currentInfo, info.source == .web, !retriedWithoutWeb {
            retriedWithoutWeb = true
            let service = AppModel.shared.series
            Task {
                await service.markWebMediaFailure(info)
                self.load(startAt: resumeAt, force: true)
            }
            return
        }
        if usedPrefetched, !retriedFresh {
            // The prefetched signed URL may have expired: resolve this episode again once.
            retriedFresh = true
            prefetched = nil
            load(startAt: resumeAt, force: true)
            return
        }
        if pipeline == .progressiveDecrypt, !retriedWithFile {
            retriedWithFile = true
            load(startAt: resumeAt, force: false, preferFile: true, resolved: currentInfo)
            return
        }
        isLoading = false
        errorMessage = "播放失败：\(message)"
    }

    /// Resolves the next episode's source and, if encrypted, its header map, so it starts instantly.
    private func prefetchNext() {
        guard let list = episodes, hasNext else { return }
        let next = list.episodes[index]
        if localFileProvider?(next) != nil { return }
        let preferred = storedPreferredQuality
        if let p = prefetched, p.vid == next.vid, Date().timeIntervalSince(p.at) < Self.prefetchLifetime / 2,
           preparedMaps[Self.mapKey(p.info.selecting(shortSide: preferred))] != nil || !p.info.isEncrypted {
            return
        }
        Task { [weak self] in
            guard let raw = try? await SourceRouter.playInfo(vid: next.vid, seriesId: list.seriesId) else { return }
            guard let self, self.episodes?.seriesId == list.seriesId else { return }
            self.prefetched = (next.vid, raw, Date())
            let info = raw.selecting(shortSide: preferred)
            guard info.needsLocalFile, PlaybackCache.shared.cachedFile(for: info) == nil else { return }
            if !info.isByteVC2, let map = try? await CencStreamLoader.open(info),
               self.episodes?.seriesId == list.seriesId, self.storedPreferredQuality == preferred {
                self.preparedMaps = [Self.mapKey(info): map]
            }
            // "播放时预先准备下一集": download and decrypt the whole next episode in the background,
            // after a short pause so the current episode gets the bandwidth first. The next
            // episode then starts from the local file at once.
            guard AppModel.shared.settings.cacheNextEpisode else { return }
            try? await Task.sleep(for: .seconds(8))
            guard self.episodes?.seriesId == list.seriesId, self.storedPreferredQuality == preferred,
                  self.hasNext, self.episodes?.episodes[self.index].vid == next.vid else { return }
            _ = try? await PlaybackCache.shared.prepare(info)
        }
    }

    /// Header maps depend on the file, i.e. episode and tier, not on the signed URL.
    private nonisolated static func mapKey(_ info: PlayInfo) -> String {
        "\(info.vid):\(info.quality?.shortSide ?? 0)"
    }

    private func episodeEnded() {
        persistPosition(finished: true)
        if autoNext, hasNext {
            play(index: index + 1)
        }
    }

    // MARK: Public playback API

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if player.timeControlStatus == .paused {
            player.playImmediately(atRate: rate)
        } else {
            player.pause()
            persistPosition()
        }
    }

    func playIfPaused() { if player.currentItem != nil, player.timeControlStatus == .paused { player.playImmediately(atRate: rate) } }
    func pause() { player.pause(); persistPosition() }

    func next() { if hasNext { play(index: index + 1) } }
    func previous() { if hasPrevious { play(index: index - 1) } }

    func retry() {
        load(startAt: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0, force: true)
    }

    /// Absolute seek, clamped to the item.
    func seek(to seconds: Double, precise: Bool = false) {
        guard player.currentItem != nil else { return }
        var target = max(0, seconds)
        if duration > 0 { target = min(target, max(0, duration - 0.25)) }
        currentTime = target
        let time = CMTime(seconds: target, preferredTimescale: 600)
        if precise {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: time)
        }
    }

    func seek(by seconds: Double) {
        seek(to: player.currentTime().seconds + seconds)
    }

    /// Seek to a fraction (0...1) of the episode, for timeline scrubbing.
    func seek(fraction: Double) {
        guard duration > 0 else { return }
        seek(to: duration * max(0, min(1, fraction)), precise: true)
    }

    func stepFrame(forward: Bool) {
        player.pause()
        player.currentItem?.step(byCount: forward ? 1 : -1)
    }

    func changeRate(by delta: Float) {
        let value = ((rate + delta) * 100).rounded() / 100
        rate = value
        show(toast: formatRate(rate))
    }

    func changeVolume(by delta: Float) {
        volume += delta
        if isMuted, delta > 0 { isMuted = false }
        show(toast: "音量 \(Int((volume * 100).rounded()))%")
    }

    func toggleMute() {
        isMuted.toggle()
        show(toast: isMuted ? "已静音" : "音量 \(Int((volume * 100).rounded()))%")
    }

    func cycleFillMode() {
        let all = VideoFillMode.allCases
        setFillMode(all[(all.firstIndex(of: fillMode)! + 1) % all.count])
        show(toast: "画面：\(fillMode.label)")
    }

    /// Changes the picture mode and remembers 适应 / 填充 for the current series (拉伸 is not remembered).
    func setFillMode(_ mode: VideoFillMode) {
        fillMode = mode
        guard let seriesId = episodes?.seriesId else { return }
        switch mode {
        case .fit: AppModel.shared.settings.pictureModes[seriesId] = .fit
        case .fill: AppModel.shared.settings.pictureModes[seriesId] = .width
        case .stretch: break
        }
    }

    func toggleDanmaku() {
        AppModel.shared.settings.danmaku.enabled.toggle()
        show(toast: AppModel.shared.settings.danmaku.enabled ? "弹幕：开" : "弹幕：关")
    }

    func toggleAutoNext() {
        autoNext.toggle()
        show(toast: autoNext ? "自动连播：开" : "自动连播：关")
    }

    /// Long-press speed boost. Does not change the remembered rate.
    func beginHoldSpeed() {
        guard !holdingSpeed, player.currentItem != nil else { return }
        holdingSpeed = true
        player.playImmediately(atRate: 2)
        show(toast: "2x 快进中")
    }

    func endHoldSpeed() {
        guard holdingSpeed else { return }
        holdingSpeed = false
        player.rate = rate
        toast = nil
    }

    func show(toast text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }

    func stop() {
        persistPosition()
        loadTask?.cancel()
        loader?.cancelAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        pipeline = nil
    }

    // MARK: Time & persistence

    private func tick() {
        if let item = player.currentItem {
            let now = player.currentTime().seconds
            if now.isFinite { currentTime = now }
            let total = item.duration.seconds
            if total.isFinite, total > 0 { duration = total }
            let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
            if let range = ranges.first(where: { $0.containsTime(player.currentTime()) }) ?? ranges.last {
                let end = range.end.seconds
                if end.isFinite { bufferedTime = end }
            }
        }
        if Date().timeIntervalSince(lastSaved) >= 5, isPlaying { persistPosition() }
    }

    func persistPosition(finished: Bool = false) {
        guard let list = episodes, let episode = currentEpisode, player.currentItem != nil else { return }
        lastSaved = Date()
        let position = finished ? 0 : player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        AppModel.shared.store.savePosition(seriesId: list.seriesId, title: list.title, cover: cover, total: list.total,
                                           episodeIndex: episode.index, vid: episode.vid,
                                           position: position.isFinite ? position : 0,
                                           duration: duration.isFinite ? duration : 0, finished: finished)
        AppModel.shared.refreshHistory()
    }
}

func formatRate(_ rate: Float) -> String {
    var text = String(format: "%.2f", rate)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text + "x"
}

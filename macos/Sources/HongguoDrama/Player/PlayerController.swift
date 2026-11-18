import AVFoundation
import AppKit
import HongguoCore

/// The single app-wide player: episode queue, source resolution, auto-next, speed and
/// position persistence. Windows (main player, mini panel, PiP) only render `player`.
@MainActor
@Observable
final class PlayerController {
    static let shared = PlayerController()

    let player = AVPlayer()

    private(set) var episodes: SeriesEpisodes?
    private(set) var cover = ""
    /// 1-based index of the current episode.
    private(set) var index = 0
    private(set) var isLoading = false
    private(set) var loadingText = ""
    private(set) var errorMessage: String?
    private(set) var isPlaying = false
    private(set) var videoSize = CGSize(width: 9, height: 16)
    private(set) var currentSource: PlaySource?
    private var storedRate: Float = 1.0
    var rate: Float {
        get { storedRate }
        set {
            storedRate = newValue
            if isPlaying, !holdingSpeed { player.rate = newValue }
            if AppModel.shared.settings.rememberSpeed { AppModel.shared.settings.playbackRate = newValue }
        }
    }
    var autoNext: Bool {
        get { AppModel.shared.settings.autoNext }
        set { AppModel.shared.settings.autoNext = newValue }
    }
    /// Short message shown over the video (speed changes, auto-next toggles).
    private(set) var toast: String?

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
    @ObservationIgnored private var holdingSpeed = false

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

    private init() {
        let settings = AppModel.shared.settings
        storedRate = settings.rememberSpeed ? max(0.25, min(4, settings.playbackRate)) : 1
        player.volume = settings.volume
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        })
        observations.append(player.observe(\.volume, options: [.new]) { player, _ in
            let volume = player.volume
            Task { @MainActor in AppModel.shared.settings.volume = volume }
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
            let list = try await AppModel.shared.series.episodes(seriesId: seriesId)
            open(episodes: list, cover: cover, index: index, startAt: startAt)
        } catch {
            isLoading = false
            errorMessage = describe(error)
        }
    }

    func open(episodes list: SeriesEpisodes, cover: String, index: Int, startAt: Double = 0) {
        persistPosition()
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
        load(startAt: startAt, force: force)
    }

    private func load(startAt: Double, force: Bool) {
        guard let episode = currentEpisode, let list = episodes else { return }
        loadTask?.cancel()
        loader?.cancelAll()
        player.pause()
        isLoading = true
        errorMessage = nil
        loadingText = "正在获取第 \(episode.index) 集片源…"
        let service = AppModel.shared.series
        loadTask = Task { [weak self] in
            do {
                let info = try await service.playInfo(vid: episode.vid, seriesId: list.seriesId, force: force)
                try Task.checkCancellation()
                try await URLGuard.check(info.url)
                let item: AVPlayerItem
                if info.isEncrypted {
                    await MainActor.run { self?.loadingText = "正在下载并解密第 \(episode.index) 集…" }
                    let file = try await PlaybackCache.shared.prepare(info)
                    try Task.checkCancellation()
                    item = AVPlayerItem(url: file)
                    await MainActor.run { self?.loader = nil }
                } else {
                    let streaming = StreamingResourceLoader(source: info.url, headers: info.httpHeaders)
                    streaming.onMediaFailure = { message in
                        Task { @MainActor in self?.mediaFailed(message) }
                    }
                    item = AVPlayerItem(asset: streaming.makeAsset())
                    await MainActor.run { self?.loader = streaming }
                }
                try Task.checkCancellation()
                await MainActor.run { self?.start(item: item, info: info, startAt: startAt) }
            } catch is CancellationError {
            } catch let error as HongguoError where error.kind == .cancelled {
            } catch {
                await MainActor.run {
                    self?.isLoading = false
                    self?.errorMessage = describe(error)
                }
            }
        }
    }

    private func start(item: AVPlayerItem, info: PlayInfo, startAt: Double) {
        currentInfo = info
        currentSource = info.source
        item.preferredForwardBufferDuration = 15
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

    /// A web media URL failed: penalise the web source and retry once with the fallback order.
    private func mediaFailed(_ message: String) {
        if let info = currentInfo, info.source == .web, !retriedWithoutWeb {
            retriedWithoutWeb = true
            let service = AppModel.shared.series
            Task {
                await service.markWebMediaFailure(info)
                self.load(startAt: self.player.currentTime().seconds, force: true)
            }
            return
        }
        isLoading = false
        errorMessage = "播放失败：\(message)"
    }

    private func prefetchNext() {
        guard let list = episodes, hasNext else { return }
        let next = list.episodes[index]
        let service = AppModel.shared.series
        Task.detached(priority: .utility) {
            _ = try? await service.playInfo(vid: next.vid, seriesId: list.seriesId)
        }
    }

    private func episodeEnded() {
        persistPosition(finished: true)
        if autoNext, hasNext {
            play(index: index + 1)
        }
    }

    // MARK: Controls

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if player.timeControlStatus == .paused {
            player.playImmediately(atRate: rate)
        } else {
            player.pause()
            persistPosition()
        }
    }

    func next() { if hasNext { play(index: index + 1) } }
    func previous() { if hasPrevious { play(index: index - 1) } }

    func retry() {
        load(startAt: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0, force: true)
    }

    func seek(by seconds: Double) {
        guard let item = player.currentItem else { return }
        let duration = item.duration.seconds
        var target = player.currentTime().seconds + seconds
        if duration.isFinite { target = min(target, max(0, duration - 0.5)) }
        player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600))
    }

    func changeRate(by delta: Float) {
        let value = ((rate + delta) * 100).rounded() / 100
        rate = max(0.25, min(4, value))
        show(toast: formatRate(rate))
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
    }

    // MARK: Persistence

    private func tick() {
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

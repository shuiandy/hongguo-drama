#if canImport(UIKit)
import UIKit
import AVFoundation
import AVKit
import AppLogic
import CoreImage
import HongguoCore
import HongguoPlayback
import Observation

/// One AVPlayer and what the UI shows about it. It plays a single episode at a time; which
/// episode comes next is decided by `PlaybackSession` or the feed.
@MainActor
@Observable
public final class PlayerEngine: NSObject {
    public enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
        /// ByteVC2 only: 此剧集暂不支持.
        case unsupported
        /// Offline sample data: no media, but the controls are live for screenshots.
        case offline
    }

    @ObservationIgnored public private(set) var player = AVPlayer()
    /// The active view that shows this player's video; `VideoSurface` slots borrow it.
    /// Swapped atomically with a pre-rendered standby `PlayerLayerView` when switching episodes.
    @ObservationIgnored public private(set) var layerView = PlayerLayerView()
    @ObservationIgnored private weak var prerenderHost: UIView?
    @ObservationIgnored private lazy var stillContext = CIContext(options: [.cacheIntermediates: false])

    /// Called only when leaving a feed card, immediately before its item is removed.
    public func departingFrame() -> CGImage? {
        guard hasFirstFrame, player.currentItem != nil, !isPictureInPictureActive,
              layerView.playerLayer.isReadyForDisplay else { return nil }
        player.pause()
        guard let buffer = layerView.playerLayer.displayedPixelBuffer() else { return nil }
        let source = CIImage(cvPixelBuffer: buffer, options: [.applyOrientationProperty: true])
        let factor = min(1, 960 / max(source.extent.width, source.extent.height))
        let still = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return stillContext.createCGImage(still, from: still.extent)
    }
    /// Bumped to make the visible `VideoSurface` take the layer view back.
    public private(set) var surfaceEpoch = 0
    /// The picture at the position being scrubbed to, when one could be read from the item.
    public private(set) var scrubImage: CGImage?
    @ObservationIgnored private var thumbnailer: AVAssetImageGenerator?
    @ObservationIgnored private weak var thumbnailerItem: AVPlayerItem?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailWanted: Double?

    /// Asks for the frame near `seconds` of the item that is playing. Requests made while one
    /// is being read collapse into the latest. Reading goes through the same loader as
    /// playback, so an encrypted episode is decrypted for the frame like for playing.
    public func requestScrubImage(at seconds: Double) {
        guard let item = player.currentItem else { return }
        if thumbnailerItem !== item {
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            thumbnailer = generator
            thumbnailerItem = item
            scrubImage = nil
        }
        thumbnailWanted = seconds
        guard thumbnailTask == nil, let generator = thumbnailer else { return }
        thumbnailTask = Task { [weak self] in
            while let self, let wanted = self.thumbnailWanted {
                self.thumbnailWanted = nil
                let image = try? await generator.image(at: CMTime(seconds: wanted, preferredTimescale: 600)).image
                if Task.isCancelled { break }
                if let image { self.scrubImage = image }
            }
            self?.thumbnailTask = nil
        }
    }

    public func endScrubImage() {
        thumbnailWanted = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailer?.cancelAllCGImageGeneration()
        scrubImage = nil
    }

    /// Every slot currently in a view tree (see `VideoSurface`).
    @ObservationIgnored public let surfaceSlots = NSHashTable<UIView>.weakObjects()

    public private(set) var phase: Phase = .idle
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    /// Whether the loaded episode was really watched (or the viewer moved the playhead). Saving a
    /// position that was only opened would claim "watched last" over other devices.
    @ObservationIgnored public private(set) var watch = WatchProgress()
    public private(set) var buffered: Double = 0
    public private(set) var videoSize: CGSize = .zero
    public private(set) var hasFirstFrame = false
    public private(set) var qualityOptions: [QualityOption] = []
    public private(set) var currentQuality: QualityOption?
    public private(set) var route: PlaybackRoute?
    public private(set) var isHoldingSpeed = false
    /// A line under the spinner while an episode is being converted before it can play.
    public private(set) var loadingNote: String?
    /// The rate while the screen is held (or the hold is locked): 1.5, 2 or 3.
    public private(set) var holdRate: Float = PlaybackRate.holdRate
    public private(set) var isPictureInPictureActive = false
    public private(set) var isExternalPlaybackActive = false
    public private(set) var externalPlaybackDeviceName = ""
    public private(set) var isCastStreamActive = false
    public private(set) var currentVid: String?

    public var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if wantsPlayback, !isHoldingSpeed, phase != .offline, player.currentItem != nil {
                player.rate = rate
            }
        }
    }
    /// Current controller owning `onEnded`/`onUnsupported` callbacks (guards stale `close()` calls).
    @ObservationIgnored weak var activeOwner: AnyObject?
    /// Exact ByteVC2 conversion key active for this player so `teardownItem` never cancels a newer job.
    @ObservationIgnored private var activeConvertedKey: String?
    /// 画幅. `.fit` shows the whole picture, with black bars where the screen's shape differs.
    /// `.fill` covers the screen and crops. `.automatic` fills when the video and the space it
    /// is shown in have the same orientation (a portrait clip on a portrait screen), and fits
    /// otherwise.
    public enum PictureFit: String, CaseIterable, Sendable {
        case automatic, fit, fill
        public var label: String {
            switch self {
            case .automatic: return "自动"
            case .fit: return "完整（留黑边）"
            case .fill: return "铺满（裁剪）"
            }
        }

        /// The viewer's choice is kept across launches. Until one is made the whole picture is
        /// shown: the outer display is wider than 9:16, and filling it cuts the top and bottom
        /// off every upright clip.
        private static let key = "pictureFit"
        public static var saved: PictureFit {
            get { UserDefaults.standard.string(forKey: key).flatMap(PictureFit.init(rawValue:)) ?? .fit }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }
    public var pictureFit: PictureFit = PictureFit.saved {
        didSet { if pictureFit != oldValue { PictureFit.saved = pictureFit } }
    }
    public var isMuted = false {
        didSet {
            player.isMuted = isMuted
            if let item = player.currentItem {
                for track in item.tracks where track.assetTrack?.mediaType == .audio {
                    track.isEnabled = !isMuted
                }
            }
        }
    }
    /// The user (or a sleep timer) wants playback; false after an explicit pause.
    public private(set) var wantsPlayback = true

    @ObservationIgnored public var onEnded: (() -> Void)?
    @ObservationIgnored public var onUnsupported: (() -> Void)?

    public var isLandscapeVideo: Bool { videoSize.width > videoSize.height && videoSize.height > 0 }
    public var isLoading: Bool { phase == .loading }

    @ObservationIgnored private var generation = 0 {
        didSet {
            if castPublication !== installedCast { castPublication?.cancel() }
            castPublication = nil
            clearSeekFrameObservation()
            pendingSeekToken = nil
        }
    }
    @ObservationIgnored private var castPublication: CastPublication?
    @ObservationIgnored private var installedCast: CastPublication?
    @ObservationIgnored private var seekFrameOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private weak var seekFrameItem: AVPlayerItem?
    @ObservationIgnored private var seekFrameTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSeekToken: Int?
    @ObservationIgnored private var loader: StreamingResourceLoader?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var controlObservation: NSKeyValueObservation?
    @ObservationIgnored private var externalPlaybackObservation: NSKeyValueObservation?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var diagnosticObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var currentCastMedia: LocalCastServer.Media?
    @ObservationIgnored private var currentPrepared: PreparedEpisode?
    /// Pre-rendered standby players (N+1 and N-1): each owns a muted `AVPlayer` and
    /// `PlayerLayerView` mounted inside `prerenderHost` so frame #0 is decoded ahead of time
    /// and swapping into the visible `SlotView` avoids any cover flash.
    private static let maxWarmSlots = 2

    private struct Warm {
        let player: AVPlayer
        let layerView: PlayerLayerView
        let item: AVPlayerItem
        let route: PlaybackRoute
        let loader: StreamingResourceLoader?
        let prepared: PreparedEpisode
        let shortSide: Int?
        let startAt: Double
        let videoSize: CGSize
        /// True only when `layerView.playerLayer.isReadyForDisplay` actually became true.
        let hasDisplayFrame: Bool

        func matches(_ preferred: Int?) -> Bool {
            shortSide == preferred && Date() < prepared.expiresAt && item.status != .failed
        }

        @MainActor
        func discard() {
            player.pause()
            player.replaceCurrentItem(with: nil)
            layerView.onReady = nil
            layerView.playerLayer.player = nil
            layerView.removeFromSuperview()
            loader?.discard()
        }
    }
    @ObservationIgnored private var warm: [String: Warm] = [:]
    @ObservationIgnored private var warmOrder: [String] = []
    @ObservationIgnored private var warmingVids: Set<String> = []
    @ObservationIgnored private var request: (vid: String, seriesId: String)?
    @ObservationIgnored private var isParked = false
    @ObservationIgnored private var requestedQuality: Int?
    @ObservationIgnored private var currentInfo: PlayInfo?
    @ObservationIgnored private var retriedAfterFailure = false
    @ObservationIgnored private var failureGate = PlaybackFailureGate()
    @ObservationIgnored private var metric: PlaybackMetric?
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored private var offlineTimer: Timer?

    /// What only some apps can do (downloads, ByteVC2 conversion, casting, picture in picture).
    @ObservationIgnored public let hooks: PlayerHooks

    public init(hooks: PlayerHooks = PlayerHooks()) {
        self.hooks = hooks
        super.init()
        bindActivePlayerObservers()
        routeChangeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshExternalRoute()
            }
        }
    }

    isolated deinit {
        offlineTimer?.invalidate()
        offlineTimer = nil
        if castPublication !== installedCast { castPublication?.cancel() }
        installedCast?.cancel()
        if let timeObserver, let owner = observedPlayer { owner.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        diagnosticObservers.forEach(NotificationCenter.default.removeObserver)
        for entry in warm.values { entry.discard() }
    }

    private func configurePlayer(_ target: AVPlayer, forActive: Bool) {
        if forActive {
            target.automaticallyWaitsToMinimizeStalling = true
            target.allowsExternalPlayback = true
            target.usesExternalPlaybackWhileExternalScreenIsActive = true
            target.preventsDisplaySleepDuringVideoPlayback = true
            target.isMuted = isMuted
        } else {
            target.automaticallyWaitsToMinimizeStalling = false
            target.allowsExternalPlayback = false
            target.usesExternalPlaybackWhileExternalScreenIsActive = false
            target.preventsDisplaySleepDuringVideoPlayback = false
            target.isMuted = true
        }
    }

    private func unbindActivePlayerObservers() {
        if let timeObserver, let owner = observedPlayer {
            owner.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil
        controlObservation = nil
        externalPlaybackObservation = nil
        layerView.onReady = nil
    }

    private func bindActivePlayerObservers() {
        unbindActivePlayerObservers()
        let active = player
        configurePlayer(active, forActive: true)
        layerView.playerLayer.player = active
        layerView.onReady = { [weak self] in self?.layerBecameReady() }
        attach(layer: layerView.playerLayer)
        observedPlayer = active
        timeObserver = active.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        controlObservation = active.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            PlaybackLog.note("control \(observed.timeControlStatus.rawValue) reason=\(observed.reasonForWaitingToPlay?.rawValue ?? "-") at=\(Int(observed.currentTime().seconds.isFinite ? observed.currentTime().seconds : -1))")
            Task { @MainActor in
                guard let self, self.player === observed, self.phase != .offline else { return }
                self.isPlaying = playing
            }
        }
        externalPlaybackObservation = active.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] observed, _ in
            let activeExternal = observed.isExternalPlaybackActive
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                self.externalPlaybackChanged(activeExternal)
            }
        }
    }

    /// Attaches the visible `SlotView`'s hidden prerender container so standby `AVPlayerLayer`s
    /// live in an active window hierarchy and decode frame #0 before the user swipes.
    public func attachPrerenderHost(_ host: UIView) {
        let changed = prerenderHost !== host
        prerenderHost = host
        guard changed || warm.values.contains(where: { $0.layerView.superview !== host }) else { return }
        for entry in warm.values {
            mountInPrerenderHost(entry.layerView)
        }
    }

    private func mountInPrerenderHost(_ view: PlayerLayerView) {
        guard let host = prerenderHost else { return }
        guard view.superview !== host else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.autoresizingMask = []
        view.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        host.addSubview(view)
        CATransaction.commit()
    }

    private func storeWarm(_ entry: Warm, for vid: String) {
        if let existing = warm.removeValue(forKey: vid) {
            warmOrder.removeAll { $0 == vid }
            existing.discard()
        }
        warm[vid] = entry
        warmOrder.append(vid)
        while warmOrder.count > Self.maxWarmSlots {
            let old = warmOrder.removeFirst()
            warm.removeValue(forKey: old)?.discard()
        }
    }

    private func clearItemObservers() {
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        diagnosticObservers.forEach(NotificationCenter.default.removeObserver)
        diagnosticObservers = []
    }

    private func canParkOutgoing(forIncomingVid incomingVid: String, force: Bool) -> Bool {
        guard !force,
              !isPictureInPictureActive,
              !isExternalPlaybackActive,
              !isCastStreamActive,
              phase == .ready,
              hasFirstFrame,
              let route, route != .convertedStream,
              let outgoingPrepared = currentPrepared,
              outgoingPrepared.info.vid != incomingVid,
              Date() < outgoingPrepared.expiresAt,
              let item = player.currentItem,
              item.status == .readyToPlay else { return false }
        return true
    }

    /// Parks the currently playing player/layer into the pre-render pool as hot N-1 standby
    /// instead of tearing down its decoder, returning the host slot to swap the incoming view into.
    private func parkOutgoingPlayerIfEligible(forIncomingVid incomingVid: String, force: Bool) -> (parked: Bool, slot: SlotView?, showsWhole: Bool) {
        let slot = layerView.superview as? SlotView
        let showsWhole = layerView.showsWholeOnLargeScreen
        guard canParkOutgoing(forIncomingVid: incomingVid, force: force),
              let outgoingPrepared = currentPrepared,
              let outgoingRoute = route,
              let outgoingItem = player.currentItem else {
            return (false, slot, showsWhole)
        }
        loadTask?.cancel()
        loadTask = nil
        offlineTimer?.invalidate()
        offlineTimer = nil
        clearItemObservers()
        loader?.onMediaFailure = nil
        let outgoingLoader = loader
        let outgoingPlayer = player
        let outgoingLayerView = layerView
        let outgoingTime = outgoingPlayer.currentTime().seconds.isFinite ? max(0, outgoingPlayer.currentTime().seconds) : currentTime
        let outgoingSize = outgoingItem.presentationSize != .zero ? outgoingItem.presentationSize : videoSize
        let outgoingQuality = requestedQuality
        unbindActivePlayerObservers()
        outgoingPlayer.pause()
        configurePlayer(outgoingPlayer, forActive: false)
        outgoingLayerView.playerLayer.player = outgoingPlayer
        mountInPrerenderHost(outgoingLayerView)
        if outgoingLayerView.superview === slot {
            outgoingLayerView.removeFromSuperview()
        }
        loader = nil
        currentInfo = nil
        currentPrepared = nil
        currentCastMedia = nil
        finishMetric("cancelled")
        metric = nil
        isPlaying = false
        let parkedEntry = Warm(
            player: outgoingPlayer,
            layerView: outgoingLayerView,
            item: outgoingItem,
            route: outgoingRoute,
            loader: outgoingLoader,
            prepared: outgoingPrepared,
            shortSide: outgoingQuality,
            startAt: outgoingTime,
            videoSize: outgoingSize,
            hasDisplayFrame: outgoingLayerView.playerLayer.isReadyForDisplay
        )
        storeWarm(parkedEntry, for: outgoingPrepared.info.vid)
        PlaybackLog.note("parked outgoing vid=\(outgoingPrepared.info.vid.suffix(6)) at=\(Int(outgoingTime))")
        return (true, slot, showsWhole)
    }

    // MARK: Loading

    /// Starts an episode. A newer call cancels this one; a load that finishes late is dropped
    /// by the generation check, so a clip the user already swiped away never starts playing.
    public func load(vid: String, seriesId: String, startAt: Double = 0, preferredShortSide: Int? = nil, force: Bool = false) {
        watch = WatchProgress()
        Self.lastSelection += 1
        let now = Date()
        load(vid: vid, seriesId: seriesId, startAt: startAt, preferredShortSide: preferredShortSide,
             force: force, sourceAttempt: 0, started: now, attemptStarted: now, selection: Self.lastSelection)
    }

    /// Numbers each viewer selection in playback-metrics.jsonl; automatic source retries and
    /// media recoveries keep both `selection` and the original `started` timestamp.
    private static var lastSelection = 0

    /// `AuthenticatedPlaybackSource` already runs multi-host, renewal, isolation, and rotation
    /// recovery internally within its 10 s budget; keep one outer retry after 1 s so transient
    /// blips still recover without turning real outages into a 30-second spinner.
    private static let sourceRetryDelays: [Double] = [1.0]

    private func load(vid: String, seriesId: String, startAt: Double, preferredShortSide: Int?, force: Bool, sourceAttempt: Int,
                      started: Date, attemptStarted: Date, selection: Int, isMediaRecovery: Bool = false) {
        // Fast path: synchronous zero-flash swap when the target episode is already pre-rendered
        // in the warm pool (N+1 or parked N-1) and no offline file or cast redirect overrides it.
        if !force, !shouldUseCastStream, hooks.localFiles?.file(vid: vid) == nil,
           let hit = takeWarm(vid: vid, shortSide: preferredShortSide) {
            activateWarmHit(hit, vid: vid, seriesId: seriesId, startAt: startAt,
                            preferredShortSide: preferredShortSide, sourceAttempt: sourceAttempt,
                            started: started, attemptStarted: attemptStarted, selection: selection,
                            isMediaRecovery: isMediaRecovery)
            return
        }

        let parkedState = parkOutgoingPlayerIfEligible(forIncomingVid: vid, force: force)
        if parkedState.parked {
            // Outgoing player/layer was parked into the warm pool; allocate a fresh active pair.
            player = AVPlayer()
            layerView = PlayerLayerView()
            if let slot = parkedState.slot {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layerView.autoresizingMask = []
                layerView.frame = slot.bounds
                layerView.showsWholeOnLargeScreen = parkedState.showsWhole
                layerView.apply(fit: pictureFit, videoSize: .zero)
                slot.addSubview(layerView)
                CATransaction.commit()
            }
            bindActivePlayerObservers()
        } else {
            teardownItem()
        }
        generation += 1
        let token = generation
        request = (vid, seriesId)
        requestedQuality = preferredShortSide
        currentVid = vid
        retriedAfterFailure = isMediaRecovery
        wantsPlayback = true
        phase = .loading
        currentTime = max(0, startAt)
        duration = 0
        buffered = 0
        hasFirstFrame = false
        loadingNote = nil
        videoSize = .zero
        metric = PlaybackMetric(vid: vid, started: started, attemptStarted: attemptStarted,
                                selection: selection, sourceAttempt: sourceAttempt, startPosition: max(0, startAt))
        PlaybackLog.note("load vid=\(vid) force=\(force) attempt=\(sourceAttempt) muted=\(isMuted)")
        _ = MediaPrefixCache.shared.takeServedBytes()
        let hooks = self.hooks
        loadTask = Task { [weak self] in
            do {
                // A downloaded episode (离线缓存) plays from its file: no lookup, no network.
                if let file = hooks.localFiles?.file(vid: vid) {
                    guard let self, self.generation == token else { return }
                    PlaybackLog.note("item made route=downloaded vid=\(vid)")
                    self.metric?.route = "downloaded"
                    self.metric?.sourceObtained = Date()
                    self.loader = nil
                    self.route = .decryptedFile
                    self.currentInfo = nil
                    self.currentPrepared = nil
                    self.qualityOptions = []
                    self.currentQuality = nil
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                    self.currentCastMedia = fileSize > 0 ? .file(url: file, size: fileSize) : nil
                    if self.shouldUseCastStream, (try? await self.prepareForAirPlay(startAt: startAt)) != nil { return }
                    guard self.generation == token else { return }
                    self.start(AVPlayerItem(url: file), startAt: startAt, token: token)
                    return
                }
                // An episode already converted on this device plays from its files, with no lookup
                // (the lookup can fail for a while; the files do not).
                // Once a quality was chosen, only a conversion at that quality counts.
                if !force, let kept = await hooks.convertedStreams?.finishedStream(vid: vid, preferredShortSide: preferredShortSide) {
                    guard let self, self.generation == token else { return }
                    PlaybackLog.note("item made route=convertedStream (kept \(kept.quality?.shortSide ?? 0)) vid=\(vid)")
                    self.metric?.route = "convertedStream-kept"
                    self.metric?.quality = kept.quality?.shortSide ?? 0
                    self.metric?.sourceObtained = Date()
                    self.loader = nil
                    self.route = .convertedStream
                    self.currentInfo = nil
                    self.currentPrepared = nil
                    self.qualityOptions = kept.options
                    self.currentQuality = kept.quality
                    self.start(AVPlayerItem(url: kept.url), startAt: startAt, token: token)
                    return
                }
                let prepared: PreparedEpisode
                let made: (item: AVPlayerItem, route: PlaybackRoute, loader: StreamingResourceLoader?)
                let lookupStarted = Date()
                if !force, let hit = self?.takeWarm(vid: vid, shortSide: preferredShortSide) {
                    // Fallback in case a warm item completed while cast stream was active.
                    self?.metric?.sourceObtained = lookupStarted
                    prepared = hit.prepared
                    hit.player.pause()
                    hit.player.replaceCurrentItem(with: nil)
                    hit.layerView.onReady = nil
                    hit.layerView.playerLayer.player = nil
                    hit.layerView.removeFromSuperview()
                    made = (hit.item, hit.route, hit.loader)
                    PlaybackLog.note("warm hit vid=\(vid.suffix(6))")
                } else {
                    prepared = try await EpisodeResolver.shared.prepare(vid: vid, seriesId: seriesId,
                                                                        preferredShortSide: preferredShortSide, force: force)
                    try Task.checkCancellation()
                    guard self?.generation == token else { return }
                    self?.metric?.sourceObtained = max(lookupStarted, prepared.sourceObtainedAt)
                    if prepared.info.isByteVC2 {
                        // Converted on the device and played as it goes (see `ByteVC2Stream`).
                        // Without the hook this app cannot convert: 此剧集暂不支持, as when the core refuses it.
                        guard let streams = hooks.convertedStreams else { throw PlaybackProblem.unsupportedCodec }
                        let asked = Date()
                        self?.activeConvertedKey = ConvertedStreamKey.make(vid: prepared.info.vid, shortSide: prepared.info.quality?.shortSide)
                        let url = try await streams.open(prepared) { fraction in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.loadingNote = "正在转换 \(Int(fraction * 100))%"
                            }
                        }
                        PlaybackLog.note("bvc2 stream ready vid=\(vid.suffix(6)) " + String(format: "wait=%.1fs", Date().timeIntervalSince(asked)))
                        made = (AVPlayerItem(url: url), .convertedStream, nil)
                    } else {
                        made = try await PlayerItemFactory.makeItem(for: prepared)
                    }
                    try Task.checkCancellation()
                }
                guard let self, self.generation == token else {
                    made.loader?.discard()
                    return
                }
                self.metric?.fill(from: prepared, route: made.route)
                PlaybackLog.note("item made route=\(made.route) vid=\(vid)")
                // Defer cast-media disk lookups until AirPlay is actually active or requested.
                self.currentCastMedia = nil
                self.currentPrepared = prepared
                self.currentInfo = prepared.info
                self.qualityOptions = prepared.info.qualityOptions
                self.currentQuality = prepared.info.quality
                self.route = made.route
                if self.shouldUseCastStream, (try? await self.prepareForAirPlay(startAt: startAt)) != nil {
                    made.loader?.discard()
                    return
                }
                guard self.generation == token else { made.loader?.discard(); return }
                made.loader?.onMediaFailure = { [weak self] message in
                    Task { @MainActor in self?.mediaFailed(message, token: token) }
                }
                self.loader = made.loader
                self.start(made.item, startAt: startAt, token: token)
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == token else { return }
                let problem = PlaybackProblem.from(error)
                PlaybackLog.note("prepare failed vid=\(vid) problem=\(problem) error=\(PlaybackLog.brief(error))")
                self.finishMetric(problem == .unsupportedCodec ? "unsupported" : "failed-source")
                if problem == .unsupportedCodec {
                    self.phase = .unsupported
                    self.onUnsupported?()
                } else if sourceAttempt < Self.sourceRetryDelays.count {
                    await EpisodeResolver.shared.forget(vid: vid)
                    let emptyReply = sourceAttempt == 0 && (problem.errorDescription ?? "").contains("空响应")
                    if !emptyReply { try? await Task.sleep(for: .seconds(Self.sourceRetryDelays[sourceAttempt])) }
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.load(vid: vid, seriesId: seriesId, startAt: startAt, preferredShortSide: preferredShortSide,
                              force: true, sourceAttempt: sourceAttempt + 1, started: started, attemptStarted: Date(), selection: selection)
                } else {
                    PlaybackLog.note("source retries exhausted vid=\(vid) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
                    self.phase = .failed(problem.errorDescription ?? "播放失败")
                }
            }
        }
    }

    /// Promotes a pre-rendered standby `Warm` player + `PlayerLayerView` into the active slot
    /// synchronously so the already-decoded frame #0 appears without any cover flash.
    private func activateWarmHit(_ hit: Warm, vid: String, seriesId: String, startAt: Double,
                                 preferredShortSide: Int?, sourceAttempt: Int,
                                 started: Date, attemptStarted: Date, selection: Int, isMediaRecovery: Bool) {
        let now = Date()
        let keepCurrentPlayer = isPictureInPictureActive || isExternalPlaybackActive
        let oldLayerView = layerView
        let parkedState: (parked: Bool, slot: SlotView?, showsWhole: Bool)
        if keepCurrentPlayer {
            teardownItem()
            parkedState = (false, oldLayerView.superview as? SlotView, oldLayerView.showsWholeOnLargeScreen)
        } else {
            parkedState = parkOutgoingPlayerIfEligible(forIncomingVid: vid, force: false)
            if !parkedState.parked {
                teardownItem()
                unbindActivePlayerObservers()
            }
        }

        generation += 1
        let token = generation
        request = (vid, seriesId)
        requestedQuality = preferredShortSide
        currentVid = vid
        retriedAfterFailure = isMediaRecovery
        wantsPlayback = true
        loadingNote = nil
        currentPrepared = hit.prepared
        currentInfo = hit.prepared.info
        qualityOptions = hit.prepared.info.qualityOptions
        currentQuality = hit.prepared.info.quality
        // Never block the main-thread layer swap with AirPlay cache/disk I/O; build lazily if cast starts.
        currentCastMedia = nil
        loader = hit.loader
        route = hit.route

        var row = PlaybackMetric(vid: vid, started: started, attemptStarted: attemptStarted,
                                 selection: selection, sourceAttempt: sourceAttempt, startPosition: max(0, startAt))
        row.sourceObtained = now
        row.itemCreated = now
        row.warmState = hit.hasDisplayFrame ? "prerendered" : "item-only"
        row.fill(from: hit.prepared, route: hit.route)
        metric = row
        _ = MediaPrefixCache.shared.takeServedBytes()

        hit.loader?.onMediaFailure = { [weak self] message in
            Task { @MainActor in self?.mediaFailed(message, token: token) }
        }

        if keepCurrentPlayer {
            // PiP / AirPlay: never replace the underlying AVPlayer or AVPlayerLayer.
            hit.player.pause()
            hit.player.replaceCurrentItem(with: nil)
            hit.layerView.onReady = nil
            hit.layerView.playerLayer.player = nil
            hit.layerView.removeFromSuperview()
            phase = .loading
            hasFirstFrame = false
            currentTime = max(0, startAt)
            duration = 0
            buffered = 0
            videoSize = .zero
            PlaybackLog.note("warm hit (pip/airplay detach) vid=\(vid.suffix(6))")
            start(hit.item, startAt: startAt, token: token)
            return
        }

        // Atomic layer swap into the active SlotView without CoreAnimation fade or blank frame.
        player = hit.player
        layerView = hit.layerView
        let itemSize = hit.item.presentationSize != .zero ? hit.item.presentationSize : hit.videoSize
        if let slot = parkedState.slot {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layerView.autoresizingMask = []
            layerView.frame = slot.bounds
            layerView.showsWholeOnLargeScreen = parkedState.showsWhole
            layerView.apply(fit: pictureFit, videoSize: itemSize)
            slot.addSubview(layerView)
            if !parkedState.parked, oldLayerView !== layerView, oldLayerView.superview === slot {
                oldLayerView.removeFromSuperview()
            }
            CATransaction.commit()
        } else if !parkedState.parked, oldLayerView !== layerView {
            oldLayerView.removeFromSuperview()
        }
        bindActivePlayerObservers()

        hit.item.preferredForwardBufferDuration = 12
        attachItemObservers(hit.item, token: token)

        for track in hit.item.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = !isMuted
        }
        let targetTime = max(0, startAt)
        let currentPos = player.currentTime().seconds
        let actualPos = currentPos.isFinite ? currentPos : 0
        let needsSeek = abs(actualPos - targetTime) > 1.0

        videoSize = itemSize
        let total = hit.item.duration.seconds
        duration = (total.isFinite && total > 0) ? total : 0
        currentTime = targetTime
        let ranges = hit.item.loadedTimeRanges.map(\.timeRangeValue)
        if let range = ranges.first(where: { $0.containsTime(player.currentTime()) }) ?? ranges.last, range.end.seconds.isFinite {
            buffered = range.end.seconds
        } else {
            buffered = 0
        }

        let itemReady = hit.item.status == .readyToPlay
        phase = itemReady ? .ready : .loading
        let layerDisplayReady = itemReady && layerView.playerLayer.isReadyForDisplay
        if itemReady { metric?.ready = now }

        if needsSeek {
            // Repositioning a parked player (e.g. from episode end back to 0s): do NOT misreport
            // the stale retained frame as the target position's first frame; record `retainedFrame`
            // separately and mark `firstFrame` only once the seek finishes decoding at `targetTime`.
            if layerDisplayReady { metric?.retainedFrame = now }
            pendingSeekToken = token
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            hit.item.add(output)
            seekFrameItem = hit.item
            seekFrameOutput = output
            hasFirstFrame = false
            PlaybackLog.note("warm swap seek-pending vid=\(vid.suffix(6)) from=\(Int(actualPos)) to=\(Int(targetTime)) retainedDisplay=\(layerDisplayReady)")
            player.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if self.pendingSeekToken == token { self.pendingSeekToken = nil }
                    // A cancelled seek can be superseded by a scrub. Observe the frame
                    // for the current item time in either case, once the layer is visible.
                    if finished {
                        self.metric?.seekCompleted = Date()
                    } else {
                        self.finishMetric("seek-superseded")
                    }
                    self.observeSeekFrame(token: token)
                    if self.wantsPlayback, (!self.isMuted || self.phase == .ready) {
                        self.player.playImmediately(atRate: self.isHoldingSpeed ? self.holdRate : self.rate)
                    } else if !self.wantsPlayback, self.layerView.playerLayer.isReadyForDisplay {
                        self.clearSeekFrameObservation()
                        self.hasFirstFrame = true
                    }
                }
            }
        } else {
            pendingSeekToken = nil
            hasFirstFrame = layerDisplayReady
            if layerDisplayReady {
                metric?.firstFrame = now
                FeedLog.swipe("frame card=\(seriesId)")
                PlaybackLog.note("warm swap instant-frame vid=\(vid.suffix(6)) at=\(Int(targetTime))")
            } else {
                PlaybackLog.note("warm swap vid=\(vid.suffix(6)) ready=\(itemReady) display=false warmState=\(hit.hasDisplayFrame ? "prerendered" : "item-only")")
            }
            if wantsPlayback {
                if !isMuted || itemReady {
                    player.playImmediately(atRate: isHoldingSpeed ? holdRate : rate)
                }
            }
        }
        if parkedState.slot == nil { refreshSurface() }
    }

    /// Pre-renders an upcoming episode on a muted offscreen `AVPlayer` + `PlayerLayerView` so its
    /// first video frame is already decoded before the user swipes. Distinguishes true rendered
    /// frames (`hasDisplayFrame == true`) from item-only readiness (`no-window` / `frame-timeout`),
    /// and discards standby resources on any error.
    public func warmUp(_ prepared: PreparedEpisode, preferredShortSide: Int?, startAt: Double = 0) async {
        let vid = prepared.info.vid
        // A ByteVC2 episode is converted ahead instead (`ByteVC2Stream.prepareAhead`).
        guard vid != currentVid, phase != .offline, !prepared.info.isByteVC2 else { return }
        if let existing = warm[vid], existing.matches(preferredShortSide),
           existing.hasDisplayFrame, abs(existing.startAt - max(0, startAt)) <= 1.0 {
            return
        }
        guard warmingVids.insert(vid).inserted else { return }
        defer { warmingVids.remove(vid) }

        let made: (item: AVPlayerItem, route: PlaybackRoute, loader: StreamingResourceLoader?)
        do {
            made = try await PlayerItemFactory.makeItem(for: prepared)
        } catch is CancellationError {
            return
        } catch {
            PlaybackLog.note("warm failed stage=makeItem vid=\(vid.suffix(6)) err=\(PlaybackLog.brief(error))")
            return
        }
        guard !Task.isCancelled, vid != currentVid else {
            made.loader?.discard()
            return
        }

        made.item.preferredForwardBufferDuration = 6
        let standbyPlayer = AVPlayer()
        configurePlayer(standbyPlayer, forActive: false)
        let standbyLayerView = PlayerLayerView()
        standbyLayerView.playerLayer.player = standbyPlayer
        standbyLayerView.apply(fit: pictureFit, videoSize: .zero)
        mountInPrerenderHost(standbyLayerView)
        standbyPlayer.replaceCurrentItem(with: made.item)

        let cleanupStandby: () -> Void = {
            standbyPlayer.pause()
            standbyPlayer.replaceCurrentItem(with: nil)
            standbyLayerView.onReady = nil
            standbyLayerView.playerLayer.player = nil
            standbyLayerView.removeFromSuperview()
            made.loader?.discard()
        }

        do {
            try await awaitWarmItemReady(made.item, timeout: 6)
            let clampedStart = max(0, startAt)
            if clampedStart > 1 {
                _ = await standbyPlayer.seek(to: CMTime(seconds: clampedStart, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
            let frameResult = try await awaitWarmFirstFrame(item: made.item, layerView: standbyLayerView, timeout: 1.5)
            guard !Task.isCancelled, vid != currentVid, made.item.status == .readyToPlay else {
                cleanupStandby()
                return
            }
            let size = made.item.presentationSize
            standbyLayerView.apply(fit: pictureFit, videoSize: size)
            let displayReady = (frameResult == .ready) && standbyLayerView.playerLayer.isReadyForDisplay
            let entry = Warm(
                player: standbyPlayer,
                layerView: standbyLayerView,
                item: made.item,
                route: made.route,
                loader: made.loader,
                prepared: prepared,
                shortSide: preferredShortSide,
                startAt: clampedStart,
                videoSize: size,
                hasDisplayFrame: displayReady
            )
            storeWarm(entry, for: vid)
            if displayReady {
                PlaybackLog.note("warm prerender-ready vid=\(vid.suffix(6)) display=true at=\(Int(clampedStart))")
            } else {
                let reason = frameResult == .noWindow ? "no-window" : "frame-timeout"
                PlaybackLog.note("warm item-ready vid=\(vid.suffix(6)) display=false reason=\(reason) at=\(Int(clampedStart))")
            }
        } catch is CancellationError {
            cleanupStandby()
        } catch {
            cleanupStandby()
            PlaybackLog.note("warm failed stage=prerender vid=\(vid.suffix(6)) err=\(PlaybackLog.brief(error))")
        }
    }

    private enum WarmFrameOutcome {
        case ready
        case noWindow
        case timedOut
    }

    private func awaitWarmItemReady(_ item: AVPlayerItem, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            switch item.status {
            case .readyToPlay:
                return
            case .failed:
                throw item.error ?? HongguoError(.unavailable, "预热解码失败")
            default:
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw HongguoError(.unavailable, "预热超时")
    }

    private func awaitWarmFirstFrame(item: AVPlayerItem, layerView: PlayerLayerView, timeout: TimeInterval) async throws -> WarmFrameOutcome {
        if layerView.window == nil { return .noWindow }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if item.status == .failed {
                throw item.error ?? HongguoError(.unavailable, "预热首帧失败")
            }
            if layerView.playerLayer.isReadyForDisplay {
                return .ready
            }
            if layerView.window == nil {
                return .noWindow
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return layerView.playerLayer.isReadyForDisplay ? .ready : .timedOut
    }

    public func canResumeFeedClip(preferredQuality: Int?) -> Bool {
        guard phase == .ready, hasFirstFrame, !isPictureInPictureActive,
              !isExternalPlaybackActive, !isCastStreamActive,
              route != .convertedStream, requestedQuality == preferredQuality,
              let item = player.currentItem, item.status == .readyToPlay else { return false }
        if let prepared = currentPrepared, Date() >= prepared.expiresAt { return false }
        let remaining = item.duration.seconds - player.currentTime().seconds
        return !remaining.isFinite || remaining > 0.2
    }

    public func parkFeedClip() {
        onEnded = nil
        onUnsupported = nil
        pause()
        isParked = true
    }

    public func takeFeedSettingsAndWarmItems(from other: PlayerEngine) {
        isParked = false
        pictureFit = other.pictureFit
        rate = other.rate
        isMuted = other.isMuted
        swap(&warm, &other.warm)
        swap(&warmOrder, &other.warmOrder)
        for entry in warm.values { mountInPrerenderHost(entry.layerView) }
    }

    public func hasWarmItem(vid: String, preferredShortSide: Int?) -> Bool {
        warm[vid]?.matches(preferredShortSide) == true
    }

    private func takeWarm(vid: String, shortSide: Int?) -> Warm? {
        guard let hit = warm[vid] else { return nil }
        warm[vid] = nil
        warmOrder.removeAll { $0 == vid }
        // A signed address that has aged out, failed item, or another quality asked for: not usable.
        guard hit.matches(shortSide) else {
            hit.discard()
            return nil
        }
        return hit
    }

    /// Sample mode: no media, a pretend 90 second timeline that advances while "playing".
    public func loadOffline(vid: String) {
        teardownItem()
        generation += 1
        currentVid = vid
        phase = .offline
        currentTime = 12
        duration = 90
        buffered = 40
        isPlaying = true
        offlineTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .offline, self.isPlaying else { return }
                self.currentTime = min(self.duration, self.currentTime + 0.25 * Double(self.rate))
                if self.currentTime >= self.duration { self.currentTime = 0; self.onEnded?() }
            }
        }
    }

    private func attachItemObservers(_ item: AVPlayerItem, token: Int) {
        clearItemObservers()
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.onEnded?()
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error.map(describeError)
            PlaybackLog.note("item status \(status.rawValue) error=\(item.error.map(PlaybackLog.brief) ?? "-") size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))")
            let size = item.presentationSize
            Task { @MainActor in self?.itemStatusChanged(status, message: message, size: size, token: token) }
        }
        // A source that stops answering after the item is ready never turns its status to
        // failed: the player stalls and, about 18 s later, posts only failedToPlayToEndTime.
        let midPlayFailure = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                                    object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let failedItem = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mediaFailed(error.map(describeError) ?? "播放中断", token: token,
                                 isCurrentItem: failedItem != nil && failedItem === self.player.currentItem)
            }
        }
        diagnosticObservers = [midPlayFailure] + [
            AVPlayerItem.playbackStalledNotification, AVPlayerItem.failedToPlayToEndTimeNotification, AVPlayerItem.newErrorLogEntryNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { note in
                let item = note.object as? AVPlayerItem
                let event = item?.errorLog()?.events.last
                let failure = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error).map(PlaybackLog.brief) ?? "-"
                PlaybackLog.note("\(name.rawValue) failure=\(failure) log=\(event.map { "\($0.errorDomain) \($0.errorStatusCode) \($0.errorComment ?? "")" } ?? "-")")
            }
        }
    }

    private func start(_ item: AVPlayerItem, startAt: Double, token: Int, cast: CastPublication? = nil) {
        if installedCast !== cast { installedCast?.cancel() }
        installedCast = cast
        isCastStreamActive = cast != nil
        item.preferredForwardBufferDuration = 12
        attachItemObservers(item, token: token)
        metric?.itemCreated = Date()
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        if startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // Muted: wait until the item is ready and its audio tracks are switched off before
        // starting, so that no audio is ever rendered and no audio output is opened for it.
        if wantsPlayback, !isMuted { player.playImmediately(atRate: rate) }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?, size: CGSize, token: Int) {
        guard generation == token else { return }
        switch status {
        case .readyToPlay:
            phase = .ready
            // Muted: switch the audio tracks off, so no audio is rendered at all (on a simulator
            // a silent track still opens the Mac's audio output).
            if isMuted, let item = player.currentItem {
                for track in item.tracks where track.assetTrack?.mediaType == .audio { track.isEnabled = false }
                if wantsPlayback, player.rate == 0 { player.playImmediately(atRate: rate) }
            }
            if size != .zero { videoSize = size }
            if metric?.ready == nil { metric?.ready = Date() }
        case .failed:
            mediaFailed(message ?? "未知错误", token: token)
        default:
            break
        }
    }

    private func mediaFailed(_ message: String, token: Int, isCurrentItem: Bool = true) {
        guard let request, failureGate.accept(token: token, current: generation, isCurrentItem: isCurrentItem) else { return }
        let originalStarted = metric?.started ?? Date()
        let originalSelection = metric?.selection ?? Self.lastSelection
        finishMetric("failed-media")
        if isParked {
            phase = .failed(message)
            return
        }
        PlaybackLog.note("media failed retried=\(retriedAfterFailure) at=\(Int(currentTime))")
        if !retriedAfterFailure {
            // A prefetched signed URL can expire: resolve once more
            // while preserving the original user-selection timestamp for accurate startup telemetry (Codex #10).
            let position = currentTime
            Task {
                await EpisodeResolver.shared.forget(vid: request.vid)
                guard self.generation == token, !self.isParked else { return }
                self.load(vid: request.vid, seriesId: request.seriesId, startAt: position,
                          preferredShortSide: self.currentQuality?.shortSide ?? self.requestedQuality, force: true, sourceAttempt: 0,
                          started: originalStarted, attemptStarted: Date(), selection: originalSelection, isMediaRecovery: true)
            }
            return
        }
        phase = .failed("播放失败：\(message)")
    }

    /// Writes the current attempt's timing row once: when time first advances, or when it fails,
    /// is cancelled or turns out unsupported first.
    private func finishMetric(_ outcome: String) {
        guard var row = metric, !row.written else { return }
        row.outcome = outcome
        row.written = true
        metric = row
        PlaybackMetric.append(row)
    }

    /// Called by the video view when the layer has a frame to show.
    public func layerBecameReady() {
        guard !hasFirstFrame, pendingSeekToken != generation, phase != .offline,
              player.currentItem != nil, layerView.playerLayer.isReadyForDisplay else { return }
        if let output = seekFrameOutput {
            guard layerView.window != nil, seekFrameItem === player.currentItem else { return }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard time.isNumeric, output.hasNewPixelBuffer(forItemTime: time),
                  output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil else { return }
            clearSeekFrameObservation()
        }
        if let request { FeedLog.swipe("frame card=\(request.seriesId)") }
        hasFirstFrame = true
        loadingNote = nil
        PlaybackLog.note("first frame, from disk \(MediaPrefixCache.shared.takeServedBytes() / 1024) KB")
        if metric?.firstFrame == nil { metric?.firstFrame = Date() }
    }

    private func clearSeekFrameObservation() {
        seekFrameTask?.cancel()
        seekFrameTask = nil
        if let output = seekFrameOutput { seekFrameItem?.remove(output) }
        seekFrameItem = nil
        seekFrameOutput = nil
    }

    private func observeSeekFrame(token: Int) {
        layerBecameReady()
        guard seekFrameOutput != nil else { return }
        // Sample the first second closely. The normal playback tick handles longer stalls.
        seekFrameTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self, generation == token, seekFrameOutput != nil else { return }
                layerBecameReady()
            }
        }
    }

    private func teardownItem() {
        pendingSeekToken = nil
        endScrubImage()
        loadTask?.cancel()
        // A conversion that was only for the episode being left stops here.
        if route == .convertedStream || phase == .loading, let leaving = currentVid {
            let leavingKey = activeConvertedKey
            if let streams = hooks.convertedStreams { Task { await streams.leave(vid: leaving, key: leavingKey) } }
        }
        activeConvertedKey = nil
        // Nothing is reading from the local server any more; it starts again when needed.
        if route == .convertedStream { hooks.convertedStreams?.stopServing() }
        loadTask = nil
        offlineTimer?.invalidate()
        offlineTimer = nil
        clearItemObservers()
        player.pause()
        // In picture in picture or AirPlay the old item stays until the next one replaces it:
        // taking the item away closes PiP or drops external playback back to the TV home screen.
        if !isPictureInPictureActive && !isExternalPlaybackActive { player.replaceCurrentItem(with: nil) }
        loader?.discard()
        loader = nil
        currentInfo = nil
        currentPrepared = nil
        currentCastMedia = nil
        // Left before it played (a swipe, a newer selection, stop): the attempt still gets a row.
        finishMetric("cancelled")
        metric = nil
        isPlaying = false
    }

    /// Asks whichever `VideoSurface` is on screen to show the video again.
    public func refreshSurface() { surfaceEpoch += 1 }

    public func stop() {
        generation += 1
        teardownItem()
        phase = .idle
        route = nil
        isParked = false
        currentVid = nil
        request = nil
        if !isExternalPlaybackActive { stopCastSession() }
    }

    // MARK: AirPlay Casting

    /// Casting needs the hook; without it the player never publishes a stream, whatever the
    /// audio route says.
    private var canPublishCast: Bool { hooks.cast != nil }

    private var shouldUseCastStream: Bool {
        canPublishCast && (isExternalPlaybackActive || isCastStreamActive || Self.activeAirPlayDeviceName() != nil)
    }

    private var canCastCurrentItem: Bool {
        guard canPublishCast else { return false }
        if currentCastMedia != nil { return true }
        guard let prepared = currentPrepared else { return false }
        let info = prepared.info
        if info.isByteVC2 { return false }
        return route == .decryptedFile || (info.isEncrypted && (prepared.map?.inputLength ?? 0) > 0) || !info.needsLocalFile
    }

    @discardableResult
    public func prepareForAirPlay() async throws -> URL {
        try await prepareForAirPlay(startAt: nil)
    }

    private func prepareForAirPlay(startAt: Double?) async throws -> URL {
        let token = generation
        let publication: CastPublication
        if let existing = castPublication {
            publication = existing
        } else {
            let local = currentCastMedia
            let prepared = currentPrepared
            guard let cast = hooks.cast else { throw HongguoError(.unavailable, "当前设备不支持局域网投屏") }
            guard local != nil || prepared != nil else {
                throw HongguoError(.unavailable, "当前片源暂不支持局域网投屏（或正在加载中）")
            }
            publication = cast.publish {
                if let local { return local }
                if let prepared, let media = Self.castMedia(for: prepared) { return media }
                throw HongguoError(.unavailable, "当前片源暂不支持局域网投屏")
            }
            castPublication = publication
        }

        let url: URL
        do {
            url = try await publication.url()
        } catch {
            if castPublication === publication {
                castPublication = nil
                publication.cancel()
            }
            throw error
        }
        guard generation == token, castPublication === publication else { throw CancellationError() }
        if installedCast !== publication {
            loader?.discard()
            loader = nil
            start(AVPlayerItem(url: url), startAt: startAt ?? currentTime, token: token, cast: publication)
        }
        return url
    }

    public func stopCastSession() {
        if castPublication !== installedCast { castPublication?.cancel() }
        installedCast?.cancel()
        castPublication = nil
        installedCast = nil
        isCastStreamActive = false
    }

    private func externalPlaybackChanged(_ active: Bool) {
        let wasActive = isExternalPlaybackActive
        isExternalPlaybackActive = active
        refreshExternalRoute()
        if active, !isCastStreamActive, canCastCurrentItem {
            Task { _ = try? await prepareForAirPlay() }
        } else if wasActive, !active, Self.activeAirPlayDeviceName() == nil {
            if isCastStreamActive {
                let resumeReq = request
                let resumeAt = currentTime
                let resumeQuality = currentQuality?.shortSide ?? requestedQuality
                stopCastSession()
                if let resumeReq, phase != .offline {
                    load(vid: resumeReq.vid, seriesId: resumeReq.seriesId, startAt: resumeAt,
                         preferredShortSide: resumeQuality, force: false)
                }
            }
        }
        if !active {
            refreshSurface()
            if layerView.playerLayer.isReadyForDisplay { layerBecameReady() }
        }
    }

    private func refreshExternalRoute() {
        let name = Self.activeAirPlayDeviceName() ?? ""
        externalPlaybackDeviceName = name
        if !name.isEmpty, !isCastStreamActive, canCastCurrentItem {
            Task { _ = try? await prepareForAirPlay() }
        }
    }

    private static func activeAirPlayDeviceName() -> String? {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .first { $0.portType == .airPlay }?
            .portName
    }

    private nonisolated static func castMedia(for prepared: PreparedEpisode) -> LocalCastServer.Media? {
        let info = prepared.info
        if info.isByteVC2 { return nil }
        if let file = PlaybackCache.shared.cachedFile(for: info),
           let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64), size > 0 {
            return .file(url: file, size: size)
        }
        if info.isEncrypted, let map = prepared.map, map.inputLength > 0 {
            let prefix = MediaPrefixCache.shared.load(key: MediaPrefixCache.key(for: info))
                ?? prepared.initialMedia
            return .encrypted(source: info.url, headers: info.httpHeaders, map: map, prefix: prefix)
        }
        if !info.needsLocalFile {
            return .remote(source: info.url, headers: info.httpHeaders, contentLength: nil)
        }
        return nil
    }

    public func retry() {
        guard let request else { return }
        load(vid: request.vid, seriesId: request.seriesId, startAt: currentTime,
             preferredShortSide: currentQuality?.shortSide ?? requestedQuality, force: true)
    }

    // MARK: Transport

    public func play() {
        wantsPlayback = true
        if phase == .offline { isPlaying = true; return }
        guard player.currentItem != nil else { return }
        // Muted and not ready yet: playback starts once the audio tracks are off (see `itemStatusChanged`).
        if isMuted, phase != .ready { return }
        player.playImmediately(atRate: isHoldingSpeed ? holdRate : rate)
    }

    public func pause() {
        wantsPlayback = false
        if phase == .offline { isPlaying = false; return }
        player.pause()
    }

    public func togglePlay() {
        wantsPlayback ? pause() : play()
    }

    public func seek(to seconds: Double) {
        watch.userMoved()
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        currentTime = target
        guard phase != .offline else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func restart() {
        seek(to: 0)
        play()
    }

    /// Long press: 2x while held.
    public func beginHoldSpeed() {
        guard !isHoldingSpeed, isPlaying else { return }
        isHoldingSpeed = true
        holdRate = PlaybackRate.holdRate
        if phase != .offline { player.rate = holdRate }
    }

    /// Changes the held rate while the hold lasts.
    public func setHoldRate(_ value: Float) {
        guard isHoldingSpeed, value != holdRate else { return }
        holdRate = value
        if phase != .offline, isPlaying { player.rate = value }
    }

    public func endHoldSpeed() {
        guard isHoldingSpeed else { return }
        isHoldingSpeed = false
        if phase != .offline, isPlaying { player.rate = rate }
    }

    /// Switches resolution tier, keeping the position.
    public func selectQuality(_ option: QualityOption) {
        guard let request, option != currentQuality else { return }
        load(vid: request.vid, seriesId: request.seriesId, startAt: currentTime, preferredShortSide: option.shortSide)
    }

    private func tick() {
        guard phase != .offline, let item = player.currentItem else { return }
        let now = player.currentTime().seconds
        if now.isFinite { currentTime = now }
        watch.sample(now, playing: player.timeControlStatus == .playing)
        if seekFrameOutput != nil { layerBecameReady() }
        if pendingSeekToken == nil, seekFrameOutput == nil, let metric, metric.advanced == nil, now.isFinite, now - metric.startPosition > 0.2, player.timeControlStatus == .playing {
            self.metric?.advanced = Date()
            finishMetric("playing")
        }
        let total = item.duration.seconds
        if total.isFinite, total > 0 { duration = total }
        if item.presentationSize != .zero, videoSize != item.presentationSize { videoSize = item.presentationSize }
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        if let range = ranges.first(where: { $0.containsTime(player.currentTime()) }) ?? ranges.last {
            let end = range.end.seconds
            if end.isFinite { buffered = end }
        }
    }

    // MARK: Picture in Picture

    public var supportsPictureInPicture: Bool { hooks.pictureInPicture != nil && AVPictureInPictureController.isPictureInPictureSupported() }

    /// 退出 App 时自动小窗: leaving the app while a clip plays carries it on in the little window.
    /// Off, leaving pauses it. Kept across launches; on until the viewer turns it off.
    private static let autoPictureInPictureKey = "autoPictureInPicture"
    public static var autoPictureInPictureSaved: Bool {
        get { UserDefaults.standard.object(forKey: autoPictureInPictureKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoPictureInPictureKey) }
    }
    public var autoPictureInPicture: Bool = PlayerEngine.autoPictureInPictureSaved {
        didSet {
            Self.autoPictureInPictureSaved = autoPictureInPicture
            if let pipController { hooks.pictureInPicture?.setStartsAutomatically(autoPictureInPicture, for: pipController) }
        }
    }

    /// The video view hands over its layer so 小窗模式 can use it.
    public func attach(layer: AVPlayerLayer) {
        guard supportsPictureInPicture, let pip = hooks.pictureInPicture, pipController?.playerLayer !== layer else { return }
        let controller = pip.makeController(for: layer, startsAutomatically: Self.autoPictureInPictureSaved)
        controller?.delegate = self
        pipController = controller
    }
}

extension PlayerEngine {
    /// Back in the app: the picture belongs on the page again, not in the little window.
    public func endPictureInPictureIfActive() {
        guard let pipController, pipController.isPictureInPictureActive else {
            if isPictureInPictureActive { isPictureInPictureActive = false }
            return
        }
        PlaybackLog.note("pip stop on foreground")
        pipController.stopPictureInPicture()
    }
}

extension PlayerEngine: AVPictureInPictureControllerDelegate {
    public nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        PlaybackLog.note("pip failed to start: \(PlaybackLog.brief(error))")
        Task { @MainActor in self.isPictureInPictureActive = false }
    }

    public nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        PlaybackLog.note("pip restore interface")
        completionHandler(true)
    }

    public nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        PlaybackLog.note("pip started")
        Task { @MainActor in self.isPictureInPictureActive = true }
    }

    public nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        PlaybackLog.note("pip stopped")
        Task { @MainActor in self.isPictureInPictureActive = false }
    }
}

/// Timings of one start, appended as a JSON line to Documents/playback-metrics.jsonl so a
/// test run can read them back from the simulator's app container.
/// One row per playback attempt in Documents/playback-metrics.jsonl. Times are milliseconds since
/// the viewer's selection (`selection`, shared by automatic source retries); -1 means not reached.
public struct PlaybackMetric {
    public var vid: String
    /// Timestamp of the viewer's original tap/swipe (preserved across retries and media recovery).
    public var started: Date
    /// Timestamp of this specific load attempt (differs from `started` on retry/recovery).
    public var attemptStarted: Date
    public var selection = 0
    public var sourceAttempt = 0
    /// Where playback starts (a resume point); time has advanced once it moves past this.
    public var startPosition: Double = 0
    public var sourceSeconds: Double = 0
    public var headerSeconds: Double = 0
    public var fromPrefetch = false
    public var route = ""
    public var source = ""
    public var codec = ""
    public var quality = 0
    public var encrypted = false
    /// The source (or a kept conversion, or a prepared item) was in hand.
    public var sourceObtained: Date?
    public var itemCreated: Date?
    public var ready: Date?
    /// Retained parked frame visible while a promoted warm player seeks to a different target position.
    public var retainedFrame: Date?
    public var seekCompleted: Date?
    /// First decoded frame at the requested `startPosition`.
    public var firstFrame: Date?
    /// Playback time first moved.
    public var advanced: Date?
    /// "cold", "item-only", or "prerendered".
    public var warmState = "cold"
    /// playing, failed-source, failed-media, unsupported or cancelled.
    public var outcome = ""
    public var written = false

    mutating func fill(from prepared: PreparedEpisode, route: PlaybackRoute) {
        sourceSeconds = prepared.sourceSeconds
        headerSeconds = prepared.headerSeconds
        fromPrefetch = prepared.fromPrefetch
        self.route = route.rawValue
        source = prepared.info.source.rawValue
        codec = prepared.info.codec
        quality = prepared.info.quality?.shortSide ?? 0
        encrypted = prepared.info.isEncrypted
    }

    public static func append(_ metric: PlaybackMetric) {
        func ms(_ date: Date?, from origin: Date = metric.started) -> Int {
            date.map { Int(($0.timeIntervalSince(origin) * 1000).rounded()) } ?? -1
        }
        let row: [String: Any] = [
            "vid": metric.vid, "route": metric.route, "source": metric.source, "codec": metric.codec,
            "quality": metric.quality, "encrypted": metric.encrypted, "fromPrefetch": metric.fromPrefetch,
            "warmState": metric.warmState,
            "selection": metric.selection, "sourceAttempt": metric.sourceAttempt, "outcome": metric.outcome,
            "sourceObtainedMs": ms(metric.sourceObtained), "advancedMs": ms(metric.advanced),
            "sourceMs": Int((metric.sourceSeconds * 1000).rounded()), "headerMs": Int((metric.headerSeconds * 1000).rounded()),
            "itemCreatedMs": ms(metric.itemCreated), "readyMs": ms(metric.ready),
            "retainedFrameMs": ms(metric.retainedFrame), "seekCompletedMs": ms(metric.seekCompleted), "firstFrameMs": ms(metric.firstFrame),
            "attemptOffsetMs": ms(metric.attemptStarted),
            "attemptFirstFrameMs": ms(metric.firstFrame, from: metric.attemptStarted),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let directory = PlaybackLog.directory else { return }
        let file = directory.appendingPathComponent("playback-metrics.jsonl")
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }
}

/// What the player did, one line per event, in Documents/playback-log.txt: enough to tell from
/// outside where a start failed. No addresses, keys or cookies are written, only ids, states
/// and error domains with their codes.
public enum PlaybackLog {
    private static let queue = DispatchQueue(label: "playback-log")

    /// Where the playback log, the playback metrics and the feed log are written: Documents
    /// unless the app chose another folder at launch (tvOS has no writable Documents).
    nonisolated(unsafe) public static var directory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

    public static func note(_ text: String) {
        let line = Data("\(Date().formatted(.iso8601)) \(text)\n".utf8)
        queue.async {
            guard let directory = PlaybackLog.directory else { return }
            let file = directory.appendingPathComponent("playback-log.txt")
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
        }
    }

    /// An error as its domain and code, with those of the error underneath it.
    public static func brief(_ error: Error) -> String {
        let ns = error as NSError
        let under = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " <- \($0.domain) \($0.code)" } ?? ""
        return "\(ns.domain) \(ns.code)\(under)"
    }
}
#endif

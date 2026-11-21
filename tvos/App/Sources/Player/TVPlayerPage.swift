import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI
import UIKit

/// The player: the shared `PlayerEngine` and `PlaybackSession` (episode order, resume, history,
/// prefetch, auto-advance), with a control layer drawn here for the Siri Remote.
///
/// A 9:16 episode fills the height, centred and never cropped, over the cover's colour blurred
/// on both sides. Clicking the touch surface or the play key pauses and shows the controls;
/// clicking its left or right edge goes back or forward 10 s; swiping left or right scrubs;
/// swiping down opens the episodes; Back closes a panel first, then the player.
struct TVPlayerPage: View {
    let app: TVAppModel
    @State private var session: PlaybackSession
    @State private var controlsVisible = false
    @State private var controlsToken = 0
    @State private var panel: Panel?
    @State private var scrubFrom: Double?
    @State private var scrubTo: Double?
    @State private var tint = Color.gray
    @State private var nowPlaying = NowPlaying()
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: Focus?
    /// Bumped to hand the focus back to the picture (the remote surface) when what had it goes.
    @State private var surfaceFocus = 0

    enum Panel: Equatable { case episodes, speed, quality, comments }
    /// The same choices as the iOS player's speed menu.
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2, 3]
    enum Focus: Hashable { case next, episodes, comments, danmaku, speed, quality, panel(Int) }

    init(target: PlayerTarget, app: TVAppModel) {
        self.app = app
        _session = State(initialValue: PlaybackSession(target: target, app: app))
    }

    private var engine: PlayerEngine { session.engine }

    var body: some View {
        GeometryReader { proxy in
            let video = videoFrame(in: proxy.size)
            ZStack {
                AmbientBackground(tint: tint)
                VideoSurface(engine: engine)
                    .frame(width: video.width, height: video.height)
                    .position(x: video.midX, y: video.midY)
                if app.library.settings.danmaku.enabled, !session.danmaku.isEmpty {
                    // Only over the top third of the picture.
                    DanmakuLayer(items: session.danmaku, engine: engine, settings: app.library.settings.danmaku, bottomInset: 0)
                        .frame(width: video.width, height: video.height / 3)
                        .clipped()
                        .position(x: video.midX, y: video.minY + video.height / 6)
                        .allowsHitTesting(false)
                }
                status
                    .position(x: video.midX, y: video.midY)
                RemoteSurface(isActive: panel == nil, focusRequest: surfaceFocus,
                              onSelect: clickOrPlayKey,
                              onStep: { step($0) }, onScrub: { scrub($0) },
                              onSwipeDown: swipeDown, onMenu: back)
                    .ignoresSafeArea()
                if controlsVisible || scrubTo != nil {
                    controls
                        .transition(.opacity)
                }
                if panel == nil {
                    NextEpisodeButton(session: session, focus: $focus) { surfaceFocus += 1 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 90).padding(.bottom, controlsVisible ? 260 : 90)
                }
                NowPlayingTicker(session: session, nowPlaying: nowPlaying)
                if let panel {
                    panelView(panel)
                        .transition(.move(edge: panel == .episodes ? .bottom : .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: panel)
        .onExitCommand(perform: back)
        // The play key, wherever the focus is.
        .onPlayPauseCommand(perform: clickOrPlayKey)
        .task { await session.open() }
        .task(id: session.cover) {
            if let color = await CoverTint.color(for: session.cover) { tint = color }
            else { tint = PlaceholderTint.color(for: session.target.seriesId) }
        }
        .task(id: controlsToken) { await autoHide() }
        .onAppear(perform: appeared)
        .onDisappear(perform: disappeared)
        .onChange(of: engine.isPlaying) { _, playing in
            // No screensaver while an episode plays.
            UIApplication.shared.isIdleTimerDisabled = playing
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the front: the position is written now, not on the next 5 s tick.
            if phase != .active { session.persist(forceSync: true) }
        }
    }

    // MARK: Layout

    /// An upright episode fills the height at 9:16, centred; a landscape one fills the screen.
    private func videoFrame(in size: CGSize) -> CGRect {
        if engine.isLandscapeVideo { return CGRect(origin: .zero, size: size) }
        let width = min(size.width, size.height * 9 / 16)
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    @ViewBuilder private var status: some View {
        switch engine.phase {
        case .loading:
            VStack(spacing: 20) {
                ProgressView().controlSize(.large)
                if let note = engine.loadingNote { Text(note).foregroundStyle(.secondary) }
            }
        case .failed(let message):
            VStack(spacing: 24) {
                Text(message).font(.headline)
                Text("按下触控板重试").foregroundStyle(.secondary)
            }
        case .unsupported:
            Text(session.hasNext ? "此剧集暂不支持，2 秒后播放下一集" : "此剧集暂不支持").font(.headline)
        case .offline:
            Label("离线示例，没有视频画面", systemImage: "wifi.slash").foregroundStyle(.secondary)
        default:
            if let loadError = session.loadError { Text(loadError).font(.headline) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.title).font(.title2.weight(.bold)).lineLimit(1)
                if session.total > 0 {
                    Text("第\(session.episodeNumber)集 / 共\(session.total)集").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 28) {
                LiveProgress(engine: engine, scrubTo: scrubTo)
                HStack(spacing: 28) {
                    Button { open(.episodes) } label: { Label("选集", systemImage: "square.grid.3x3") }
                        .focused($focus, equals: .episodes)
                    Button { open(.comments) } label: { Label("评论", systemImage: "text.bubble") }
                        .focused($focus, equals: .comments)
                        .disabled(session.currentEpisode == nil)
                    let danmakuOn = app.library.settings.danmaku.enabled
                    Button { toggleDanmaku() } label: {
                        Label(danmakuOn ? "弹幕 开" : "弹幕 关", systemImage: danmakuOn ? "captions.bubble.fill" : "captions.bubble")
                    }
                    .focused($focus, equals: .danmaku)
                    Button { open(.speed) } label: { Label(speedLabel(engine.rate), systemImage: "gauge.with.dots.needle.67percent") }
                        .focused($focus, equals: .speed)
                    Button { open(.quality) } label: { Label(engine.currentQuality?.label ?? "画质", systemImage: "sparkles.tv") }
                        .focused($focus, equals: .quality)
                        .disabled(engine.qualityOptions.count < 2)
                }
                .focusSection()
                // Up from the buttons puts the controls away and the remote back on the picture.
                .onMoveCommand { if $0 == .up { controlsVisible = false; focus = nil; surfaceFocus += 1 } }
            }
        }
        .padding(.horizontal, 90)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: Panels

    @ViewBuilder private func panelView(_ panel: Panel) -> some View {
        switch panel {
        case .episodes:
            EpisodePanel(session: session) { number in
                session.select(episode: number)
                close()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case .comments:
            if let episode = session.currentEpisode {
                CommentsSidePanel(seriesId: session.target.seriesId, vid: episode.vid) { close() }
            }
        case .speed:
            SidePanel(title: "倍速") {
                ForEach(Array(Self.rates.enumerated()), id: \.offset) { index, rate in
                    Button { session.setRate(rate); close() } label: {
                        HStack { Text(speedLabel(rate)); Spacer(); if rate == engine.rate { Image(systemName: "checkmark") } }
                    }
                    .focused($focus, equals: .panel(index))
                }
            }
        case .quality:
            SidePanel(title: "画质") {
                ForEach(Array(engine.qualityOptions.enumerated()), id: \.offset) { index, option in
                    Button {
                        app.library.settings.preferredQuality = option.shortSide
                        engine.selectQuality(option)
                        close()
                    } label: {
                        HStack { Text(option.label); Spacer(); if option == engine.currentQuality { Image(systemName: "checkmark") } }
                    }
                    .focused($focus, equals: .panel(index))
                }
            }
        }
    }

    private func speedLabel(_ rate: Float) -> String {
        rate == 1 ? "倍速" : String(format: rate == rate.rounded() ? "%.0fx" : "%gx", rate)
    }

    // MARK: Remote

    private func clickOrPlayKey() {
        if case .failed = engine.phase { engine.retry(); return }
        if engine.wantsPlayback && engine.isPlaying || engine.wantsPlayback && engine.phase != .ready {
            engine.pause()
            showControls()
        } else {
            engine.play()
            controlsVisible = false
        }
    }

    private func step(_ direction: Int) {
        engine.seek(to: engine.currentTime + Double(direction) * 10)
        showControls()
    }

    private func scrub(_ fraction: Double?) {
        guard engine.duration > 0 else { return }
        if let fraction {
            if scrubFrom == nil { scrubFrom = engine.currentTime }
            // A swipe across the whole surface moves a minute.
            scrubTo = min(max(0, (scrubFrom ?? 0) + fraction * 60), engine.duration)
            showControls()
        } else {
            if let target = scrubTo { engine.seek(to: target) }
            scrubFrom = nil
            scrubTo = nil
        }
    }

    private func swipeDown() {
        if controlsVisible { focus = .episodes } else { open(.episodes) }
    }

    private func back() {
        if panel != nil { close(); return }
        // The controls' buttons have the focus: put them away first.
        if focus != nil, controlsVisible { controlsVisible = false; focus = nil; surfaceFocus += 1; return }
        exit()
    }

    private func open(_ next: Panel) {
        panel = next
        controlsVisible = false
    }

    private func close() {
        panel = nil
        focus = nil
        surfaceFocus += 1
    }

    private func toggleDanmaku() {
        app.library.settings.danmaku.enabled.toggle()
        if app.library.settings.danmaku.enabled { session.reloadDanmakuIfNeeded() }
        showControls()
    }

    private func showControls() {
        controlsVisible = true
        controlsToken += 1
    }

    /// The controls fade after 5 s while the episode plays and nothing is being done with them.
    private func autoHide() async {
        guard controlsVisible, app.launch.route != .playerControls else { return }
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, engine.isPlaying, panel == nil, scrubTo == nil else { return }
        controlsVisible = false
        surfaceFocus += 1
    }

    private func exit() {
        session.close()
        app.closePlayer()
    }

    private func appeared() {
        switch app.launch.route {
        case .playerControls: controlsVisible = true
        case .playerEpisodes: panel = .episodes
        default: break
        }
        nowPlaying.start(play: { engine.play() }, pause: { engine.pause() }, toggle: { engine.togglePlay() },
                         skip: { engine.seek(to: engine.currentTime + $0) }, seek: { engine.seek(to: $0) },
                         next: { session.next() })
    }

    private func disappeared() {
        session.close()
        nowPlaying.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

}

/// 下一集 in the last 5 seconds of an episode with one after it; it takes the focus when it shows.
/// A view of its own, so only it follows the playback clock.
private struct NextEpisodeButton: View {
    let session: PlaybackSession
    var focus: FocusState<TVPlayerPage.Focus?>.Binding
    /// It went (the episode moved on): the picture takes the focus back.
    var gone: () -> Void

    var body: some View {
        let engine = session.engine
        let shows = engine.duration > 0 && engine.duration - engine.currentTime <= 5 && session.hasNext
            && (engine.phase == .ready || engine.phase == .offline)
        Group {
            if shows {
                Button { session.next() } label: { Label("下一集", systemImage: "forward.end.fill") }
                    .focused(focus, equals: .next)
            }
        }
        // It takes the focus when it shows and hands it back to the picture when it goes.
        .onChange(of: shows) { _, now in if now { focus.wrappedValue = .next } else { gone() } }
    }
}

/// Keeps the system's Now Playing in step: on play and pause, a new episode, and every 5 s.
private struct NowPlayingTicker: View {
    let session: PlaybackSession
    let nowPlaying: NowPlaying

    var body: some View {
        let engine = session.engine
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: engine.isPlaying, initial: true) { _, _ in update() }
            .onChange(of: session.episodeNumber) { _, _ in update() }
            .onChange(of: Int(engine.currentTime) / 5) { _, _ in update() }
    }

    private func update() {
        nowPlaying.update(title: session.title, episode: session.episodeNumber, engine: session.engine)
    }
}

/// The progress bar following the playback clock (or the scrub target).
private struct LiveProgress: View {
    let engine: PlayerEngine
    let scrubTo: Double?

    var body: some View {
        ProgressBar(current: scrubTo ?? engine.currentTime, buffered: engine.buffered, duration: engine.duration,
                    isScrubbing: scrubTo != nil)
    }
}

/// The playback position with what is buffered, and the times on either side.
struct ProgressBar: View {
    let current: Double
    let buffered: Double
    let duration: Double
    var isScrubbing = false

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let fraction = duration > 0 ? min(1, max(0, current / duration)) : 0
                let loaded = duration > 0 ? min(1, max(0, buffered / duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white.opacity(0.35)).frame(width: width * loaded)
                    Capsule().fill(Theme.accent).frame(width: width * fraction)
                    Circle().fill(.white).frame(width: isScrubbing ? 30 : 20, height: isScrubbing ? 30 : 20)
                        .offset(x: width * fraction - (isScrubbing ? 15 : 10))
                }
            }
            .frame(height: isScrubbing ? 14 : 10)
            HStack {
                Text(Self.clock(current)).monospacedDigit()
                Spacer()
                Text(Self.clock(duration)).monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A panel on the right side (倍速, 画质).
struct SidePanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.weight(.semibold))
            content
            Spacer()
        }
        .padding(48)
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .focusSection()
    }
}

/// 选集: the series' episodes in the shared ranges, twelve to a row, the one playing marked.
struct EpisodePanel: View {
    let session: PlaybackSession
    let choose: (Int) -> Void
    /// The range shown (following the episode playing), shared with the iOS 选集 panel.
    @State private var model: EpisodePanelModel
    @FocusState private var focusedEpisode: Int?

    init(session: PlaybackSession, choose: @escaping (Int) -> Void) {
        self.session = session
        self.choose = choose
        _model = State(initialValue: EpisodePanelModel(episode: session.episodeNumber, total: session.total))
    }

    private static var columns: [GridItem] { Array(repeating: GridItem(.fixed(96), spacing: 18), count: 12) }

    var body: some View {
        let ranges = model.ranges(total: session.total)
        let range = model.range(total: session.total) ?? 1...max(1, session.total)
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 24) {
                Text("选集").font(.title3.weight(.semibold))
                if ranges.count > 1 {
                    ForEach(Array(ranges.enumerated()), id: \.offset) { index, item in
                        Button(EpisodeRanges.label(item)) { model.rangeIndex = index }
                            .font(.callout.weight(index == model.rangeIndex ? .bold : .regular))
                    }
                }
            }
            .focusSection()
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
                ForEach(session.episodes.filter { range.contains($0.index) }) { episode in
                    EpisodeCell(number: episode.index, isCurrent: episode.index == session.episodeNumber,
                                isDisabled: episode.disabled) { choose(episode.index) }
                        .focused($focusedEpisode, equals: episode.index)
                }
            }
            .focusSection()
        }
        .padding(.horizontal, 90)
        .padding(.vertical, 50)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .onAppear {
            model.follow(episode: session.episodeNumber, total: session.total)
            // The episode playing takes focus, not the range buttons above it.
            DispatchQueue.main.async { focusedEpisode = session.episodeNumber }
        }
    }
}

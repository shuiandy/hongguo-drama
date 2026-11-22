import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI
import UIKit

/// The player: the shared `PlayerEngine` and `PlaybackSession` (episode order, resume, history,
/// prefetch, auto-advance), with a control layer drawn here for the Siri Remote.
///
/// A 9:16 episode fills the height, centred and never cropped, over the cover's colour blurred
/// on both sides. The remote works in three layers, one at a time, and Back always goes one
/// layer out:
///
/// 1. The picture alone. The centre click or the play key pauses and brings the controls in;
///    a click on the ring's left or right goes back or forward 10 s and flashes the progress
///    bar; up or down (clicked or swiped) brings the controls in; Back leaves the player.
///    Sliding a finger left or right does nothing, so the position never moves by accident.
/// 2. The controls: the progress bar and, under it, one row of buttons. The focus engine moves
///    between them. Only while the progress bar itself has the focus do left and right change
///    the position (10 s a step); on the buttons they move between the buttons. Back puts the
///    controls away.
/// 3. A panel (选集, 评论, 倍速, 画质). Back closes it.
struct TVPlayerPage: View {
    let app: TVAppModel
    @State private var session: PlaybackSession
    @State private var controlsVisible = false
    @State private var controlsToken = 0
    /// The progress bar alone, shown for a moment after a ±10 s click on the picture.
    @State private var hudVisible = false
    @State private var hudToken = 0
    @State private var panel: Panel?
    @State private var tint = Color.gray
    @State private var nowPlaying = NowPlaying()
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: Focus?
    /// Bumped to hand the focus back to the picture (the remote surface) when what had it goes.
    @State private var surfaceFocus = 0
    /// 下一集 is on screen (kept here by the button, so the page does not follow the clock).
    @State private var nextShows = false

    enum Panel: Equatable { case episodes, speed, quality, comments }
    /// The same choices as the iOS player's speed menu.
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2, 3]
    enum Focus: Hashable { case scrubber, next, episodes, comments, danmaku, speed, quality, panel(Int) }

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
                // Priority 1 as on the iOS player page: over the feed's surface under it.
                VideoSurface(engine: engine, priority: 1)
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
                // Focusable only while the picture is alone: with the controls, a panel or 下一集
                // up, the focus engine moves between what is drawn and nothing here listens.
                // (SwiftUI cannot take the focus from this UIKit view, so it lets go itself.)
                RemoteSurface(isActive: panel == nil && !controlsVisible && !nextShows, focusRequest: surfaceFocus,
                              onSelect: clickOrPlayKey, onStep: { step($0) }, onReveal: reveal, onMenu: back)
                    .ignoresSafeArea()
                if hudVisible, !controlsVisible, panel == nil {
                    hud
                        .transition(.opacity)
                }
                if controlsVisible {
                    controls
                        .transition(.opacity)
                }
                if panel == nil {
                    NextEpisodeButton(session: session, focus: $focus, mayTakeFocus: { !controlsVisible && panel == nil }, showing: { nextShows = $0 }) { surfaceFocus += 1 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 90).padding(.bottom, controlsVisible ? 330 : 90)
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
        .animation(.easeInOut(duration: 0.25), value: hudVisible)
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
        .task(id: hudToken) {
            guard hudVisible else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { hudVisible = false }
        }
        // Moving between the controls counts as using them: the 5 s start again.
        .onChange(of: focus) { _, _ in if controlsVisible { controlsToken += 1 } }
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

    /// After a ±10 s click on the picture: the progress bar alone for a moment. It takes no focus.
    private var hud: some View {
        VStack {
            Spacer()
            LiveProgress(engine: engine)
        }
        .padding(.horizontal, 90)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The controls: the title on top, the progress bar and one row of buttons at the bottom.
    /// The progress bar and the buttons are ordinary focus items, each the full width of its
    /// row's section, so down from the bar always reaches the buttons and up always returns.
    private var controls: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.title).font(.title2.weight(.bold)).lineLimit(1)
                    if session.total > 0 {
                        Text("第\(session.episodeNumber)集 / 共\(session.total)集").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label("返回键收起，再按一次退出播放", systemImage: "chevron.backward")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 10) {
                    Button(action: clickOrPlayKey) {
                        LiveTrack(engine: engine, isFocused: focus == .scrubber)
                    }
                    .buttonStyle(ScrubberButtonStyle())
                    .focused($focus, equals: .scrubber)
                    // Left and right change the position only here, while the bar has the focus.
                    // On the simulator down from the bar did not reach the buttons once it had a
                    // move handler (why is not established: on 推荐 up still reaches the tab bar
                    // past one), so down is passed on to the buttons here.
                    .onMoveCommand { direction in
                        switch direction {
                        case .left: step(-1)
                        case .right: step(1)
                        case .down: focus = .episodes
                        default: break
                        }
                    }
                    .accessibilityLabel("进度条")
                    LiveClock(engine: engine)
                        .padding(.leading, LiveTrack.glyphWidth)
                }
                .frame(maxWidth: .infinity)
                .focusSection()
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
                // The whole width, so down from anywhere on the bar lands in the row.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                Text(focus == .scrubber ? "左右：后退或前进 10 秒　按下：播放或暂停　向下：更多选项" : "向上：回到进度条")
                    .font(.caption).foregroundStyle(.tertiary)
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

    private var isPlayingOrStarting: Bool {
        engine.wantsPlayback && engine.isPlaying || engine.wantsPlayback && engine.phase != .ready
    }

    /// The centre click (on the picture or on the progress bar) and the play key anywhere.
    private func clickOrPlayKey() {
        if case .failed = engine.phase { engine.retry(); return }
        if isPlayingOrStarting {
            engine.pause()
            showControls(focusing: .scrubber)
        } else {
            engine.play()
            hideControls()
        }
    }

    /// Back or forward 10 s: from the picture (a click on the ring's side, which flashes the
    /// progress bar) or from the progress bar while it has the focus.
    private func step(_ direction: Int) {
        engine.seek(to: engine.currentTime + Double(direction) * 10)
        if controlsVisible {
            controlsToken += 1
        } else {
            hudVisible = true
            hudToken += 1
        }
    }

    /// Up or down on the picture: the controls, with the focus on the buttons.
    private func reveal() {
        guard !controlsVisible, panel == nil else { return }
        showControls(focusing: .episodes)
    }

    /// One layer out: a panel closes, then the controls go, then the player.
    private func back() {
        if panel != nil { close(); return }
        if controlsVisible { hideControls(); return }
        exit()
    }

    private func open(_ next: Panel) {
        panel = next
        controlsVisible = false
        // 倍速 and 画质 open on the choice in use.
        let chosen: Int?
        switch next {
        case .speed: chosen = Self.rates.firstIndex(of: engine.rate) ?? 0
        case .quality: chosen = engine.currentQuality.flatMap { engine.qualityOptions.firstIndex(of: $0) } ?? 0
        default: chosen = nil
        }
        if let chosen { settleFocus(on: .panel(chosen)) { panel == next } }
    }

    private func close() {
        panel = nil
        returnToPicture()
    }

    private func toggleDanmaku() {
        app.library.settings.danmaku.enabled.toggle()
        if app.library.settings.danmaku.enabled { session.reloadDanmakuIfNeeded() }
        controlsToken += 1
    }

    /// Shows the controls. When the focus is on the picture it goes to `target`; when it is
    /// already on one of the controls it stays where it is.
    private func showControls(focusing target: Focus) {
        let wasVisible = controlsVisible
        controlsVisible = true
        hudVisible = false
        controlsToken += 1
        if !wasVisible || focus == nil { settleFocus(on: target) { controlsVisible } }
    }

    private func hideControls() {
        guard controlsVisible else { return }
        controlsVisible = false
        returnToPicture()
    }

    /// The focus goes back to the picture, or to 下一集 while it shows.
    private func returnToPicture() {
        if nextIsDue {
            focus = .next
        } else {
            focus = nil
            surfaceFocus += 1
        }
    }

    /// As `NextEpisodeButton` decides it; read here only when asked, so the page does not follow
    /// the playback clock.
    private var nextIsDue: Bool {
        engine.duration > 0 && engine.duration - engine.currentTime <= 5 && session.hasNext
            && (engine.phase == .ready || engine.phase == .offline)
    }

    /// Puts the focus on a control that is only now coming on screen: asked for once it is drawn,
    /// and again for a moment if nothing has taken the focus yet.
    private func settleFocus(on target: Focus, while stillWanted: @escaping () -> Bool) {
        Task { @MainActor in
            for attempt in 0..<6 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 50 : 120))
                guard stillWanted() else { return }
                if attempt > 0, focus != nil { return }
                focus = target
            }
        }
    }

    /// The controls fade after 5 s while the episode plays and nothing is being done with them.
    private func autoHide() async {
        guard controlsVisible, app.launch.route != .playerControls else { return }
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, engine.isPlaying, panel == nil else { return }
        hideControls()
    }

    private func exit() {
        session.close()
        app.closePlayer()
    }

    private func appeared() {
        switch app.launch.route {
        case .playerControls: showControls(focusing: .scrubber)
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
    /// True while only the picture shows (no controls, no panel): then the button may take the focus.
    var mayTakeFocus: () -> Bool
    /// Tells the page whether the button is on screen.
    var showing: (Bool) -> Void
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
        // It takes the focus from the picture when it shows (not from a control in use) and
        // hands it back to the picture when it goes.
        .onChange(of: shows) { _, now in
            showing(now)
            if now { takeFocus() } else { gone() }
        }
    }

    /// The button is only now being drawn: ask for the focus once it is, and again for a moment
    /// until it has it.
    private func takeFocus() {
        Task { @MainActor in
            for attempt in 0..<6 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 50 : 120))
                guard mayTakeFocus(), focus.wrappedValue != .next else { return }
                focus.wrappedValue = .next
            }
        }
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

/// The progress bar with its times, following the playback clock; for the moment after a skip.
private struct LiveProgress: View {
    let engine: PlayerEngine

    var body: some View {
        VStack(spacing: 10) {
            ProgressTrack(current: engine.currentTime, buffered: engine.buffered, duration: engine.duration)
            ClockRow(current: engine.currentTime, duration: engine.duration)
        }
    }
}

/// The progress bar as a focus item: play or pause on the left, then the track, which grows
/// and lights up while it has the focus.
private struct LiveTrack: View {
    static let glyphWidth: CGFloat = 76
    let engine: PlayerEngine
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: engine.wantsPlayback ? "pause.fill" : "play.fill")
                .font(.title3)
                .foregroundStyle(isFocused ? .primary : .secondary)
                .frame(width: Self.glyphWidth, alignment: .leading)
            ProgressTrack(current: engine.currentTime, buffered: engine.buffered, duration: engine.duration, isFocused: isFocused)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// The times under the track, outside the focus item so they stay readable as text.
private struct LiveClock: View {
    let engine: PlayerEngine

    var body: some View {
        ClockRow(current: engine.currentTime, duration: engine.duration)
    }
}

/// The progress bar's focus item draws itself (the track grows); no system platter around it.
private struct ScrubberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The playback position with what is buffered.
struct ProgressTrack: View {
    let current: Double
    let buffered: Double
    let duration: Double
    var isFocused = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = duration > 0 ? min(1, max(0, current / duration)) : 0
            let loaded = duration > 0 ? min(1, max(0, buffered / duration)) : 0
            let knob: CGFloat = isFocused ? 34 : 18
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(isFocused ? 0.3 : 0.18))
                Capsule().fill(.white.opacity(0.35)).frame(width: width * loaded)
                Capsule().fill(Theme.accent).frame(width: width * fraction)
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(color: .white.opacity(isFocused ? 0.6 : 0), radius: 12)
                    .offset(x: width * fraction - knob / 2)
            }
            .frame(height: isFocused ? 16 : 8)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 34)
    }
}

struct ClockRow: View {
    let current: Double
    let duration: Double

    var body: some View {
        HStack {
            Text(Self.clock(current)).monospacedDigit()
            Spacer()
            Text(Self.clock(duration)).monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// What every panel says about leaving it.
struct BackHint: View {
    var body: some View {
        Label("返回键关闭", systemImage: "chevron.backward").font(.caption).foregroundStyle(.secondary)
    }
}

/// A panel on the right side (倍速, 画质).
struct SidePanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                BackHint()
            }
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
                Spacer()
                BackHint()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
                ForEach(session.episodes.filter { range.contains($0.index) }) { episode in
                    EpisodeCell(number: episode.index, isCurrent: episode.index == session.episodeNumber,
                                isDisabled: episode.disabled) { choose(episode.index) }
                        .focused($focusedEpisode, equals: episode.index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        .padding(.horizontal, 90)
        .padding(.vertical, 50)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .onAppear {
            model.follow(episode: session.episodeNumber, total: session.total)
            // The episode playing takes focus, not the range buttons above it.
            for delay in [0.0, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if focusedEpisode == nil { focusedEpisode = session.episodeNumber }
                }
            }
        }
    }
}

import AVKit
import SwiftUI
import HongguoCore

// Liquid Glass player UI (second design): a video stage with ambient light and an always-reachable
// glass control bar, plus a right panel with 选集 / 简介 / 评论 tabs. The video is a bare AVPlayerLayer;
// all controls are drawn here and bound to PlayerController.

// MARK: Video surface

/// AVPlayerLayer host.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    final class SurfaceView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.clear.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
    }
}

// MARK: Overlays

struct PlayerOverlays: View {
    let controller: PlayerController
    var compact = false

    var body: some View {
        ZStack {
            if controller.isLoading || (controller.isBuffering && controller.errorMessage == nil) {
                VStack(spacing: 10) {
                    ProgressView().controlSize(compact ? .regular : .large)
                    if !compact {
                        Text(controller.isLoading ? controller.loadingText : "缓冲中…")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(compact ? 12 : 20)
                .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if let error = controller.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: compact ? 20 : 28)).foregroundStyle(Color.hongguoGold)
                    Text(error)
                        .font(.system(size: compact ? 11 : 13))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .frame(maxWidth: compact ? 200 : 340)
                        .lineLimit(compact ? 3 : nil)
                    HStack(spacing: 8) {
                        Button("重试") { controller.retry() }.buttonStyle(GlassButtonStyle(prominent: true, size: .small))
                        if controller.hasNext {
                            Button("下一集") { controller.next() }.buttonStyle(GlassButtonStyle(size: .small))
                        }
                    }
                }
                .padding(compact ? 14 : 22)
                .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(12)
            }
            if let toast = controller.toast {
                Text(toast)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, compact ? 12 : 16)
                    .frame(height: compact ? 28 : 34)
                    .glassSurface(in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, compact ? 44 : 64)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: controller.toast)
        .allowsHitTesting(controller.errorMessage != nil)
    }
}

// MARK: Scrubber

/// Timeline with buffered range; drag or click to seek; shows the time under the pointer while hovering.
struct Scrubber: View {
    let controller: PlayerController
    var thin = false
    @State private var dragFraction: Double?
    @State private var hoverFraction: Double?

    private var progress: Double {
        controller.duration > 0 ? min(1, max(0, controller.currentTime / controller.duration)) : 0
    }

    private var buffered: Double {
        controller.duration > 0 ? min(1, max(0, controller.bufferedTime / controller.duration)) : 0
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let fraction = dragFraction ?? progress
            let active = hoverFraction != nil || dragFraction != nil
            let height: CGFloat = thin ? 4 : (active ? 8 : 6)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.35)).frame(width: width * buffered)
                Capsule().fill(.white).frame(width: max(height, width * fraction))
                if !thin && active {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                        .offset(x: width * fraction - 7)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if !thin, let preview = dragFraction ?? hoverFraction, controller.duration > 0 {
                    Text(formatClock(preview * controller.duration))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .glassSurface(in: Capsule())
                        .fixedSize()
                        .position(x: min(max(24, width * preview), width - 24), y: -12)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverFraction = min(1, max(0, location.x / width))
                case .ended: hoverFraction = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragFraction = min(1, max(0, value.location.x / width)) }
                    .onEnded { value in
                        controller.seek(fraction: min(1, max(0, value.location.x / width)))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: thin ? 10 : 22)
        .animation(.easeOut(duration: 0.12), value: hoverFraction != nil || dragFraction != nil)
    }
}

// MARK: Main player window

/// Main player window: ambient stage with the video and control bar, right panel with tabs.
struct PlayerScreen: View {
    let controller: PlayerController
    let windows: PlayerWindows
    @State private var chromeVisible = true
    @State private var hoveringBar = false
    @State private var hideTask: Task<Void, Never>?
    /// Whether the pointer is over the video area.
    @State private var pointerInside = false
    /// The next episode started while the pointer was elsewhere (autoplay): keep the controls
    /// hidden through the switch so playback feels continuous, until the pointer comes back.
    @State private var quietTransition = false

    /// Controls stay up while paused, loading, buffering, failed, or while the pointer is on them.
    private var showChrome: Bool {
        if quietTransition, controller.errorMessage == nil { return hoveringBar }
        return chromeVisible || hoveringBar || !controller.isPlaying || controller.isLoading || controller.isBuffering
            || controller.errorMessage != nil || !controller.hasItem
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                stage
                if windows.showEpisodes {
                    PlayerSidePanel(controller: controller, windows: windows)
                        .frame(width: PlayerWindows.episodePanelWidth - 24)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Backdrop goes in the background so it can never size the layout.
        .background {
            ZStack {
                Color.black
                if !controller.cover.isEmpty {
                    AmbientBackdrop(url: controller.cover, blur: 110, opacity: 0.6)
                        .overlay(RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 120, endRadius: 800))
                }
            }
        }
        .clipped()
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .tint(.hongguoRed)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: windows.showEpisodes)
    }

    private var stage: some View {
        ZStack {
            VideoSurface(player: controller.player, gravity: controller.fillMode.gravity)
            DanmakuOverlay(controller: controller, bottomInset: 130, active: !windows.isMini)
            // Click toggles play, double click toggles full screen.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { windows.toggleFullScreen() }
                .onTapGesture { controller.togglePlay() }
            PlayerOverlays(controller: controller)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                PlayerControlBar(controller: controller, windows: windows)
                    .onHover { hoveringBar = $0 }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .opacity(showChrome ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showChrome)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            switch phase {
            case .active: pointerInside = true; revealChrome()
            case .ended: pointerInside = false; hideChrome(after: 0.6)
            }
        }
        // Playback starting (or the next episode) shows the controls, then hides them after 5 s
        // even if the pointer never moves.
        .onChange(of: controller.isPlaying) { _, playing in
            guard playing else { return }
            if quietTransition {
                quietTransition = false
                chromeVisible = false
            } else {
                chromeVisible = true
                hideChrome(after: 5)
            }
        }
        .onChange(of: controller.index) { _, _ in
            if pointerInside, NSApp.isActive {
                quietTransition = false
                chromeVisible = true
                hideChrome(after: 5)
            } else {
                hideTask?.cancel()
                chromeVisible = false
                quietTransition = true
            }
        }
        .onAppear { hideChrome(after: 5) }
    }

    private var topBar: some View {
        ZStack {
            WindowDragArea { NSApp.keyWindow?.zoom(nil) }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(controller.episodes?.title ?? controller.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let total = controller.episodes?.total, controller.index > 0 {
                        Text("第 \(controller.index) 集 / \(total)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .glassSurface(in: Capsule())
                .allowsHitTesting(false)
                Spacer()
                if !windows.showEpisodes {
                    Button { windows.toggleEpisodes() } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(GlassIconButtonStyle(diameter: 32))
                        .help("显示选集（E）")
                }
            }
            .padding(.leading, 84) // traffic lights
            .padding(.trailing, 14)
        }
        .frame(height: 48)
    }

    private func revealChrome() {
        quietTransition = false
        chromeVisible = true
        hideChrome(after: 3)
    }

    private func hideChrome(after delay: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            chromeVisible = false
        }
    }
}

/// Glass control bar: timeline on top; transport, episode label and settings below.
struct PlayerControlBar: View {
    let controller: PlayerController
    let windows: PlayerWindows
    @State private var showDanmakuSettings = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text(formatClock(controller.currentTime)).foregroundStyle(.white.opacity(0.9))
                Scrubber(controller: controller)
                Text(formatClock(controller.duration)).foregroundStyle(.white.opacity(0.65))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())

            ViewThatFits(in: .horizontal) {
                controlsRow(showLabel: true, showVolumeSlider: true)
                controlsRow(showLabel: false, showVolumeSlider: true)
                controlsRow(showLabel: false, showVolumeSlider: false)
                compactRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func controlsRow(showLabel: Bool, showVolumeSlider: Bool) -> some View {
        HStack(spacing: 4) {
            Button { controller.previous() } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(BarIconButtonStyle(size: 34))
                .disabled(!controller.hasPrevious)
                .help("上一集（↑）")
            Button { controller.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                .buttonStyle(BarIconButtonStyle(size: 34))
                .help("后退 10 秒")
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 46, variant: .clear))
            .help("播放 / 暂停（空格）")
            Button { controller.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                .buttonStyle(BarIconButtonStyle(size: 34))
                .help("前进 10 秒")
            Button { controller.next() } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(BarIconButtonStyle(size: 34))
                .disabled(!controller.hasNext)
                .help("下一集（↓）")

            if showLabel, controller.index > 0 {
                Divider().frame(height: 22).padding(.horizontal, 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("第 \(controller.index) 集").font(.system(size: 13, weight: .bold))
                    Text(controller.episodes?.title ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 160, alignment: .leading)
            }

            if let episode = controller.currentEpisode {
                PlayerSocialButtons(controller: controller, episode: episode)
            }

            Spacer(minLength: 8)

            Button { controller.toggleMute() } label: {
                Image(systemName: volumeSymbol)
            }
            .buttonStyle(BarIconButtonStyle(size: 32))
            .help(controller.isMuted ? "取消静音" : "静音")
            if showVolumeSlider {
                Slider(value: Binding(get: { Double(controller.isMuted ? 0 : controller.volume) },
                                      set: { value in
                                          controller.volume = Float(value)
                                          if value > 0, controller.isMuted { controller.isMuted = false }
                                      }), in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 84)
                    .padding(.trailing, 6)
                    .help("音量")
            }

            Menu {
                ForEach(PlayerController.rateOptions, id: \.self) { value in
                    Button { controller.rate = value } label: {
                        if value == controller.rate { Label(formatRate(value), systemImage: "checkmark") } else { Text(formatRate(value)) }
                    }
                }
                Divider()
                Text("按住空格临时 2x")
            } label: {
                pill(formatRate(controller.rate))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("倍速（S / D）")

            let danmakuOn = AppModel.shared.settings.danmaku.enabled
            Button { AppModel.shared.settings.danmaku.enabled.toggle() } label: {
                Image(systemName: danmakuOn ? "text.bubble.fill" : "text.bubble")
            }
            .buttonStyle(BarIconButtonStyle(size: 32, active: danmakuOn))
            .help(danmakuOn ? "关闭弹幕" : "打开弹幕")
            .contextMenu { Button("弹幕设置…") { showDanmakuSettings = true } }
            Button { showDanmakuSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(BarIconButtonStyle(size: 28))
                .help("弹幕设置")
                .popover(isPresented: $showDanmakuSettings, arrowEdge: .top) { DanmakuSettingsPanel() }

            if !controller.qualityOptions.isEmpty {
                Menu {
                    Button { controller.preferredQuality = nil } label: {
                        if controller.preferredQuality == nil { Label("自动", systemImage: "checkmark") } else { Text("自动") }
                    }
                    Divider()
                    ForEach(controller.qualityOptions) { option in
                        Button { controller.preferredQuality = option.id } label: {
                            if controller.preferredQuality == option.id { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                        }
                    }
                } label: {
                    pill(controller.preferredQuality == nil ? "自动 \(controller.currentQuality?.label ?? "")" : (controller.currentQuality?.label ?? "画质"))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("画质")
            }

            Menu {
                ForEach(VideoFillMode.allCases) { mode in
                    Button { controller.setFillMode(mode) } label: {
                        if mode == controller.fillMode { Label(fillModeTitle(mode), systemImage: "checkmark") } else { Text(fillModeTitle(mode)) }
                    }
                }
            } label: {
                Image(systemName: fillModeSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("画面模式：\(controller.fillMode.label)")

            Button { controller.toggleAutoNext() } label: { Image(systemName: "repeat") }
                .buttonStyle(BarIconButtonStyle(size: 32, active: controller.autoNext))
                .help(controller.autoNext ? "自动连播：开（A）" : "自动连播：关（A）")
            Button { windows.togglePin() } label: { Image(systemName: windows.isPinned ? "pin.fill" : "pin") }
                .buttonStyle(BarIconButtonStyle(size: 32, active: windows.isPinned))
                .help(windows.isPinned ? "取消置顶（M）" : "置顶播放器，所有控制都在（M）")
            Button { windows.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(BarIconButtonStyle(size: 32))
                .help("全屏（F）")
        }
    }

    /// For a small pinned window: transport, like / favourite, speed, danmaku, pin and full screen.
    private var compactRow: some View {
        HStack(spacing: 2) {
            Button { controller.previous() } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(BarIconButtonStyle(size: 30))
                .disabled(!controller.hasPrevious)
                .help("上一集（↑）")
            Button { controller.togglePlay() } label: { Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill") }
                .buttonStyle(GlassIconButtonStyle(diameter: 40, variant: .clear))
                .help("播放 / 暂停（空格）")
            Button { controller.next() } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(BarIconButtonStyle(size: 30))
                .disabled(!controller.hasNext)
                .help("下一集（↓）")
            if let episode = controller.currentEpisode {
                PlayerSocialButtons(controller: controller, episode: episode, size: 30)
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(PlayerController.rateOptions, id: \.self) { value in
                    Button { controller.rate = value } label: {
                        if value == controller.rate { Label(formatRate(value), systemImage: "checkmark") } else { Text(formatRate(value)) }
                    }
                }
            } label: { pill(formatRate(controller.rate)) }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("倍速（S / D）")
            let danmakuOn = AppModel.shared.settings.danmaku.enabled
            Button { AppModel.shared.settings.danmaku.enabled.toggle() } label: {
                Image(systemName: danmakuOn ? "text.bubble.fill" : "text.bubble")
            }
            .buttonStyle(BarIconButtonStyle(size: 30, active: danmakuOn))
            .help(danmakuOn ? "关闭弹幕" : "打开弹幕")
            Button { windows.togglePin() } label: { Image(systemName: windows.isPinned ? "pin.fill" : "pin") }
                .buttonStyle(BarIconButtonStyle(size: 30, active: windows.isPinned))
                .help(windows.isPinned ? "取消置顶（M）" : "置顶播放器（M）")
            Button { windows.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(BarIconButtonStyle(size: 30))
                .help("全屏（F）")
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.white.opacity(0.13), in: Capsule())
            .contentShape(Capsule())
    }

    private var volumeSymbol: String {
        if controller.isMuted || controller.volume == 0 { return "speaker.slash.fill" }
        return controller.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    private var fillModeSymbol: String {
        switch controller.fillMode {
        case .fit: return "rectangle.center.inset.filled"
        case .fill: return "rectangle.inset.filled"
        case .stretch: return "arrow.left.and.right.square"
        }
    }

    private func fillModeTitle(_ mode: VideoFillMode) -> String {
        switch mode {
        case .fit: return "适应窗口（保持比例）"
        case .fill: return "填满窗口（裁掉边缘）"
        case .stretch: return "拉伸铺满"
        }
    }
}

// MARK: Right panel

/// Right panel of the player: 选集 / 简介 / 评论.
struct PlayerSidePanel: View {
    enum Tab: Hashable, Sendable { case episodes, info, reviews }

    let controller: PlayerController
    let windows: PlayerWindows
    @State private var tab: Tab = .episodes
    @State private var details: PublicDetails?
    @State private var reviewScope: ReviewScope = .series
    @State private var episodeComments: EpisodeComments?
    @State private var episodeCommentsError = ""

    enum ReviewScope: Hashable, Sendable { case series, episode }
    private static let episodeCommentService = EpisodeCommentService()

    private var record: WatchRecord? {
        guard let id = controller.episodes?.seriesId else { return nil }
        return AppModel.shared.history.first { $0.seriesId == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                GlassSegments(options: [GlassOption(label: "选集", value: Tab.episodes),
                                        GlassOption(label: "简介", value: Tab.info),
                                        GlassOption(label: reviewTabTitle, value: Tab.reviews)],
                              selection: $tab)
                Spacer(minLength: 0)
                Button { windows.toggleEpisodes() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(GlassIconButtonStyle(diameter: 34, variant: .clear))
                    .help("收起面板（E）")
            }

            switch tab {
            case .episodes: episodesTab
            case .info: infoTab
            case .reviews: reviewsTab
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task(id: controller.episodes?.seriesId) {
            details = nil
            guard let id = controller.episodes?.seriesId, SourceRouter.isHongguo(id) else { return }
            details = try? await AppModel.shared.series.publicDetails(seriesId: id)
        }
        .task(id: "\(controller.episodes?.seriesId ?? ""):\(controller.currentEpisode?.vid ?? ""):\(tab == .reviews && reviewScope == .episode)") {
            await loadEpisodeComments()
        }
    }

    private var reviewTabTitle: String {
        if let total = details?.reviewTotal, total > 0 { return "评论 \(formatCount(total))" }
        return "评论"
    }

    // MARK: 选集

    private var seriesHeader: some View {
        HStack(spacing: 12) {
            CoverImage(url: controller.cover, cornerRadius: 12).frame(width: 60, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.episodes?.title ?? "加载中").font(.system(size: 17, weight: .bold)).lineLimit(2)
                Text(progressLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var progressLine: String {
        var parts: [String] = []
        if let total = controller.episodes?.total, controller.index > 0 { parts.append("第 \(controller.index) / \(total) 集") }
        if let rating = details?.rating, rating > 0 { parts.append(String(format: "%.1f 分", rating)) }
        return parts.joined(separator: " · ")
    }

    private var episodesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            seriesHeader
            ScrollView {
                if let episodes = controller.episodes {
                    EpisodeGrid(episodes: episodes.episodes,
                                current: controller.index,
                                completed: record?.completedEpisode ?? 0,
                                minimumCellWidth: 48) { episode in
                        controller.play(index: episode.index)
                    }
                    .padding(2)
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            if controller.hasNext, let list = controller.episodes {
                upNext(list.episodes[controller.index])
            }
        }
    }

    private func upNext(_ episode: Episode) -> some View {
        HStack(spacing: 12) {
            Button { controller.next() } label: {
                ZStack {
                    CoverImage(url: controller.cover, cornerRadius: 10).brightness(-0.25)
                    Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 48, height: 64)
            }
            .buttonStyle(.plain)
            .help("播放第 \(episode.index) 集")
            VStack(alignment: .leading, spacing: 2) {
                Text("接下来").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("第 \(episode.index) 集").font(.system(size: 14, weight: .bold))
                Text(controller.autoNext ? "本集结束后自动播放" : "自动连播已关闭").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("自动连播", isOn: Binding(get: { controller.autoNext }, set: { controller.autoNext = $0 }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.hongguoRed)
                .controlSize(.small)
        }
        .padding(12)
        .glassSurface(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: 简介

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    CoverImage(url: controller.cover, cornerRadius: 14).frame(width: 96, height: 128)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(controller.episodes?.title ?? "").font(.system(size: 20, weight: .heavy)).lineLimit(3)
                        FlowLayout(spacing: 6) {
                            if let rating = details?.rating, rating > 0 {
                                GlassTag(text: String(format: "%.1f", rating), systemImage: "star.fill", iconColor: .hongguoGold)
                            }
                            if let likes = details?.likeCount { GlassTag(text: formatCount(likes), systemImage: "heart.fill", iconColor: .hongguoRed) }
                            if let label = details?.episodeLabel, !label.isEmpty { GlassTag(text: label) }
                        }
                    }
                }
                if let description = details?.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                } else if details == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 12) {
                    infoCell("当前集", controller.index > 0 ? "第 \(controller.index) 集 · \(formatClock(controller.duration))" : "未开始")
                    infoCell("片源", controller.currentSource.map(sourceName) ?? "未知")
                    infoCell("观看进度", "\(record?.completedEpisode ?? 0) / \(controller.episodes?.total ?? 0) 集")
                    infoCell("播放方式", controller.pipeline.map(pipelineName) ?? "未知")
                    if let ms = controller.startupMilliseconds { infoCell("起播耗时", "\(ms) ms") }
                    if controller.videoSize.height > 1 {
                        infoCell("分辨率", "\(Int(controller.videoSize.width))×\(Int(controller.videoSize.height))")
                    }
                }
                .padding(14)
                .glassSurface(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(2)
        }
        .scrollIndicators(.never)
    }

    private func infoCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
    }

    // MARK: 评论

    private var reviewsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSegments(options: [GlassOption(label: "全剧", value: ReviewScope.series),
                                    GlassOption(label: episodeScopeTitle, value: ReviewScope.episode)],
                          selection: $reviewScope)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    switch reviewScope {
                    case .series: seriesReviews
                    case .episode: episodeReviews
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.never)
        }
    }

    private var episodeScopeTitle: String {
        guard controller.index > 0 else { return "本集" }
        if let total = episodeComments?.total, total > 0, episodeComments?.vid == controller.currentEpisode?.vid {
            return "第 \(controller.index) 集 \(formatCount(total))"
        }
        return "第 \(controller.index) 集"
    }

    @ViewBuilder
    private var seriesReviews: some View {
        if let reviews = details?.reviews, !reviews.isEmpty {
            ForEach(reviews) { review in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        CoverImage(url: review.avatar, cornerRadius: 12).frame(width: 24, height: 24)
                        Text(review.author.isEmpty ? "匿名用户" : review.author).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let likes = review.likes, likes > 0 {
                            Label(formatCount(likes), systemImage: "hand.thumbsup").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    EmoticonText(review.content, size: 13).lineSpacing(3).textSelection(.enabled)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else if details == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            Text("暂无评论").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    @ViewBuilder
    private var episodeReviews: some View {
        let vid = controller.currentEpisode?.vid
        if let comments = episodeComments, comments.vid == vid {
            if let likes = comments.likeCount, likes > 0 {
                Label("本集 \(formatCount(likes)) 人点赞", systemImage: "heart.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if comments.items.isEmpty {
                Text("本集暂无公开评论").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
            }
            ForEach(comments.items) { item in
                EmoticonText(item.content, size: 13).lineSpacing(3).textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Text(comments.notice).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 4)
        } else if !episodeCommentsError.isEmpty {
            Text(episodeCommentsError).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
        } else if vid == nil {
            Text("开始播放后显示本集评论").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    private func loadEpisodeComments() async {
        guard tab == .reviews, reviewScope == .episode,
              let seriesId = controller.episodes?.seriesId, let vid = controller.currentEpisode?.vid else { return }
        if episodeComments?.vid == vid { return }
        episodeCommentsError = ""
        guard WatchHistory.source(of: seriesId) == .hongguo else {
            episodeCommentsError = "这个片源没有本集评论"
            return
        }
        do {
            let result = try await Self.episodeCommentService.comments(seriesId: seriesId, vid: vid)
            guard !Task.isCancelled else { return }
            episodeComments = result
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            episodeCommentsError = (error as? HongguoError)?.message ?? "本集评论加载失败，请稍后重试"
        }
    }

    private func sourceName(_ source: PlaySource) -> String {
        switch source {
        case .web: return "官网"
        case .api: return "旧接口"
        case .app: return "App"
        }
    }

    private func pipelineName(_ pipeline: PlaybackPipeline) -> String {
        switch pipeline {
        case .stream: return "直连"
        case .progressiveDecrypt: return "边下边解"
        case .decryptedFile: return "解密缓存"
        case .localFile: return "本地文件"
        }
    }
}

/// 点赞 (this episode) and 收藏 (the series), showing this Mac's state and the account's.
struct PlayerSocialButtons: View {
    let controller: PlayerController
    let episode: Episode
    var size: CGFloat = 32

    var body: some View {
        let model = AppModel.shared
        let title = controller.episodes?.title ?? controller.title
        let liked = model.isEpisodeLikedAnywhere(seriesId: episode.seriesId, vid: episode.vid, index: episode.index)
        let favorite = model.isFavoriteAnywhere(episode.seriesId)
        let account = AccountState.shared.profile != nil && model.settings.accountWriteSync && SourceRouter.isHongguo(episode.seriesId)
        HStack(spacing: 2) {
            Button {
                model.setEpisodeLike(!liked, seriesId: episode.seriesId, title: title, vid: episode.vid, index: episode.index)
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart").foregroundStyle(liked ? Color.hongguoRed : Color.white)
            }
            .buttonStyle(BarIconButtonStyle(size: size, active: liked))
            .help(liked ? "取消点赞本集" : (account ? "点赞本集（同步到账号）" : "点赞本集"))
            Button {
                model.setFavorite(!favorite, seriesId: episode.seriesId, title: title, cover: controller.cover)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.hongguoGold : Color.white)
            }
            .buttonStyle(BarIconButtonStyle(size: size, active: favorite))
            .help(favorite ? "取消收藏" : (account ? "收藏这部剧（同步到账号）" : "收藏这部剧"))
        }
    }
}

// MARK: Mini window

/// Content of the borderless floating window: just the video at rest, glass controls on hover.
struct MiniPlayerView: View {
    let controller: PlayerController
    let windows: PlayerWindows
    @State private var hovering = false

    private var progress: Double {
        controller.duration > 0 ? min(1, max(0, controller.currentTime / controller.duration)) : 0
    }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: controller.player, gravity: controller.fillMode.gravity)
            // Same danmaku as the player window, same size; it stays clear of the controls on hover.
            DanmakuOverlay(controller: controller, bottomInset: hovering ? 110 : 8, active: windows.isMini)
            WindowDragArea { windows.exitMini() }
            PlayerOverlays(controller: controller, compact: true)

            if hovering {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Button { windows.closeMini() } label: { Image(systemName: "xmark") }
                            .buttonStyle(GlassIconButtonStyle(diameter: 28))
                            .help("关闭")
                        Spacer()
                        Button { windows.exitMini() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(GlassIconButtonStyle(diameter: 28))
                            .help("返回播放器（双击画面）")
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        HStack {
                            Text(miniTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(formatClock(controller.currentTime)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Scrubber(controller: controller, thin: true)
                        HStack(spacing: 14) {
                            Button { controller.previous() } label: { Image(systemName: "backward.end.fill") }
                                .buttonStyle(BarIconButtonStyle(size: 28))
                                .disabled(!controller.hasPrevious)
                                .help("上一集")
                            Button { controller.togglePlay() } label: { Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill") }
                                .buttonStyle(GlassIconButtonStyle(diameter: 36, variant: .clear))
                                .help("播放 / 暂停")
                            Button { controller.next() } label: { Image(systemName: "forward.end.fill") }
                                .buttonStyle(BarIconButtonStyle(size: 28))
                                .disabled(!controller.hasNext)
                                .help("下一集")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .padding(16)
                .background(
                    LinearGradient(colors: [.black.opacity(0.3), .clear, .clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                )
                .transition(.opacity)
            } else {
                // At rest: only a hairline of progress along the bottom edge.
                VStack {
                    Spacer()
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.2))
                            Rectangle().fill(.white.opacity(0.9)).frame(width: proxy.size.width * progress)
                        }
                    }
                    .frame(height: 3)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        // Borderless windows only get a hairline to resize from; give every edge and corner a real grip.
        .overlay(WindowResizeEdges(thickness: 12, corner: 28))
        .onHover { value in withAnimation(.easeOut(duration: 0.18)) { hovering = value } }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    private var miniTitle: String {
        guard let title = controller.episodes?.title else { return controller.title }
        return controller.index > 0 ? "\(title) · 第 \(controller.index) 集" : title
    }
}

func formatClock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

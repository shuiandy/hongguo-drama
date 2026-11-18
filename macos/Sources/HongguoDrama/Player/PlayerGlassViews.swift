import AVKit
import SwiftUI
import HongguoCore

// Liquid Glass player UI: the main player window, the episode drawer and the floating mini window.
// The video is a bare AVPlayerLayer; every control is drawn here so it can sit on glass.

// MARK: Playback clock

/// Current time, duration and buffered end of the shared player, sampled four times a second.
@MainActor
@Observable
final class PlaybackClock {
    static let shared = PlaybackClock(player: PlayerController.shared.player)

    private(set) var current: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0

    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private var token: Any?

    private init(player: AVPlayer) {
        self.player = player
        token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    var progress: Double { duration > 0 ? min(1, max(0, current / duration)) : 0 }
    var bufferedProgress: Double { duration > 0 ? min(1, max(0, buffered / duration)) : 0 }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let target = duration * min(1, max(0, fraction))
        current = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        current = seconds.isFinite ? seconds : 0
        let total = player.currentItem?.duration.seconds ?? 0
        duration = total.isFinite ? total : 0
        let ranges = player.currentItem?.loadedTimeRanges.map(\.timeRangeValue) ?? []
        buffered = ranges.first { $0.containsTime(time) }.map { ($0.start + $0.duration).seconds } ?? current
    }
}

// MARK: Video surface with picture in picture

/// AVPlayerLayer host. With `allowsPictureInPicture` it also owns the system PiP controller.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var allowsPictureInPicture = false

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
        if allowsPictureInPicture { PictureInPicture.shared.attach(view.playerLayer) }
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

@MainActor
@Observable
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PictureInPicture()

    private(set) var isActive = false
    @ObservationIgnored private var controller: AVPictureInPictureController?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ layer: AVPlayerLayer) {
        guard isSupported, controller == nil else { return }
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = false }
    }
}

// MARK: Overlays

struct PlayerOverlays: View {
    let controller: PlayerController
    var compact = false

    var body: some View {
        ZStack {
            if controller.isLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(compact ? .regular : .large)
                    if !compact {
                        Text(controller.loadingText).font(.callout).foregroundStyle(.white.opacity(0.9))
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
                    .font(.system(size: compact ? 13 : 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, compact ? 12 : 18)
                    .frame(height: compact ? 28 : 36)
                    .glassSurface(in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, compact ? 44 : 60)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: controller.toast)
        .allowsHitTesting(controller.errorMessage != nil)
    }
}

// MARK: Scrubber

/// Progress bar with buffered range; drag or click to seek. Grows on hover.
struct Scrubber: View {
    let clock: PlaybackClock
    var thin = false
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            let fraction = dragFraction ?? clock.progress
            let height: CGFloat = thin ? 4 : (hovering || dragFraction != nil ? 7 : 5)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.32)).frame(width: proxy.size.width * clock.bufferedProgress)
                Capsule().fill(.white).frame(width: max(height, proxy.size.width * fraction))
                if !thin && (hovering || dragFraction != nil) {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                        .offset(x: proxy.size.width * fraction - 7)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragFraction = min(1, max(0, value.location.x / max(1, proxy.size.width))) }
                    .onEnded { value in
                        clock.seek(toFraction: value.location.x / max(1, proxy.size.width))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: thin ? 10 : 20)
        .onHover { value in withAnimation(.easeOut(duration: 0.12)) { hovering = value } }
        .animation(.easeOut(duration: 0.12), value: dragFraction != nil)
    }
}

// MARK: Main player window

/// Main player window: ambient light around the video, floating glass controls, glass episode drawer.
struct PlayerScreen: View {
    let controller: PlayerController
    let windows: PlayerWindows
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var showChrome: Bool { chromeVisible || !controller.isPlaying || controller.player.currentItem == nil }

    var body: some View {
        ZStack {
            Color.black
            // Ambient light: the cover, blurred, fills the letterbox around the 9:16 video.
            if !controller.cover.isEmpty {
                AmbientBackdrop(url: controller.cover, blur: 100, opacity: 0.55)
                    .overlay(RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 80, endRadius: 700))
            }
            HStack(spacing: 0) {
                videoArea
                if windows.showEpisodes {
                    EpisodeDrawer(controller: controller, windows: windows)
                        .frame(width: PlayerWindows.episodePanelWidth - 24)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(.hongguoRed)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: windows.showEpisodes)
    }

    private var videoArea: some View {
        ZStack {
            VideoSurface(player: controller.player, allowsPictureInPicture: true)
                .shadow(color: .black.opacity(0.6), radius: 40)
            // Click toggles play, double click toggles full screen.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { windows.toggleFullScreen() }
                .onTapGesture { controller.togglePlay() }
            PlayerOverlays(controller: controller)
            VStack(spacing: 0) {
                topBar
                Spacer()
                PlayerControlBar(controller: controller, windows: windows)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                    .frame(maxWidth: 600)
            }
            .opacity(showChrome ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showChrome)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: revealChrome()
            case .ended: hideChrome(after: 0.4)
            }
        }
    }

    private var topBar: some View {
        ZStack {
            WindowDragArea { NSApp.keyWindow?.zoom(nil) }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 84) // traffic lights
            .padding(.trailing, 12)
        }
        .frame(height: 46)
    }

    private func revealChrome() {
        chromeVisible = true
        hideChrome(after: 2.5)
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

/// Floating glass control bar: scrubber on top, transport and window controls below.
struct PlayerControlBar: View {
    let controller: PlayerController
    let windows: PlayerWindows
    private var clock: PlaybackClock { PlaybackClock.shared }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(formatClock(clock.current)).foregroundStyle(.white.opacity(0.9))
                Scrubber(clock: clock)
                Text(formatClock(clock.duration)).foregroundStyle(.white.opacity(0.65))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())

            HStack(spacing: 2) {
                Button { controller.previous() } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(BarIconButtonStyle())
                    .disabled(!controller.hasPrevious)
                    .help("上一集（↑）")
                Button { controller.togglePlay() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(GlassIconButtonStyle(diameter: 40, variant: .clear))
                .help("播放 / 暂停（空格）")
                Button { controller.next() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(BarIconButtonStyle())
                    .disabled(!controller.hasNext)
                    .help("下一集（↓）")

                Spacer(minLength: 6)

                Menu {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2, 3], id: \.self) { value in
                        Button { controller.rate = value } label: {
                            if value == controller.rate { Label(formatRate(value), systemImage: "checkmark") } else { Text(formatRate(value)) }
                        }
                    }
                } label: {
                    Text(formatRate(controller.rate))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("播放速度（S / D）")

                Button { controller.toggleAutoNext() } label: { Image(systemName: "repeat") }
                    .buttonStyle(BarIconButtonStyle(active: controller.autoNext))
                    .help(controller.autoNext ? "自动连播：开（A）" : "自动连播：关（A）")
                if PictureInPicture.shared.isSupported {
                    Button { PictureInPicture.shared.toggle() } label: {
                        Image(systemName: PictureInPicture.shared.isActive ? "pip.exit" : "pip.enter")
                    }
                    .buttonStyle(BarIconButtonStyle())
                    .help("系统画中画")
                }
                Button { windows.enterMini() } label: { Image(systemName: "rectangle.inset.bottomright.filled") }
                    .buttonStyle(BarIconButtonStyle())
                    .help("悬浮小窗（M）")
                Button { windows.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(BarIconButtonStyle())
                    .help("全屏（F）")
                Button { windows.toggleEpisodes() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(BarIconButtonStyle(active: windows.showEpisodes))
                    .help("选集（E）")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// Floating glass episode drawer on the right of the player.
struct EpisodeDrawer: View {
    let controller: PlayerController
    let windows: PlayerWindows

    private var record: WatchRecord? {
        guard let id = controller.episodes?.seriesId else { return nil }
        return AppModel.shared.history.first { $0.seriesId == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                CoverImage(url: controller.cover, cornerRadius: 10).frame(width: 54, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.episodes?.title ?? "选集").font(.system(size: 15, weight: .bold)).lineLimit(2)
                    if let total = controller.episodes?.total {
                        Text("共 \(total) 集\(controller.currentSource.map { " · 片源：\(sourceName($0))" } ?? "")")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { windows.toggleEpisodes() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(GlassIconButtonStyle(diameter: 28, variant: .clear))
                    .help("收起选集（E）")
            }
            .padding(.top, 2)

            ScrollView {
                if let episodes = controller.episodes {
                    EpisodeGrid(episodes: episodes.episodes,
                                current: controller.index,
                                completed: record?.completedEpisode ?? 0,
                                minimumCellWidth: 44) { episode in
                        controller.play(index: episode.index)
                    }
                    .padding(2)
                }
            }
            .scrollIndicators(.never)

            Text("空格 播放/暂停 · ← → 快退快进 · E 选集 · M 小窗 · S/D 倍速")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .padding(.top, 20)
        .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func sourceName(_ source: PlaySource) -> String {
        switch source {
        case .web: return "官网"
        case .api: return "旧接口"
        case .app: return "App"
        }
    }
}

// MARK: Mini window

/// Content of the borderless floating window: just the video at rest, glass controls on hover.
struct MiniPlayerView: View {
    let controller: PlayerController
    let windows: PlayerWindows
    @State private var hovering = false
    private var clock: PlaybackClock { PlaybackClock.shared }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: controller.player)
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
                            Text(formatClock(clock.current)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Scrubber(clock: clock, thin: true)
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
                .padding(10)
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
                            Rectangle().fill(.white.opacity(0.9)).frame(width: proxy.size.width * clock.progress)
                        }
                    }
                    .frame(height: 3)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
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

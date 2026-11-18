import AVKit
import SwiftUI
import HongguoCore

/// AVPlayerView with native floating controls, PiP button and full-screen toggle.
struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = false
        view.allowsMagnification = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Bare video layer, no controls (used by the mini panel).
struct VideoLayerView: NSViewRepresentable {
    let player: AVPlayer

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
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

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// Transparent area that drags the window; double click runs `onDoubleClick`.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: () -> Void

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?(); return }
            window?.performDrag(with: event)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.onDoubleClick = onDoubleClick }
}

struct PlayerOverlays: View {
    let controller: PlayerController

    var body: some View {
        ZStack {
            if controller.isLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(controller.loadingText).font(.callout).foregroundStyle(.white.opacity(0.85))
                }
                .padding(18)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            } else if let error = controller.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(error).multilineTextAlignment(.center).foregroundStyle(.white).frame(maxWidth: 340)
                    HStack {
                        Button("重试") { controller.retry() }
                        if controller.hasNext { Button("下一集") { controller.next() } }
                    }
                }
                .padding(20)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }
            if let toast = controller.toast {
                Text(toast)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 54)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: controller.toast)
        .allowsHitTesting(controller.errorMessage != nil)
    }
}

/// Main player window content: video on the left, episode list on the right.
struct PlayerScreen: View {
    let controller: PlayerController
    let windows: PlayerWindows
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.black
                NativePlayerView(player: controller.player)
                PlayerOverlays(controller: controller)
                topBar
                    .opacity(hovering || controller.player.currentItem == nil ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: hovering)
            }
            .onContinuousHover { phase in
                if case .active = phase { hovering = true } else { hovering = false }
            }
            if windows.showEpisodes {
                EpisodePanel(controller: controller)
                    .frame(width: PlayerWindows.episodePanelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(controller.title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.white)
            Spacer()
            Menu {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2, 3], id: \.self) { value in
                    Button { controller.rate = value } label: {
                        if value == controller.rate { Label(formatRate(value), systemImage: "checkmark") } else { Text(formatRate(value)) }
                    }
                }
            } label: {
                Text(formatRate(controller.rate)).font(.callout.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("播放速度（S / D）")
            iconButton(controller.autoNext ? "repeat.circle.fill" : "repeat.circle", help: "自动连播（A）") { controller.toggleAutoNext() }
            iconButton("pip.enter", help: "悬浮小窗（M）") { windows.enterMini() }
            iconButton("sidebar.right", help: "选集（E）") { windows.toggleEpisodes() }
        }
        .padding(.leading, 84) // traffic lights
        .padding(.trailing, 14)
        .frame(height: 40)
        .background {
            ZStack {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                WindowDragArea { NSApp.keyWindow?.zoom(nil) }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct EpisodePanel: View {
    let controller: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.episodes?.title ?? "选集").font(.headline).lineLimit(2)
                if let total = controller.episodes?.total {
                    Text("共 \(total) 集\(controller.currentSource.map { " · 片源：\(sourceName($0))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 40)
            .padding(.bottom, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(controller.episodes?.episodes ?? []) { episode in
                            let current = episode.index == controller.index
                            Button { controller.play(index: episode.index) } label: {
                                Text("\(episode.index)")
                                    .font(.callout.monospacedDigit())
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(current ? Color.accentColor : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(current ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .id(episode.index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: controller.index) { _, value in
                    withAnimation { proxy.scrollTo(value, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(controller.index, anchor: .center) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    private func sourceName(_ source: PlaySource) -> String {
        switch source {
        case .web: return "官网"
        case .api: return "旧接口"
        case .app: return "App"
        }
    }
}

/// Content of the borderless floating window: video, drag-to-move, hover controls.
struct MiniPlayerView: View {
    let controller: PlayerController
    let windows: PlayerWindows
    @State private var hovering = false

    var body: some View {
        ZStack {
            VideoLayerView(player: controller.player)
            WindowDragArea { windows.exitMini() }
            PlayerOverlays(controller: controller)
            if hovering {
                VStack {
                    HStack {
                        miniButton("xmark", help: "关闭") { windows.closeMini() }
                        Spacer()
                        miniButton("arrow.up.left.and.arrow.down.right", help: "返回播放器（双击）") { windows.exitMini() }
                    }
                    Spacer()
                    HStack(spacing: 18) {
                        miniButton("backward.end.fill", help: "上一集") { controller.previous() }.disabled(!controller.hasPrevious)
                        miniButton(controller.isPlaying ? "pause.fill" : "play.fill", help: "播放 / 暂停", size: 22) { controller.togglePlay() }
                        miniButton("forward.end.fill", help: "下一集") { controller.next() }.disabled(!controller.hasNext)
                    }
                    .padding(.bottom, 4)
                    MiniProgress(player: controller.player)
                }
                .padding(10)
                .background(LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
        .preferredColorScheme(.dark)
    }

    private func miniButton(_ symbol: String, help: String, size: CGFloat = 14, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Thin progress bar for the mini window; click to seek.
struct MiniProgress: View {
    let player: AVPlayer
    @State private var progress: Double = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: proxy.size.width * progress)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
                let fraction = max(0, min(1, location.x / proxy.size.width))
                player.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 600))
                progress = fraction
            }
        }
        .frame(height: 4)
        .onReceive(timer) { _ in
            guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { progress = 0; return }
            progress = max(0, min(1, player.currentTime().seconds / duration))
        }
    }
}

import AppKit
import AVKit
import SwiftUI

/// Owns the player window, the borderless floating mini panel, and player keyboard shortcuts.
@MainActor
@Observable
final class PlayerWindows: NSObject, NSWindowDelegate {
    static let shared = PlayerWindows()

    static let episodePanelWidth: CGFloat = 424
    /// The video stage never gets narrower than this, so the control bar fits; ambient light fills the rest.
    static let minimumStageWidth: CGFloat = 700

    private(set) var isMini = false
    private(set) var showEpisodes = true
    /// 置顶: the player window floats above other apps and follows across Spaces, with every
    /// control still there. Replaces the old reduced mini window. Remembered between launches.
    private(set) var isPinned = UserDefaults.standard.bool(forKey: "playerPinned")
    @ObservationIgnored private var episodesBeforePin: Bool?

    @ObservationIgnored private var playerWindow: NSWindow?
    @ObservationIgnored private var miniPanel: MiniPanel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var spaceHold: DispatchWorkItem?
    @ObservationIgnored private var spaceHoldActive = false
    @ObservationIgnored private var spaceIsDown = false
    @ObservationIgnored private var lastAspect: CGFloat = 9.0 / 16.0

    private var controller: PlayerController { PlayerController.shared }

    // MARK: Main player window

    func showPlayer() {
        if isMini { exitMini() }
        let window = playerWindow ?? makePlayerWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    private func makePlayerWindow() -> NSWindow {
        let height = min(820, (NSScreen.main?.visibleFrame.height ?? 900) * 0.85)
        let videoWidth = max(Self.minimumStageWidth, (height * lastAspect).rounded())
        let size = NSSize(width: videoWidth + (showEpisodes ? Self.episodePanelWidth : 0), height: height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "红果短剧 播放器"
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Self.minimumStageWidth, height: 520)
        if isPinned { showEpisodes = false }
        let hosting = NSHostingView(rootView: PlayerScreen(controller: controller, windows: self))
        // The window decides its size; SwiftUI content must not grow it (that pushed the drawer header off-screen).
        hosting.sizingOptions = []
        window.contentView = hosting
        window.delegate = self
        window.setFrameAutosaveName("HongguoPlayerWindow")
        if !window.setFrameUsingName("HongguoPlayerWindow") { window.center() }
        playerWindow = window
        applyPin(to: window)
        return window
    }

    // MARK: Pin on top

    func togglePin() {
        let window = playerWindow ?? makePlayerWindow()
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        isPinned.toggle()
        UserDefaults.standard.set(isPinned, forKey: "playerPinned")
        // A pinned player is usually made small: the episode list steps aside, and comes back on unpin.
        if isPinned {
            episodesBeforePin = showEpisodes
            if showEpisodes { toggleEpisodes() }
        } else if episodesBeforePin == true, !showEpisodes {
            toggleEpisodes()
        }
        applyPin(to: window)
        window.makeKeyAndOrderFront(nil)
    }

    private func applyPin(to window: NSWindow) {
        window.level = isPinned ? .floating : .normal
        if isPinned {
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.minSize = NSSize(width: 380, height: 300)
        } else {
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.minSize = NSSize(width: Self.minimumStageWidth, height: 520)
            var frame = window.frame
            if frame.width < window.minSize.width || frame.height < window.minSize.height {
                frame.size.width = max(frame.width, window.minSize.width)
                frame.size.height = max(frame.height, window.minSize.height)
                window.setFrame(frame, display: true, animate: true)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === playerWindow, !isMini else { return }
        controller.persistPosition()
        controller.player.pause()
    }

    func toggleEpisodes() {
        showEpisodes.toggle()
        guard let window = playerWindow, !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frame
        let delta = showEpisodes ? Self.episodePanelWidth : -Self.episodePanelWidth
        frame.size.width = max(window.minSize.width, frame.size.width + delta)
        window.setFrame(frame, display: true, animate: true)
    }

    func toggleFullScreen() {
        if isMini { exitMini() }
        // A floating window cannot go full screen: unpin first.
        if isPinned { togglePin() }
        playerWindow?.toggleFullScreen(nil)
    }

    /// Fit the window width to the video's aspect ratio once the first frame size is known.
    func videoSizeChanged(_ size: CGSize) {
        let aspect = size.width / size.height
        guard abs(aspect - lastAspect) > 0.01 else { return }
        lastAspect = aspect
        miniPanel?.contentAspectRatio = size
        if let window = playerWindow, !window.styleMask.contains(.fullScreen) {
            var frame = window.frame
            let contentHeight = window.contentLayoutRect.height
            let width = max(isPinned ? 0 : Self.minimumStageWidth, contentHeight * aspect) + (showEpisodes ? Self.episodePanelWidth : 0)
            frame.origin.x += (frame.width - width) / 2
            frame.size.width = width
            window.setFrame(frame, display: true, animate: true)
        }
        if let panel = miniPanel {
            var frame = panel.frame
            frame.size.height = frame.width / aspect
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Mini floating window

    func toggleMini() {
        isMini ? exitMini() : enterMini()
    }

    func enterMini() {
        guard controller.player.currentItem != nil else { return }
        if playerWindow?.styleMask.contains(.fullScreen) == true { playerWindow?.toggleFullScreen(nil) }
        let panel = miniPanel ?? makeMiniPanel()
        isMini = true
        playerWindow?.orderOut(nil)
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
    }

    func exitMini() {
        guard isMini else { return }
        isMini = false
        if let panel = miniPanel {
            AppModel.shared.settings.miniWindowFrame = NSStringFromRect(panel.frame)
            panel.orderOut(nil)
        }
        let window = playerWindow ?? makePlayerWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeMini() {
        exitMini()
        controller.persistPosition()
        controller.player.pause()
        playerWindow?.orderOut(nil)
    }

    private func makeMiniPanel() -> MiniPanel {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 270
        var frame = NSRect(x: visible.maxX - width - 24, y: visible.minY + 24, width: width, height: width / lastAspect)
        if let saved = AppModel.shared.settings.miniWindowFrame {
            let restored = NSRectFromString(saved)
            if restored.width >= 160, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(restored) }) {
                frame = NSRect(origin: restored.origin, size: NSSize(width: restored.width, height: restored.width / lastAspect))
            }
        }
        let panel = MiniPanel(contentRect: frame)
        panel.contentAspectRatio = NSSize(width: lastAspect * 1000, height: 1000)
        let miniHosting = NSHostingView(rootView: MiniPlayerView(controller: controller, windows: self))
        miniHosting.sizingOptions = []
        panel.contentView = miniHosting
        panel.delegate = self
        miniPanel = panel
        return panel
    }

    func windowDidMove(_ notification: Notification) { saveMiniFrame(notification) }
    func windowDidResize(_ notification: Notification) { saveMiniFrame(notification) }

    private func saveMiniFrame(_ notification: Notification) {
        guard let panel = notification.object as? MiniPanel, panel === miniPanel, isMini else { return }
        AppModel.shared.settings.miniWindowFrame = NSStringFromRect(panel.frame)
    }

    // MARK: Keyboard shortcuts

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Return only a Sendable flag across the isolation boundary; the event itself stays here.
            let consumed: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let key = NSApp.keyWindow, key === playerWindow || key === miniPanel else { return event }
        if key.firstResponder is NSText { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return event }

        if event.keyCode == 49 { // space
            handleSpace(event)
            return nil
        }
        guard event.type == .keyDown else { return event }
        switch event.keyCode {
        case 123: controller.seek(by: event.modifierFlags.contains(.shift) ? -10 : -5)
        case 124: controller.seek(by: event.modifierFlags.contains(.shift) ? 10 : 5)
        case 126: if !event.isARepeat { controller.previous() }
        case 125: if !event.isARepeat { controller.next() }
        case 53: // escape
            if isMini { exitMini() } else if key.styleMask.contains(.fullScreen) { key.toggleFullScreen(nil) } else { return event }
        default:
            let step = AppModel.shared.settings.speedStep
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": if !event.isARepeat { controller.toggleAutoNext() }
            case "s": controller.changeRate(by: -step)
            case "d": controller.changeRate(by: step)
            case "f": if !event.isARepeat { toggleFullScreen() }
            case "m": if !event.isARepeat { togglePin() }
            case "e": if !event.isARepeat, !isMini { toggleEpisodes() }
            case "b": if !event.isARepeat { controller.toggleDanmaku() }
            default: return event
            }
        }
        return nil
    }

    private func handleSpace(_ event: NSEvent) {
        guard AppModel.shared.settings.holdToSpeedUp else {
            if event.type == .keyDown, !event.isARepeat { controller.togglePlay() }
            return
        }
        if event.type == .keyDown {
            guard !event.isARepeat, !spaceIsDown else { return }
            spaceIsDown = true
            spaceHoldActive = false
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.spaceIsDown else { return }
                    self.spaceHoldActive = true
                    self.controller.beginHoldSpeed()
                }
            }
            spaceHold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        } else {
            spaceIsDown = false
            spaceHold?.cancel()
            spaceHold = nil
            if spaceHoldActive {
                spaceHoldActive = false
                controller.endHoldSpeed()
            } else {
                controller.togglePlay()
            }
        }
    }
}

/// Borderless, always-on-top, resizable panel that follows the user across Spaces.
final class MiniPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 160, height: 160)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

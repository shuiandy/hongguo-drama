import SwiftUI
import AppKit
import HongguoCore

@main
struct HongguoDramaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        // Diagnostic: `HONGGUO_PROBE_REVIEWS=<series id> HongguoDrama.app/Contents/MacOS/HongguoDrama`
        // prints the App series review reply's codes and shape with the saved login, then quits.
        if let seriesId = ProcessInfo.processInfo.environment["HONGGUO_PROBE_REVIEWS"], !seriesId.isEmpty {
            Self.probeReviewsAndExit(seriesId)
        }
    }

    private static func probeReviewsAndExit(_ seriesId: String) -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for line in await EpisodeSocialService.probeSeriesReviews(seriesId: seriesId) { print(line) }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    var body: some Scene {
        WindowGroup("红果短剧", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button("退出红果短剧") { AppDelegate.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            SettingsCommands()
            CommandMenu("播放") {
                Button("播放 / 暂停") { PlayerController.shared.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [.command])
                Button("上一集") { PlayerController.shared.previous() }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("下一集") { PlayerController.shared.next() }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                Divider()
                Button("置顶播放器") { PlayerWindows.shared.togglePin() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("显示播放器") { PlayerWindows.shared.showPlayer() }
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}

/// ⌘, opens settings inside the main window (there is no separate settings window).
struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                AppModel.shared.showSettings()
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        Task { @MainActor in
            AppModel.shared.applyTheme()
            AppModel.shared.connectPlayer()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Coming back to the app (say after watching on the phone) brings the account's progress,
    /// favourites and likes in; syncCloudHistory itself waits a minute between runs.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in await AppModel.shared.syncCloudHistory() }
    }

    /// Settings is a sheet on the main window, and AppKit refuses to quit while a sheet is up
    /// (⌘Q beeps, a quit request from outside is answered "cancelled"). Both the menu command and
    /// the quit Apple event come here: take the sheet down first, then quit.
    @MainActor static func quit() {
        let sheets = NSApp.windows.compactMap(\.attachedSheet)
        guard !sheets.isEmpty else { NSApp.terminate(nil); return }
        AppModel.shared.closeSettings()
        for sheet in sheets { sheet.sheetParent?.endSheet(sheet) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { Self.quit() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PlayerController.shared.persistPosition() }
    }
}

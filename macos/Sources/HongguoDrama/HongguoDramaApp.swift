import SwiftUI
import AppKit
import HongguoCore

@main
struct HongguoDramaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

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
                MainWindow.show()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        // Commands live as long as the app, so this keeps a working openWindow even after the
        // last main window has been closed (the Dock icon needs it to bring the window back).
        let _ = MainWindow.storeOpener(openWindow)
    }
}

/// Brings the main window back: the open or minimised one if there is one (a closed SwiftUI window
/// can linger in NSApp.windows, so it is not reused), otherwise a
/// fresh one from the "main" WindowGroup.
@MainActor enum MainWindow {
    private static var opener: OpenWindowAction?

    static func storeOpener(_ action: OpenWindowAction) -> Bool {
        opener = action
        return true
    }

    static func show() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            opener?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
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

    /// Clicking the Dock icon after the main window was closed. AppKit only offers to reopen when no
    /// window is visible, and the player window often still is, so always bring the main window
    /// back ourselves instead of leaving it to SwiftUI.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindow.show() }
        return false
    }

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

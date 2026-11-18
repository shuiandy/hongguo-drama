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
            CommandMenu("播放") {
                Button("播放 / 暂停") { PlayerController.shared.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [.command])
                Button("上一集") { PlayerController.shared.previous() }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("下一集") { PlayerController.shared.next() }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                Divider()
                Button("悬浮小窗") { PlayerWindows.shared.toggleMini() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("显示播放器") { PlayerWindows.shared.showPlayer() }
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            AppModel.shared.applyTheme()
            AppModel.shared.connectPlayer()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PlayerController.shared.persistPosition() }
    }
}

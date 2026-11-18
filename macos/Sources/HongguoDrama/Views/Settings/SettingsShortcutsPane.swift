import SwiftUI

/// 快捷键: read-only reference of the player and global shortcuts.
struct SettingsShortcutsPane: View {
    private let player: [(String, String)] = [
        ("播放 / 暂停（长按临时 2 倍速）", "空格"),
        ("快退 / 快进 5 秒", "← →"),
        ("快退 / 快进 10 秒", "⇧← ⇧→"),
        ("上一集 / 下一集", "↑ ↓"),
        ("减速 / 加速", "S D"),
        ("切换自动连播", "A"),
        ("开关弹幕", "B"),
        ("全屏", "F"),
        ("悬浮小窗", "M"),
        ("显示 / 隐藏选集", "E"),
        ("退出全屏或小窗", "esc"),
    ]
    private let global: [(String, String)] = [
        ("搜索", "⌘K"),
        ("打开设置", "⌘,"),
        ("播放 / 暂停", "⌘空格"),
        ("上一集 / 下一集", "⌘↑ ⌘↓"),
        ("悬浮小窗", "⌥⌘M"),
        ("显示播放器", "⌘0"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Array(player.enumerated()), id: \.offset) { _, item in LabeledContent(item.0) { KeyCap(text: item.1) } }
            } header: {
                Text("播放器")
            } footer: {
                Text("播放器窗口或小窗在前面时生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("全局") {
                ForEach(Array(global.enumerated()), id: \.offset) { _, item in LabeledContent(item.0) { KeyCap(text: item.1) } }
            }
        }
    }
}

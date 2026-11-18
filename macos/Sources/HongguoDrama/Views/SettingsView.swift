import SwiftUI
import HongguoCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var cacheBytes: Int64 = 0

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Picker("外观", selection: $model.settings.theme) {
                    Text("跟随系统").tag(AppSettings.Theme.system)
                    Text("浅色").tag(AppSettings.Theme.light)
                    Text("深色").tag(AppSettings.Theme.dark)
                }
                LabeledContent("播放缓存") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                        Button("清理") {
                            PlaybackCache.shared.clear()
                            cacheBytes = PlaybackCache.shared.usageBytes()
                        }
                    }
                }
            }
            .tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                Toggle("自动播放下一集", isOn: $model.settings.autoNext)
                Toggle("记住播放速度", isOn: $model.settings.rememberSpeed)
                Toggle("长按空格临时 2 倍速", isOn: $model.settings.holdToSpeedUp)
                Picker("S / D 调速步长", selection: $model.settings.speedStep) {
                    ForEach([Float(0.25), 0.5, 0.75, 1.0], id: \.self) { Text(String(format: "%.2fx", $0)).tag($0) }
                }
                Section("播放器快捷键") {
                    shortcut("空格", "播放 / 暂停（长按临时 2 倍速）")
                    shortcut("← / →", "快退 / 快进 5 秒")
                    shortcut("↑ / ↓", "上一集 / 下一集")
                    shortcut("S / D", "减速 / 加速")
                    shortcut("A", "切换自动连播")
                    shortcut("F", "全屏")
                    shortcut("M", "悬浮小窗")
                    shortcut("E", "显示 / 隐藏选集")
                }
            }
            .tabItem { Label("播放", systemImage: "play.rectangle") }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .onAppear { cacheBytes = PlaybackCache.shared.usageBytes() }
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        LabeledContent(action) { Text(key).font(.body.monospaced()).foregroundStyle(.secondary) }
    }
}

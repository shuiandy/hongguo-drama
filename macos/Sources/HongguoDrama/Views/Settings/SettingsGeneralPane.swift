import SwiftUI
import HongguoCore

/// 通用: appearance, start page, playback cache, import from the Electron app.
struct SettingsGeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var cacheBytes: Int64 = 0
    @State private var confirmImport = false
    @State private var importing = false
    @State private var importNote = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("外观") {
                LabeledContent {
                    Picker("主题", selection: $model.settings.theme) {
                        Text("跟随系统").tag(AppSettings.Theme.system)
                        Text("浅色").tag(AppSettings.Theme.light)
                        Text("深色").tag(AppSettings.Theme.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    SettingLabel("主题", note: "深色下玻璃效果最明显。")
                }
                Picker("打开时显示", selection: $model.settings.startPage) {
                    Text("上次的页面").tag("last")
                    Text("发现").tag("discover")
                    Text("观看记录").tag("history")
                    Text("我的剧库").tag("library")
                    Text("下载").tag("downloads")
                }
            }

            Section("存储") {
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                            .monospacedDigit().foregroundStyle(.secondary)
                        Button("清理") {
                            PlaybackCache.shared.clear()
                            cacheBytes = PlaybackCache.shared.usageBytes()
                        }
                    }
                } label: {
                    SettingLabel("播放缓存", note: "解密后的视频，用于秒开和预先准备下一集。")
                }
                Picker(selection: $model.settings.playbackCacheLimitGB) {
                    ForEach(AppSettings.cacheLimits, id: \.self) { gb in
                        Text(gb == 0 ? "不限制" : "\(gb) GB").tag(gb)
                    }
                } label: {
                    SettingLabel("缓存上限", note: "超出后先删除最久没看的集。")
                }
            }

            Section("从旧版导入") {
                LabeledContent {
                    Button(importing ? "导入中…" : "导入…") { confirmImport = true }
                        .disabled(importing || !ElectronImport.exists())
                } label: {
                    SettingLabel("Electron 版数据", note: ElectronImport.exists()
                                 ? "导入观看进度、打开过的剧、已下载的集和设置。只读取旧版数据，不会修改它。"
                                 : "没有找到旧版数据（~/Library/Application Support/红果短剧/data.json）。")
                }
                if !importNote.isEmpty { Text(importNote).font(.caption) }
            }
        }
        .onAppear { cacheBytes = PlaybackCache.shared.usageBytes() }
        .onChange(of: model.settings.playbackCacheLimitGB) {
            // The cap is applied by AppModel; read the size again after pruning.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                cacheBytes = PlaybackCache.shared.usageBytes()
            }
        }
        .confirmationDialog("从 Electron 版导入数据？", isPresented: $confirmImport) {
            Button("导入") { runImport() }
        } message: {
            Text("会合并观看进度、打开过的剧、已下载的集和设置；两边都有的记录以较新的为准。旧版数据只读取，不会被修改。")
        }
    }

    private func runImport() {
        importing = true
        importNote = ""
        Task {
            defer { importing = false }
            do {
                let result = try ElectronImport.read(base: model.settings)
                let counts = try await ElectronImport.apply(result, store: model.store, library: model.library,
                                                            downloads: model.downloads, applySettings: true)
                if let settings = result.settings { model.settings = settings }
                model.refreshHistory()
                model.refreshLibrary()
                model.applyDownloadSettings()
                var text = "已导入 \(counts.records) 条观看记录、\(counts.series) 部剧、\(counts.downloads) 个下载"
                if result.skipped > 0 { text += "，跳过 \(result.skipped) 条无效数据" }
                importNote = text
            } catch {
                importNote = (error as? HongguoError)?.message ?? "导入失败：\(describe(error))"
            }
        }
    }
}

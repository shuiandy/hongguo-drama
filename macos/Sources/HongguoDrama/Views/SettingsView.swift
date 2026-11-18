import AppKit
import SwiftUI
import HongguoCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var cacheBytes: Int64 = 0
    @State private var announcementPrefs = AnnouncementService.State()
    @State private var announcementNote = ""
    @State private var confirmImport = false
    @State private var importing = false
    @State private var importNote = ""

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
                Section("从旧版导入") {
                    LabeledContent("Electron 版数据") {
                        Button(importing ? "导入中…" : "导入…") { confirmImport = true }
                            .disabled(importing || !ElectronImport.exists())
                    }
                    Text(ElectronImport.exists()
                         ? "导入旧版红果短剧里的观看进度、打开过的剧、已下载的集和设置。只读取旧版数据，不会修改它。"
                         : "没有找到旧版数据（~/Library/Application Support/红果短剧/data.json）。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !importNote.isEmpty { Text(importNote).font(.caption) }
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

            Form {
                LabeledContent("下载位置") {
                    HStack {
                        Text(AppModel.downloadConfiguration(model.settings).root.path)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("更改…") { chooseFolder() }
                    }
                }
                Stepper("同时下载 \(model.settings.maxConcurrentDownloads) 集", value: $model.settings.maxConcurrentDownloads, in: 1...10)
                TextField("文件命名", text: $model.settings.downloadNameFormat)
                Toggle("看完后自动删除已下载的集", isOn: $model.settings.autoDeleteWatched)
                Toggle("播放时预先准备下一集", isOn: $model.settings.cacheNextEpisode)
                Section("追剧") {
                    Toggle("检查已看剧集的更新", isOn: $model.settings.watchUpdatesEnabled)
                    Toggle("检查续作", isOn: $model.settings.watchSequelsEnabled)
                }
                StorageSettingsSection()
            }
            .tabItem { Label("下载", systemImage: "arrow.down.circle") }

            Form { SourcesSettingsSection() }
                .tabItem { Label("片源", systemImage: "film.stack") }

            Form {
                LabeledContent("当前版本", value: UpdateChecker.currentVersion)
                LabeledContent("更新") {
                    HStack {
                        if let release = model.availableRelease {
                            Button("下载 \(release.version)") { NSWorkspace.shared.open(release.url) }
                        }
                        Button("检查更新") { Task { await model.checkForUpdate(manual: true) } }
                    }
                }
                if !model.updateMessage.isEmpty {
                    Text(model.updateMessage).font(.caption).foregroundStyle(.secondary)
                }
                Section("公告") {
                    Toggle("显示普通公告", isOn: Binding(get: { announcementPrefs.normalEnabled },
                                                     set: { value in setAnnouncements(normal: value) }))
                    Toggle("显示紧急公告", isOn: Binding(get: { announcementPrefs.emergencyEnabled },
                                                     set: { value in setAnnouncements(emergency: value) }))
                    LabeledContent("当前公告") {
                        Button("查看") {
                            Task {
                                announcementNote = await model.showCurrentAnnouncement() ? "" : "目前没有公告"
                            }
                        }
                    }
                    if !announcementNote.isEmpty { Text(announcementNote).font(.caption).foregroundStyle(.secondary) }
                }
                LabeledContent("项目主页") {
                    Button("在 GitHub 打开") { NSWorkspace.shared.open(ReleaseRepo.releasesURL) }
                }
            }
            .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 520)
        .onAppear { cacheBytes = PlaybackCache.shared.usageBytes() }
        .task { announcementPrefs = await model.announcements.preferences }
        .confirmationDialog("从 Electron 版导入数据？", isPresented: $confirmImport) {
            Button("导入") { runImport() }
        } message: {
            Text("会合并观看进度、打开过的剧、已下载的集和设置；两边都有的记录以较新的为准。旧版数据只读取，不会被修改。")
        }
        .onChange(of: model.settings.maxConcurrentDownloads) { model.applyDownloadSettings() }
        .onChange(of: model.settings.downloadNameFormat) { model.applyDownloadSettings() }
        .onChange(of: model.settings.downloadRoot) { model.applyDownloadSettings() }
    }

    private func setAnnouncements(normal: Bool? = nil, emergency: Bool? = nil) {
        Task {
            do {
                try await model.announcements.setPreferences(normalEnabled: normal, emergencyEnabled: emergency)
                announcementNote = ""
            } catch {
                announcementNote = (error as? HongguoError)?.message ?? "保存失败"
            }
            announcementPrefs = await model.announcements.preferences
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { model.settings.downloadRoot = url.path }
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        LabeledContent(action) { Text(key).font(.body.monospaced()).foregroundStyle(.secondary) }
    }
}

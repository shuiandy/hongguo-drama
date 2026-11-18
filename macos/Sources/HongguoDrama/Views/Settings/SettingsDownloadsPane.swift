import AppKit
import SwiftUI
import HongguoCore

/// 下载: folder, file naming, download behaviour, and disk use per series (StorageSettingsSection).
struct SettingsDownloadsPane: View {
    @Environment(AppModel.self) private var model

    private var root: URL { AppModel.downloadConfiguration(model.settings).root }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("位置与命名") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("在访达中显示") {
                            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                        Button("更改…") { chooseFolder() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("下载位置")
                        Text((root.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("文件命名")
                        Spacer()
                        Menu("插入字段") {
                            Button("剧名") { insert("剧名") }
                            Button("集数") { insert("集数") }
                            Button("标题") { insert("标题") }
                            Divider()
                            Button("恢复默认") { model.settings.downloadNameFormat = DownloadNaming.defaultFormat }
                        }
                        .fixedSize()
                    }
                    TextField("文件命名", text: $model.settings.downloadNameFormat, prompt: Text("剧名 集数"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Text("示例：\(example)（每部剧单独一个文件夹）").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("下载行为") {
                Stepper(value: $model.settings.maxConcurrentDownloads, in: 1...10) {
                    LabeledContent("同时下载", value: "\(model.settings.maxConcurrentDownloads) 集")
                }
                Toggle(isOn: $model.settings.autoDeleteWatched) {
                    SettingLabel("看完后自动删除已下载的集", note: "看到结尾的集会从磁盘删除。")
                }
                Toggle(isOn: $model.settings.autoExportText) {
                    SettingLabel("同时导出弹幕和评论", note: "一部剧下载完成后，在视频旁边保存同名的弹幕和评论文件。")
                }
            }

            StorageSettingsSection()
        }
    }

    private var example: String {
        DownloadNaming.episodeFilename(format: model.settings.downloadNameFormat,
                                       seriesTitle: "少夫人来自东北3", index: 1, episodeTitle: "初到伦敦")
    }

    private func insert(_ token: String) {
        let current = model.settings.downloadNameFormat.trimmingCharacters(in: .whitespaces)
        model.settings.downloadNameFormat = current.isEmpty ? token : current + " " + token
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = root
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { model.settings.downloadRoot = url.path }
    }
}

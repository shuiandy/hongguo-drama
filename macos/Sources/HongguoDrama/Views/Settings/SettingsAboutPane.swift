import AppKit
import SwiftUI
import HongguoCore

/// 关于: version, update check, project links and licence.
struct SettingsAboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var showLicense = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: .hongguoRed)
                    Text("红果短剧").font(.system(size: 20, weight: .heavy)).padding(.top, 4)
                    Text("Mac 原生版 · 版本 \(UpdateChecker.currentVersion)").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let release = model.availableRelease {
                            Button("下载 \(release.version)") { NSWorkspace.shared.open(release.url) }
                                .settingsButton(prominent: true)
                        } else {
                            Button("检查更新") { Task { await model.checkForUpdate(manual: true) } }
                                .settingsButton(prominent: true)
                        }
                        Button("查看更新说明") { NSWorkspace.shared.open(ReleaseRepo.releasesURL) }
                            .settingsButton()
                    }
                    .padding(.top, 6)
                    if !model.updateMessage.isEmpty {
                        Text(model.updateMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("更新") {
                Toggle(isOn: $model.settings.checkUpdatesAtLaunch) {
                    SettingLabel("启动时检查更新", note: "发现新版本时提示，不会自动下载或安装。随时可以在上面手动检查。")
                }
            }

            Section("项目") {
                LabeledContent {
                    Button("打开") { NSWorkspace.shared.open(ReleaseRepo.releasesURL) }
                } label: {
                    SettingLabel("项目主页", note: "GitHub 上的发布页")
                }
                LabeledContent {
                    Button("查看") { showLicense = true }
                } label: {
                    SettingLabel("开源许可", note: "GPL-3.0")
                }
            }
        }
        .sheet(isPresented: $showLicense) { LicenseSheet() }
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开源许可").font(.headline)
            Text("""
            红果短剧 Mac 原生版以 GNU General Public License v3.0 发布。部分签名与片源代码移植自 GPL-3.0 的 Electron 版红果短剧。

            你可以自由使用、修改和再发布本程序，但再发布时必须同样以 GPL-3.0 开放源代码，并保留版权和许可声明。本程序不提供任何担保。

            完整许可文本见 https://www.gnu.org/licenses/gpl-3.0.html
            """)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 440)
    }
}

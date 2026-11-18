import AppKit
import SwiftUI
import HongguoCore

/// Download / install controls for an available release, shared by 关于 and the sidebar card.
/// Releases without an installable archive fall back to the release page.
struct UpdateControls: View {
    let release: AvailableRelease
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.updatePhase {
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(received), total: Double(max(total, 1))).tint(.hongguoRed)
                HStack {
                    Text("正在下载 \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    Spacer()
                    Button("取消") { model.cancelUpdate() }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: compact ? .infinity : 280)
        case .verifying:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在校验更新…").font(.caption) }
        case .ready(let version):
            Button("重启并安装 \(version)") { Task { await model.installUpdate() } }
                .buttonStyle(GlassButtonStyle(prominent: true, size: .small))
                .disabled(!AppUpdateInstaller.canReplaceInstalledApp)
                .help(AppUpdateInstaller.canReplaceInstalledApp ? "退出后替换应用并重新打开" : "没有权限替换当前应用，请到发布页下载")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("重试") { model.downloadUpdate() }.buttonStyle(GlassButtonStyle(size: .small))
                    Button("打开发布页") { NSWorkspace.shared.open(release.url) }.buttonStyle(GlassButtonStyle(size: .small))
                }
            }
        case .idle:
            if release.asset != nil {
                Button("下载并安装 \(release.version)") { model.downloadUpdate() }
                    .buttonStyle(GlassButtonStyle(prominent: true, size: .small))
            } else {
                Button("下载 \(release.version)") { NSWorkspace.shared.open(release.url) }
                    .buttonStyle(GlassButtonStyle(prominent: true, size: .small))
                    .help("这个版本没有应用内安装包，前往发布页下载")
            }
        }
    }
}

import SwiftUI
import HongguoCore

/// 账号: who is signed in, cloud history sync, sign out. Login itself stays on the main window's 账号 page
/// (QR code and web login need the room).
struct SettingsAccountPane: View {
    @Environment(AppModel.self) private var model
    @State private var account = AccountState.shared
    @State private var confirmLogout = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: 14) {
                    AccountAvatar(account: account)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.restoring ? "正在恢复登录…" : (account.profile?.nickname ?? "未登录"))
                            .font(.system(size: 16, weight: .bold))
                        Text(account.profile != nil ? "已用红果 App 扫码登录，登录信息保存在钥匙串。"
                             : "用红果短剧 App 扫码登录后，可以看手机上的观看记录。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !account.message.isEmpty {
                            Text(account.message).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if account.profile != nil {
                        Button("退出登录") { confirmLogout = true }
                    } else if !account.restoring {
                        Button("去登录…") { openLoginPage() }.buttonStyle(GlassButtonStyle(prominent: true, size: .small))
                    }
                }
                .padding(.vertical, 4)
            }

            Section("同步") {
                Toggle(isOn: $model.settings.cloudHistorySync) {
                    SettingLabel("显示云端观看记录", note: "在“观看记录”里合并手机上看过的剧，较新的进度为准。")
                }
                Toggle(isOn: $model.settings.accountWriteSync) {
                    SettingLabel("双向同步到账号", note: "在这台 Mac 上的收藏、点赞、观看进度和删除的记录也会写到红果账号；账号里的收藏和点赞同步到这里。清空全部记录只清本机。")
                }
                LabeledContent {
                    Button(model.cloudSyncing ? "同步中…" : "立即同步") {
                        Task { await model.syncCloudHistory(force: true, manual: true) }
                    }
                    .disabled(model.cloudSyncing || account.profile == nil)
                } label: {
                    SettingLabel("上次同步", note: syncNote)
                }
            }
            .disabled(account.profile == nil)
        }
        .task { await account.restore() }
        .confirmationDialog("退出红果账号？", isPresented: $confirmLogout) {
            Button("退出登录", role: .destructive) { logout() }
        } message: {
            Text("会删除钥匙串里保存的登录信息。本机的观看记录会保留。")
        }
    }

    private var syncNote: String {
        if !model.cloudSyncMessage.isEmpty { return model.cloudSyncMessage }
        if !AccountSync.shared.message.isEmpty { return AccountSync.shared.message }
        guard model.lastCloudSync > .distantPast else { return "本次打开后还没有同步" }
        let time = model.lastCloudSync.formatted(.relative(presentation: .named))
        let sync = AccountSync.shared
        let extra = model.settings.accountWriteSync && sync.lastPull > .distantPast
            ? " · 账号收藏 \(sync.cloudFavoriteCount) 部 · 点赞 \(sync.cloudLikeCount) 集" : ""
        return "\(time) · 观看记录 \(model.lastCloudSyncCount) 条\(extra)"
    }

    private func openLoginPage() {
        model.closeSettings()
        model.selection = .account
    }

    private func logout() {
        Task {
            let warning = await AccountService.shared.logout()
            AccountSync.shared.signedOut()
            account.profile = nil
            account.message = warning
        }
    }
}

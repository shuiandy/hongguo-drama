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
                    ZStack {
                        Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.54, blue: 0.58), .purple],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        if let name = account.profile?.nickname, let first = name.first {
                            Text(String(first)).font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
                        } else {
                            Image(systemName: "person.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
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
                        Button("去登录…") { openLoginPage() }.settingsButton(prominent: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("同步") {
                Toggle(isOn: $model.settings.cloudHistorySync) {
                    SettingLabel("显示云端观看记录", note: "在“观看记录”里合并手机上看过的剧，较新的进度为准。")
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
        guard model.lastCloudSync > .distantPast else { return "本次打开后还没有同步" }
        let time = model.lastCloudSync.formatted(.relative(presentation: .named))
        return "\(time) · 共 \(model.lastCloudSyncCount) 条"
    }

    private func openLoginPage() {
        model.closeSettings()
        model.selection = .account
    }

    private func logout() {
        Task {
            let warning = await AccountService.shared.logout()
            account.profile = nil
            account.message = warning
        }
    }
}

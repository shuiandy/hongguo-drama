import AppLogic
import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 我的: the account and the settings, laid out like the system's Settings. On the left, what the
/// account is (picture, name, id); it takes no focus. On the right, one column of full-width
/// rows, so up and down on the remote reach every one of them and nothing sits beside a row:
/// 账号 (扫码登录 or 退出登录 with a confirmation, 切换账号) and the settings the TV uses, all kept in
/// the shared library's settings (默认清晰度, 默认倍速, 弹幕, 自动连播, 云端观看记录). A press on a
/// settings row moves it to its next value. 点赞 and 预约 are lists of series and live on 追剧.
struct MePage: View {
    @Environment(TVAppModel.self) private var app
    @State private var confirmsSignOut = false

    private static let qualities: [Int?] = [nil, 1080, 720, 540, 480]

    var body: some View {
        ZStack {
            AmbientBackground(tint: .gray)
            HStack(alignment: .top, spacing: 90) {
                accountCard
                    .frame(width: 520)
                    .padding(.top, 60)
                ScrollView(.vertical) {
                    rows
                        .padding(.vertical, 40)
                        .padding(.horizontal, 30)
                }
                .scrollClipDisabled()
            }
            .padding(.horizontal, 80)
            // One section across the page: down from any tab lands in the rows.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .focusSection()
        }
        .alert("退出登录？", isPresented: $confirmsSignOut) {
            Button("退出登录", role: .destructive) {
                Task {
                    // Signing out on a shared TV also takes the account off this Apple TV's list,
                    // so nobody can switch back into it without scanning again.
                    if let id = app.account.profile?.id, let entry = app.roster.entries.first(where: { $0.id == id }) {
                        await app.roster.remove(entry, account: app.account)
                    }
                    await app.account.signOut()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台 Apple TV 上的观看记录会保留，账号里的收藏和历史不再显示。")
        }
    }

    // MARK: Account

    private var accountCard: some View {
        let account = app.account
        return VStack(spacing: 22) {
            Group {
                if let url = URL(string: account.avatar), !account.avatar.isEmpty {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(Circle())
            if let profile = account.profile {
                Text(profile.nickname.isEmpty ? "红果用户" : profile.nickname).font(.title2.weight(.bold)).lineLimit(1)
                Text("ID \(profile.id)").foregroundStyle(.secondary)
            } else {
                Text("未登录").font(.title2.weight(.bold))
                Text("登录后，追剧里会显示账号的收藏、点赞、预约和观看记录")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !account.message.isEmpty {
                Text(account.message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text("数据来源：\(app.backend.isOffline ? "内置示例（离线）" : "红果官方")")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Rows

    private var rows: some View {
        let settings = app.library.settings
        return VStack(alignment: .leading, spacing: 14) {
            header("账号")
            if app.account.isSignedIn {
                SettingRow(title: "退出登录", systemImage: "rectangle.portrait.and.arrow.right") { confirmsSignOut = true }
            } else {
                SettingRow(title: "扫码登录", systemImage: "qrcode") { app.showsLogin = true }
            }
            SettingRow(title: "切换账号", systemImage: "person.2") { app.showsAccountPicker = true }

            header("播放")
            SettingRow(title: "默认清晰度", value: settings.preferredQuality.map { "\($0)P" } ?? "自动") {
                let index = Self.qualities.firstIndex(of: settings.preferredQuality) ?? 0
                app.library.settings.preferredQuality = Self.qualities[(index + 1) % Self.qualities.count]
            }
            SettingRow(title: "默认倍速", value: PlaybackRate.label(settings.playbackRate)) {
                let index = TVPlayerPage.rates.firstIndex(of: settings.playbackRate) ?? (TVPlayerPage.rates.firstIndex(of: 1) ?? 0)
                app.library.settings.playbackRate = TVPlayerPage.rates[(index + 1) % TVPlayerPage.rates.count]
            }
            SettingRow(title: "弹幕", value: settings.danmaku.enabled ? "开" : "关") {
                app.library.settings.danmaku.enabled.toggle()
            }
            SettingRow(title: "自动连播", value: settings.autoNext ? "开" : "关") {
                app.library.settings.autoNext.toggle()
            }

            header("同步")
            SettingRow(title: "云端观看记录", value: settings.cloudHistorySync ? "开" : "关") {
                app.library.settings.cloudHistorySync.toggle()
            }
            Text("按下遥控器切换到下一个选项").font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .frame(maxWidth: 1000, alignment: .leading)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.secondary)
            .padding(.top, 22)
    }
}

/// One full-width row of 我的: a title, and on the right its present value (a setting) or nothing
/// (an action). The system's button gives the focus effect.
private struct SettingRow: View {
    let title: String
    var systemImage: String? = nil
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
                Spacer(minLength: 20)
                if let value { Text(value).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        // A screen reader hears the row with its value; tests find the row by its title.
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
    }
}

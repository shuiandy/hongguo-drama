import AppLogic
import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 我的: the account card (sign in with a QR code, or name, id and 退出登录 with a confirmation),
/// 点赞 and 预约 shelves from the shared MeModel, and the settings the TV uses, all kept in the
/// shared library's settings: 默认清晰度, 默认倍速, 弹幕, 自动连播, 云端观看记录.
struct MePage: View {
    @Environment(TVAppModel.self) private var app
    @State private var me: MeModel?
    @State private var confirmsSignOut = false

    private static let qualities = [1080, 720, 540, 480]

    var body: some View {
        ZStack {
            AmbientBackground(tint: .gray)
            if let me {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 44) {
                        accountCard
                        likes(me)
                        reservations(me)
                        settings
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 40)
                }
                .scrollClipDisabled()
            }
        }
        .onAppear { if me == nil { me = MeModel(library: app.library, account: app.account) } }
        .alert("退出登录？", isPresented: $confirmsSignOut) {
            Button("退出登录", role: .destructive) { Task { await app.account.signOut() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台 Apple TV 上的观看记录会保留，账号里的收藏和历史不再显示。")
        }
    }

    // MARK: Account

    private var accountCard: some View {
        let account = app.account
        return HStack(spacing: 36) {
            Group {
                if let url = URL(string: account.avatar), !account.avatar.isEmpty {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 10) {
                if let profile = account.profile {
                    Text(profile.nickname.isEmpty ? "红果用户" : profile.nickname).font(.title2.weight(.bold))
                    Text("ID \(profile.id)").foregroundStyle(.secondary)
                } else {
                    Text("未登录").font(.title2.weight(.bold))
                    Text("登录后可以看到账号里的收藏、点赞、预约和观看记录").foregroundStyle(.secondary)
                }
                if !account.message.isEmpty {
                    Text(account.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.isSignedIn {
                Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right") { confirmsSignOut = true }
            } else {
                Button("扫码登录", systemImage: "qrcode") { app.showsLogin = true }
            }
        }
        .focusSection()
    }

    // MARK: Lists

    @ViewBuilder private func likes(_ me: MeModel) -> some View {
        let _ = app.library.libraryRevision
        let merged = me.likes
        let items = merged.local.map { SeriesSummary(seriesId: $0.item.seriesId, title: $0.item.title, cover: $0.item.cover,
                                                     episodeCount: $0.item.episodeCount) }
            + merged.account.map { SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                                 episodeCount: $0.episodeCount, episodeLabel: $0.detail) }
        if !items.isEmpty {
            Shelf(title: "点赞", items: items)
        } else {
            section("点赞", note: "还没有点赞")
        }
    }

    @ViewBuilder private func reservations(_ me: MeModel) -> some View {
        let _ = app.library.libraryRevision
        let items = me.onlineReservations.map { SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                                               heat: $0.heatText, episodeLabel: "已上线") }
            + me.upcomingReservations.map { SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                                           episodeLabel: $0.releaseText.isEmpty ? SeriesDetailModel.upcomingLabel : $0.releaseText) }
            + me.localReservations.map { SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                                        episodeLabel: $0.releaseText) }
        if !items.isEmpty {
            Shelf(title: "预约", items: items)
        } else {
            section("预约", note: "还没有预约")
        }
    }

    private func section(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text(note).foregroundStyle(.secondary)
        }
    }

    // MARK: Settings

    /// A title on the left of a control that has none of its own on tvOS (segmented pickers).
    private func labeled<Control: View>(_ title: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(spacing: 40) {
            Text(title).frame(width: 220, alignment: .leading)
            control()
        }
    }

    private var settings: some View {
        @Bindable var library = app.library
        return VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.title3.weight(.semibold))
            labeled("默认清晰度") {
                Picker("默认清晰度", selection: $library.settings.preferredQuality) {
                    Text("自动").tag(Int?.none)
                    ForEach(Self.qualities, id: \.self) { Text("\($0)P").tag(Optional($0)) }
                }
            }
            labeled("默认倍速") {
                Picker("默认倍速", selection: $library.settings.playbackRate) {
                    ForEach(TVPlayerPage.rates, id: \.self) { Text(PlaybackRate.label($0)).tag($0) }
                }
            }
            Toggle("弹幕", isOn: $library.settings.danmaku.enabled)
            Toggle("自动连播", isOn: $library.settings.autoNext)
            Toggle("云端观看记录", isOn: $library.settings.cloudHistorySync)
            Text("数据来源：\(app.backend.isOffline ? "内置示例（离线）" : "红果官方")").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 1100, alignment: .leading)
        .focusSection()
    }
}

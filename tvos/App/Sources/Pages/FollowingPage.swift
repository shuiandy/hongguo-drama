import AppLogic
import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 追剧: everything the viewer keeps, one shelf each: 收藏 and 历史 with how far each series is
/// watched, then 点赞 and 预约 (they used to sit on 我的, which is now the account and settings
/// only). From the shared MeModel (signed out the device's lists; signed in the account's, with its history merged into
/// the device's). A long press offers 取消收藏 or 删除记录, which go through the shared models'
/// write queue (the device's own list first, the account write after, put back if it fails).
struct FollowingPage: View {
    @Environment(TVAppModel.self) private var app
    @State private var me: MeModel?
    @State private var tint = Color.gray

    var body: some View {
        ZStack {
            AmbientBackground(tint: tint)
            if let me {
                content(me)
            }
        }
        .onAppear { if me == nil { me = MeModel(library: app.library, account: app.account) } }
        // The lists' page syncs on the way in, as the iOS 我的 (where these lists live) does.
        .task {
            await app.account.restoreIfNeeded(refresh: false)
            await app.library.syncAccount(force: app.account.hasListFailure)
        }
    }

    /// The account's message above the lists, with 重试 after a list could not be read: the
    /// same text and the same forced sync as the iOS 我的 page.
    @ViewBuilder private var syncNotice: some View {
        if !app.account.message.isEmpty {
            HStack(spacing: 24) {
                Text(app.account.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if app.account.hasListFailure {
                    Button("重试") { Task { await app.library.syncAccount(force: true) } }
                }
            }
            .focusSection()
        }
    }

    @ViewBuilder private func content(_ me: MeModel) -> some View {
        let _ = app.library.libraryRevision
        let favorites = favoriteItems(me)
        let history = me.history
        let likes = likeItems(me)
        let reservations = reservationItems(me)
        if favorites.isEmpty, history.isEmpty, likes.isEmpty, reservations.isEmpty {
            VStack(spacing: 40) {
                syncNotice
                LoadStateView(state: .empty("还没有在追的剧"))
            }
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    syncNotice
                    if !favorites.isEmpty {
                        row("收藏", favorites.map { item in
                            Card(series: item.series, progress: item.progress) {
                                Button("取消收藏", systemImage: "heart.slash", role: .destructive) {
                                    app.library.toggleFavorite(seriesId: item.series.seriesId, title: item.series.title,
                                                               cover: item.series.cover)
                                }
                            }
                        })
                    }
                    if !history.isEmpty {
                        row("历史", history.map { record in
                            Card(series: SeriesSummary(seriesId: record.seriesId, title: record.title, cover: record.cover,
                                                       episodeCount: record.total,
                                                       episodeLabel: HistoryProgress.label(episodeIndex: record.episodeIndex, total: record.total)),
                                 progress: record.total > 0 ? Double(record.episodeIndex) / Double(record.total) : nil,
                                 resume: record) {
                                Button("删除记录", systemImage: "trash", role: .destructive) { me.deleteHistory(record) }
                            }
                        })
                    }
                    if !likes.isEmpty {
                        Shelf(title: "点赞", items: likes, onFocus: follow)
                    }
                    if !reservations.isEmpty {
                        Shelf(title: "预约", items: reservations, onFocus: follow)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
        }
    }

    private struct Favorite { var series: SeriesSummary; var progress: Double? }

    /// The device's favourites (signed out) or the account's shelf, with progress where known.
    private func favoriteItems(_ me: MeModel) -> [Favorite] {
        let local = me.localFavorites.map { series -> Favorite in
            let record = app.library.store.record(for: series.seriesId)
            let total = max(series.episodeCount, record?.total ?? 0)
            return Favorite(series: SeriesSummary(seriesId: series.seriesId, title: series.title, cover: series.cover,
                                                  episodeCount: total),
                            progress: record.map { total > 0 ? Double($0.episodeIndex) / Double(total) : 0 })
        }
        let account = me.accountShelf.map {
            Favorite(series: SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover, episodeCount: $0.episodeCount),
                     progress: $0.episodeCount > 0 && $0.watchedEpisode > 0 ? Double($0.watchedEpisode) / Double($0.episodeCount) : nil)
        }
        return local + account
    }

    /// 点赞: the device's and the account's, as on the iOS 我的 page.
    private func likeItems(_ me: MeModel) -> [SeriesSummary] {
        let merged = me.likes
        return merged.local.map { SeriesSummary(seriesId: $0.item.seriesId, title: $0.item.title, cover: $0.item.cover,
                                                episodeCount: $0.item.episodeCount) }
            + merged.account.map { SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                                 episodeCount: $0.episodeCount, episodeLabel: $0.detail) }
    }

    /// 预约: what is out already, what is still to come, and the device's own.
    private func reservationItems(_ me: MeModel) -> [SeriesSummary] {
        me.onlineReservations.map { SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                                  heat: $0.heatText, episodeLabel: "已上线") }
            + me.upcomingReservations.map { SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                                          episodeLabel: $0.releaseText.isEmpty ? SeriesDetailModel.upcomingLabel : $0.releaseText) }
            + me.localReservations.map { SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                                       episodeLabel: $0.releaseText) }
    }

    private func row(_ title: String, _ cards: [Card]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.weight(.semibold))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: PosterMetrics.spacing) {
                    ForEach(cards) { card in
                        PosterCard(series: card.series, progress: card.progress, onFocus: { follow(card.series) },
                                   menu: card.menu) {
                            if let record = card.resume {
                                // A row from the account says where to resume, as on the iOS 我的 page.
                                let hinted = record.fromAccount && record.episodeIndex > 0
                                app.openPlayer(SeriesSummary(seriesId: record.seriesId, title: record.title, cover: record.cover),
                                               startEpisode: hinted ? record.episodeIndex : nil,
                                               startAt: record.fromAccount ? record.position : 0)
                            } else {
                                app.openDetail(card.series)
                            }
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func follow(_ series: SeriesSummary) {
        Task {
            if let color = await CoverTint.color(for: series.cover) { tint = color }
            else { tint = PlaceholderTint.color(for: series.seriesId) }
        }
    }
}

/// One card of a 追剧 shelf with its long-press menu.
private struct Card: Identifiable {
    var series: SeriesSummary
    var progress: Double?
    var resume: HistoryEntry?
    var menu: AnyView
    var id: String { series.seriesId }

    init<Menu: View>(series: SeriesSummary, progress: Double?, resume: HistoryEntry? = nil, @ViewBuilder menu: () -> Menu) {
        self.series = series
        self.progress = progress
        self.resume = resume
        self.menu = AnyView(menu())
    }
}

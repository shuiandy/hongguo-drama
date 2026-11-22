import AppLogic
import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 追剧: 收藏 and 历史 as two shelves with how far each series is watched, from the shared
/// MeModel (signed out the device's lists; signed in the account's, with its history merged into
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
    }

    @ViewBuilder private func content(_ me: MeModel) -> some View {
        let _ = app.library.libraryRevision
        let favorites = favoriteItems(me)
        let history = me.history
        if favorites.isEmpty, history.isEmpty {
            LoadStateView(state: .empty("还没有在追的剧"))
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
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

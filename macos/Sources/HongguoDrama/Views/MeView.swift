import SwiftUI
import HongguoCore

/// 我的 tabs, in the iOS order with 下载 added at the end.
enum MeTab: String, CaseIterable, Hashable, Sendable {
    case history, favorites, likes, reservations, downloads

    var label: String {
        switch self {
        case .history: return "历史"
        case .favorites: return "收藏"
        case .likes: return "点赞"
        case .reservations: return "预约"
        case .downloads: return "下载"
        }
    }
}

/// Content kinds the account tags its rows with (same labels as the iOS app).
enum MeCategory: CaseIterable, Hashable, Sendable {
    case all, real, comic, ai, highlight

    var label: String {
        switch self {
        case .all: return "全部"
        case .real: return "真人剧"
        case .comic: return "漫剧"
        case .ai: return "AI剧"
        case .highlight: return "高光"
        }
    }

    func matches(_ category: String) -> Bool { self == .all || category == label }
}

/// 我的: who is signed in, then 历史 / 收藏 / 点赞 / 预约 / 下载, the same structure as the iOS app.
/// Signed in, 收藏, 点赞 and 预约 show the account's own lists (kept in step by AccountSync);
/// things only on this Mac show beside them.
struct MeView: View {
    @Environment(AppModel.self) private var model
    @State private var account = AccountState.shared

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                accountRow
                GlassSegments(options: MeTab.allCases.map { GlassOption(label: label(for: $0), value: $0) },
                              selection: $model.meTab)
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Group {
                switch model.meTab {
                case .history: HistoryView(embedded: true)
                case .favorites: MeFavoritesView()
                case .likes: MeLikesView()
                case .reservations: MeReservationsView()
                case .downloads: DownloadsView(embedded: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // One light for the whole page, header and tabs alike.
        .background(alignment: .top) {
            if let cover = model.history.first?.cover, !cover.isEmpty {
                AmbientBackdrop(url: cover, opacity: 0.4)
                    .frame(height: 520)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
            }
        }
        .navigationTitle("我的")
        .transparentToolbar()
        .task { await account.restore() }
    }

    private var accountRow: some View {
        HStack(spacing: 12) {
            AccountAvatar(account: account, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.restoring ? "正在恢复登录…" : (account.profile?.nickname ?? "未登录"))
                    .font(.system(size: 22, weight: .heavy))
                    .lineLimit(1)
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            HeaderSearchField()
            if account.profile != nil {
                if model.cloudSyncing { ProgressView().controlSize(.small).help("正在和账号同步") }
            } else if !account.restoring {
                Button("登录…") { model.selection = .account }
                    .buttonStyle(GlassButtonStyle(prominent: true))
            }
        }
    }

    private var note: String {
        guard let profile = account.profile else { return "登录后，收藏、点赞、预约和观看进度会和红果账号同步" }
        let sync = AccountSync.shared
        if !sync.message.isEmpty { return sync.message }
        if !model.cloudSyncMessage.isEmpty { return model.cloudSyncMessage }
        return "ID \(profile.id)"
    }

    private func label(for tab: MeTab) -> String {
        let count: Int
        switch tab {
        case .history: count = model.history.count
        case .favorites: count = MeLists.favorites(model: model).count
        case .likes: count = MeLists.likes(model: model).account.count + MeLists.likes(model: model).local.count
        case .reservations: count = AccountSync.shared.reservations.count
        case .downloads: count = Set(model.downloadTasks.map(\.seriesId)).count
        }
        return count > 0 ? "\(tab.label) \(count)" : tab.label
    }
}

/// The merged lists behind the tabs, so counts and pages agree.
@MainActor
enum MeLists {
    struct Favorite: Identifiable {
        var summary: SeriesSummary
        var category: String
        var id: String { summary.seriesId }
    }

    /// The account's shelf first (newest first, as the account returns it), then favourites only on this Mac.
    static func favorites(model: AppModel) -> [Favorite] {
        let signedIn = AccountState.shared.profile != nil
        let shelf = signedIn ? AccountSync.shared.shelf : []
        let shelfIds = Set(shelf.map(\.seriesId))
        let records = Dictionary(model.history.map { ($0.seriesId, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = shelf.map { item in
            // This Mac's history already holds the later of its own and the account's progress;
            // the shelf's own "watched" field lags behind, so it is only the fallback.
            let total = max(item.episodeCount, records[item.seriesId]?.total ?? 0)
            let watched = records[item.seriesId]?.episodeIndex ?? item.watchedEpisode
            let label = watched > 0 && total > 0
                ? "看到第 \(min(watched, total)) 集 / 共 \(total) 集"
                : (total > 0 ? "全 \(total) 集" : "")
            return Favorite(summary: SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover,
                                                   episodeCount: item.episodeCount,
                                                   heat: item.category == "真人剧" ? "" : item.category,
                                                   episodeLabel: label),
                            category: item.category)
        }
        rows += model.favorites.filter { !shelfIds.contains($0.seriesId) }.map { Favorite(summary: $0.summary, category: "") }
        return rows
    }

    struct LocalLike: Identifiable {
        var series: LibrarySeries
        var episodes: Int
        var id: String { series.seriesId }
    }

    /// Account likes (one per episode), and series liked on this Mac whose episodes the account does not list.
    static func likes(model: AppModel) -> (account: [AccountDataAccess.LikedVideo], local: [LocalLike]) {
        _ = model.libraryRevision
        let signedIn = AccountState.shared.profile != nil
        let account = signedIn ? AccountSync.shared.likes : []
        let accountVids = Set(account.map(\.vid))
        let local = model.library.recent().compactMap { series -> LocalLike? in
            let extra = series.likedEpisodeIds.filter { !accountVids.contains($0) }
            return extra.isEmpty ? nil : LocalLike(series: series, episodes: extra.count)
        }
        return (account, local)
    }
}

// MARK: - 收藏

struct MeFavoritesView: View {
    @Environment(AppModel.self) private var model
    @State private var category: MeCategory = .all

    var body: some View {
        let all = MeLists.favorites(model: model)
        let shown = all.filter { category == .all || category.matches($0.category) }
        let recent = model.recentSeries.filter { item in !all.contains { $0.id == item.seriesId } }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MeCategoryPills(selection: $category, options: [.all, .real, .comic, .ai])
                if shown.isEmpty {
                    MeEmptyNote(text: category == .all ? "还没有收藏" : "这个分类下还没有收藏",
                                detail: "在详情页点“收藏”，喜欢的剧会出现在这里。")
                } else {
                    PosterGrid(items: shown.map(\.summary))
                }
                if category == .all, !recent.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("最近打开").font(.system(size: 20, weight: .heavy))
                        Text("按打开时间").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    PosterGrid(items: recent.map(\.summary))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .onAppear { model.refreshLibrary() }
    }
}

// MARK: - 点赞

struct MeLikesView: View {
    @Environment(AppModel.self) private var model
    @State private var category: MeCategory = .all

    var body: some View {
        let lists = MeLists.likes(model: model)
        let account = lists.account.filter { category.matches($0.category) }
        let local = category == .all ? lists.local : []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MeCategoryPills(selection: $category, options: [.all, .real, .comic, .ai, .highlight])
                if account.isEmpty, local.isEmpty {
                    MeEmptyNote(text: category == .all ? "还没有点赞" : "这个分类下还没有点赞",
                                detail: "播放时点小红心，点赞的集会出现在这里。")
                } else {
                    LazyVGrid(columns: MeCell.columns, alignment: .leading, spacing: 24) {
                        ForEach(account, id: \.vid) { item in
                            Button { play(seriesId: item.seriesId, title: item.title, cover: item.cover, index: item.episodeIndex) } label: {
                                MeCell(title: item.title, cover: item.cover,
                                       detail: item.detail.isEmpty ? (item.episodeIndex > 0 ? "第 \(item.episodeIndex) 集" : "") : item.detail,
                                       badge: item.category == "真人剧" ? "" : item.category,
                                       bottomBadge: item.diggedCount > 0 ? "♥ \(Self.short(item.diggedCount))" : "")
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("播放这一集") { play(seriesId: item.seriesId, title: item.title, cover: item.cover, index: item.episodeIndex) }
                                Button("查看详情") { model.open(SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover)) }
                                if model.isEpisodeLiked(seriesId: item.seriesId, vid: item.vid) {
                                    Divider()
                                    Button("取消点赞", role: .destructive) {
                                        model.toggleEpisodeLike(seriesId: item.seriesId, title: item.title, vid: item.vid)
                                    }
                                }
                            }
                        }
                        ForEach(local) { entry in
                            Button { model.open(entry.series.summary) } label: {
                                MeCell(title: entry.series.title, cover: entry.series.cover, detail: "本机已赞 \(entry.episodes) 集")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
    }

    private func play(seriesId: String, title: String, cover: String, index: Int) {
        Task { await PlayerController.shared.open(seriesId: seriesId, title: title, cover: cover, index: max(1, index)) }
    }

    static func short(_ count: Int) -> String {
        count >= 10_000 ? String(format: "%.1f万", Double(count) / 10_000) : "\(count)"
    }
}

// MARK: - 预约

struct MeReservationsView: View {
    @Environment(AppModel.self) private var model
    @State private var online = true

    var body: some View {
        let all = AccountSync.shared.reservations
        let onlineRows = all.filter(\.isOnline)
        let upcomingRows = all.filter { !$0.isOnline }
        let rows = online ? onlineRows : upcomingRows
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if AccountState.shared.profile == nil {
                    MeEmptyNote(text: "登录后显示预约", detail: "在红果 App 里预约的待上线短剧会出现在这里。")
                } else {
                    GlassSegments(options: [GlassOption(label: onlineRows.isEmpty ? "已上线" : "已上线 \(onlineRows.count)", value: true),
                                            GlassOption(label: upcomingRows.isEmpty ? "待上线" : "待上线 \(upcomingRows.count)", value: false)],
                                  selection: $online, compact: true)
                    if rows.isEmpty {
                        MeEmptyNote(text: online ? "还没有已上线的预约剧" : "还没有待上线的预约剧", detail: "")
                    } else {
                        LazyVGrid(columns: MeCell.columns, alignment: .leading, spacing: 24) {
                            ForEach(rows, id: \.seriesId) { item in
                                Button { open(item) } label: {
                                    MeCell(title: item.title, cover: item.cover,
                                           detail: item.isOnline && !item.subtitle.isEmpty ? item.subtitle : item.releaseText,
                                           badge: item.isOnline ? "" : "待上线",
                                           bottomBadge: item.heatText.isEmpty ? "" : "🔥 \(item.heatText)")
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if item.isOnline { Button("播放") { open(item) } }
                                    Button("查看详情") {
                                        model.open(SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover, description: item.description))
                                    }
                                    Divider()
                                    Button(item.isOnline ? "删除预约记录" : "取消预约", role: .destructive) {
                                        AccountSync.shared.cancelReservation(item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
    }

    private func open(_ item: AccountDataAccess.Reservation) {
        guard item.isOnline else {
            model.open(SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover, description: item.description))
            return
        }
        Task { await PlayerController.shared.resume(seriesId: item.seriesId, title: item.title, cover: item.cover) }
    }
}

// MARK: - Pieces

struct MeCategoryPills: View {
    @Binding var selection: MeCategory
    let options: [MeCategory]

    var body: some View {
        GlassSegments(options: options.map { GlassOption(label: $0.label, value: $0) }, selection: $selection, compact: true)
    }
}

struct MeEmptyNote: View {
    let text: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(text).font(.system(size: 15, weight: .semibold))
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

/// A cover with a title, one detail line and optional corner badges (like the iOS 我的 grid).
struct MeCell: View {
    static let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 18)]

    let title: String
    let cover: String
    var detail = ""
    var badge = ""
    var bottomBadge = ""
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(CoverImage(url: cover, cornerRadius: 16))
                .overlay(alignment: .topTrailing) { tag(badge).padding(8) }
                .overlay(alignment: .bottomTrailing) { tag(bottomBadge).padding(8) }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.7 : 0.08), lineWidth: hovering ? 2 : 1)
                }
                .shadow(color: .black.opacity(hovering ? 0.4 : 0.22), radius: hovering ? 18 : 8, y: hovering ? 10 : 4)
                .scaleEffect(hovering ? 1.03 : 1)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).padding(.top, 9)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
    }

    @ViewBuilder
    private func tag(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

import HongguoCore
import HongguoModels
import SwiftUI

// The six tabs. 剧场 and 排行 read the shared backend's catalogue, 追剧 the shared library's
// favourites; 推荐, 搜索 and 我的 are placeholders until the player and their page models land.

/// Shelves of catalogue lists, one per kind, loaded through the shared backend (the official App
/// catalogue live, the sample rows offline).
struct CatalogShelvesPage: View {
    @Environment(TVAppModel.self) private var app
    let kinds: [CatalogKind]
    var showsRank = false

    @State private var rows: [(CatalogKind, [SeriesSummary])] = []
    @State private var state: LoadState? = .loading
    @State private var attempt = 0

    var body: some View {
        Group {
            if let state {
                LoadStateView(state: state) { attempt += 1 }
            } else {
                ZStack {
                    AmbientBackground(tint: PlaceholderTint.color(for: rows.first?.1.first?.seriesId ?? ""))
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 40) {
                            ForEach(rows, id: \.0) { kind, items in
                                Shelf(title: kind.label, items: items, showsRank: showsRank)
                            }
                        }
                        .padding(.horizontal, 80)
                        .padding(.vertical, 40)
                    }
                    .scrollClipDisabled()
                }
            }
        }
        .task(id: attempt) { await load() }
    }

    private func load() async {
        state = .loading
        var loaded: [(CatalogKind, [SeriesSummary])] = []
        var failure: String?
        for kind in kinds {
            do {
                let page = try await app.backend.catalog(kind: kind, genre: nil, page: 1)
                if !page.items.isEmpty { loaded.append((kind, page.items)) }
            } catch {
                failure = (error as? HongguoError)?.message ?? "暂时取不到"
            }
        }
        rows = loaded
        state = loaded.isEmpty ? (failure.map { .failed($0) } ?? .empty("这里还没有剧")) : nil
    }
}

struct TheaterPage: View {
    var body: some View { CatalogShelvesPage(kinds: CatalogKind.categories) }
}

struct RankingPage: View {
    var body: some View { CatalogShelvesPage(kinds: CatalogKind.rankings, showsRank: true) }
}

/// 追剧: the favourites the shared library keeps (the account's shelf when signed in comes with
/// the 我的 page model).
struct FollowingPage: View {
    @Environment(TVAppModel.self) private var app

    var body: some View {
        let favorites = app.library.favorites()
        if favorites.isEmpty {
            LoadStateView(state: .empty("还没有在追的剧"))
        } else {
            ZStack {
                AmbientBackground(tint: PlaceholderTint.color(for: favorites[0].seriesId))
                ScrollView(.vertical) {
                    Shelf(title: "我的收藏", items: favorites.map {
                        SeriesSummary(seriesId: $0.seriesId, title: $0.title, cover: $0.cover)
                    })
                    .padding(.horizontal, 80)
                    .padding(.vertical, 40)
                }
                .scrollClipDisabled()
            }
        }
    }
}

struct RecommendPage: View {
    @Environment(TVAppModel.self) private var app

    var body: some View {
        if app.launch.offlineFixtures {
            let first = FixtureBackend.summary(1)
            ZStack {
                AmbientBackground(tint: PlaceholderTint.color(for: first.seriesId))
                HStack(spacing: 80) {
                    // Where the 9:16 player goes: full height, centred, never cropped.
                    PosterImage(series: first)
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .frame(maxHeight: 760)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(first.title).font(.title2.weight(.bold))
                        Text("\(first.episodeLabel) · \(first.heat)").foregroundStyle(.secondary)
                        Text("离线样例，没有视频画面").font(.callout).foregroundStyle(.tertiary)
                        Button("观看完整剧集", systemImage: "play.fill") {}
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                }
            }
        } else {
            LoadStateView(state: .empty("推荐刷剧即将上线"))
        }
    }
}

struct SearchPage: View {
    var body: some View {
        LoadStateView(state: .empty("搜索即将上线"))
    }
}

struct MePage: View {
    @Environment(TVAppModel.self) private var app

    var body: some View {
        LoadStateView(state: .empty(app.account.isSignedIn
            ? "已登录：\(app.account.profile?.nickname ?? "")"
            : "我的页面即将上线：扫码登录、观看历史和设置"))
    }
}

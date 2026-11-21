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

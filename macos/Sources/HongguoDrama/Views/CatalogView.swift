import SwiftUI
import HongguoCore

/// Category pages (with genre filter) and ranking pages, with infinite scroll.
struct CatalogView: View {
    let kind: CatalogKind
    @Environment(AppModel.self) private var model

    @State private var items: [SeriesSummary] = []
    @State private var genres: [Genre] = []
    @State private var genre: String = ""
    @State private var page = 0
    @State private var totalPages = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var unsupported: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            genreChip("全部", slug: "")
                            ForEach(genres) { genreChip($0.label, slug: $0.slug) }
                        }
                    }
                }
                if let unsupported {
                    ContentUnavailableView(unsupported, systemImage: "book")
                } else if items.isEmpty {
                    LoadStateView(error: error, isLoading: isLoading) { Task { await reload() } }
                } else {
                    PosterGrid(items: items) { Task { await loadMore() } }
                    if isLoading { ProgressView().frame(maxWidth: .infinity) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .padding(20)
        }
        .navigationTitle(kind.label)
        .toolbar {
            ToolbarItem {
                Button { Task { await reload(force: true) } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
            ToolbarItem {
                Button { NSWorkspace.shared.open(CatalogService.url(kind: kind, genre: genre, page: 1)) } label: {
                    Label("在官网打开", systemImage: "safari")
                }
            }
        }
        .task(id: genre) { await reload() }
    }

    private func genreChip(_ label: String, slug: String) -> some View {
        Button(label) { genre = slug }
            .buttonStyle(.bordered)
            .tint(genre == slug ? .accentColor : .secondary)
            .controlSize(.small)
    }

    private func reload(force: Bool = false) async {
        items = []
        page = 0
        totalPages = 0
        error = nil
        await load(page: 1, force: force)
    }

    private func loadMore() async {
        guard !isLoading, error == nil, totalPages == 0 || page < totalPages else { return }
        await load(page: page + 1, force: false)
    }

    private func load(page target: Int, force: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await model.catalog.browse(kind: kind, genre: genre.isEmpty ? nil : genre, page: target, forceRefresh: force)
            let known = Set(items.map(\.id))
            items += result.results.filter { !known.contains($0.id) }
            if !result.genres.isEmpty { genres = result.genres }
            page = result.page
            totalPages = result.totalPages
            unsupported = result.unsupportedMessage
            if result.results.isEmpty { totalPages = page }
        } catch {
            self.error = describe(error)
        }
    }
}

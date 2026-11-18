import SwiftUI
import HongguoCore

/// Browse and search one of the other catalogues (西饭, 河马, overseas, custom endpoints).
struct SourceCatalogView: View {
    let sourceId: String
    @Environment(AppModel.self) private var model

    @State private var items: [SeriesSummary] = []
    @State private var genres: [Genre] = []
    @State private var genre = ""
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var error: String?
    @State private var generation = 0

    private var label: String { SourceRouter.label(sourceId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: label, subtitle: subtitle) {
                    SourcePicker(current: sourceId)
                    searchField
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(GlassIconButtonStyle(diameter: 38))
                        .help("刷新")
                }
                if activeQuery.isEmpty, !genres.isEmpty {
                    GenreBar(genres: genres, selection: $genre)
                }
                if !activeQuery.isEmpty {
                    HStack(spacing: 8) {
                        Text("“\(activeQuery)” 的搜索结果").font(.system(size: 20, weight: .heavy))
                        Button("清除") { query = ""; activeQuery = "" }.buttonStyle(GlassButtonStyle())
                    }
                }
                if items.isEmpty {
                    if !isLoading, error == nil, page > 0 {
                        ContentUnavailableView(activeQuery.isEmpty ? "这里还没有内容" : "没有找到相关短剧", systemImage: "film.stack")
                    } else {
                        LoadStateView(error: error, isLoading: isLoading) { Task { await reload() } }
                    }
                } else {
                    PosterGrid(items: items) { Task { await loadMore() } }
                    if isLoading { ProgressView().frame(maxWidth: .infinity) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(alignment: .top) {
            if let cover = items.first?.cover, !cover.isEmpty {
                AmbientBackdrop(url: cover, opacity: 0.45)
                    .frame(height: 520)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
            }
        }
        .navigationTitle(label)
        .transparentToolbar()
        .task(id: "\(genre)|\(activeQuery)") { await reload() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            TextField("在\(label)里搜索", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { activeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        .padding(.horizontal, 14)
        .frame(width: 240, height: 38)
        .glassSurface(in: Capsule(), interactive: true)
    }

    private var subtitle: String {
        if items.isEmpty { return isLoading ? "加载中…" : "" }
        return hasMore ? "已加载 \(items.count) 部 · 向下滚动加载更多" : "共 \(items.count) 部"
    }

    private func reload() async {
        generation += 1
        items = []
        page = 0
        hasMore = true
        error = nil
        await load(page: 1)
    }

    private func loadMore() async {
        guard !isLoading, error == nil, hasMore else { return }
        await load(page: page + 1)
    }

    private func load(page target: Int) async {
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            guard let source = try SourceRouter.catalogue(sourceId) else { return }
            let result = activeQuery.isEmpty
                ? try await source.browse(genre: genre.isEmpty ? nil : genre, page: target)
                : try await source.search(activeQuery, page: target)
            guard token == generation else { return }
            let known = Set(items.map(\.id))
            items += result.results.filter { !known.contains($0.id) }
            if !result.genres.isEmpty, activeQuery.isEmpty { genres = result.genres }
            page = result.page
            hasMore = result.hasMore && !result.results.isEmpty
        } catch is CancellationError {
        } catch {
            guard token == generation else { return }
            page = max(page, 1)
            self.error = describe(error)
        }
    }
}

/// 发现 page source switch: 红果 (the category pages) or another enabled catalogue.
struct SourcePicker: View {
    let current: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let sources = model.settings.mediaSources
        if sources.count > 1 {
            Menu {
                ForEach(sources, id: \.id) { entry in
                    Button {
                        select(entry.id)
                    } label: {
                        if entry.id == current { Label(entry.label, systemImage: "checkmark") } else { Text(entry.label) }
                    }
                }
                Divider()
                SettingsLink { Text("管理片源…") }
            } label: {
                Label("片源：\(SourceRouter.label(current))", systemImage: "film.stack")
            }
            .menuStyle(.button)
            .buttonStyle(GlassButtonStyle())
            .menuIndicator(.visible)
            .fixedSize()
            .help("切换片源")
        }
    }

    private func select(_ id: String) {
        guard id != current else { return }
        model.selection = id == "hongguo" ? .category(.realDrama) : .source(id)
    }
}

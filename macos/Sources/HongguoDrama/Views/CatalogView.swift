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

    private var featured: SeriesSummary? { genre.isEmpty ? items.first : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let featured {
                    FeaturedHero(summary: featured, badge: kind.isRanking ? "\(kind.label) No.1" : "今日主推")
                }
                if !genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GenreBar(genres: genres, selection: $genre)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 2)
                    }
                    .scrollClipDisabled()
                }
                if let unsupported {
                    ContentUnavailableView(unsupported, systemImage: "book")
                } else if items.isEmpty {
                    LoadStateView(error: error, isLoading: isLoading) { Task { await reload() } }
                } else {
                    Text(sectionTitle).font(.system(size: 18, weight: .bold))
                    PosterGrid(items: items) { Task { await loadMore() } }
                    if isLoading { ProgressView().frame(maxWidth: .infinity) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(alignment: .top) {
            // Featured cover as a coloured light source, extended under the sidebar and toolbar.
            if let cover = items.first?.cover, !cover.isEmpty {
                AmbientBackdrop(url: cover, opacity: 0.55)
                    .frame(height: 560)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
            }
        }
        .navigationTitle(kind.label)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await reload(force: true) } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                Button { NSWorkspace.shared.open(CatalogService.url(kind: kind, genre: genre, page: 1)) } label: {
                    Label("在官网打开", systemImage: "safari")
                }
            }
        }
        .task(id: genre) { await reload() }
    }

    private var sectionTitle: String {
        if !genre.isEmpty { return genres.first { $0.slug == genre }?.label ?? "筛选结果" }
        return kind.isRanking ? "完整榜单" : "热播中"
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

/// Genre filter: one glass capsule, the selected genre is a bright pill that slides between items.
struct GenreBar: View {
    let genres: [Genre]
    @Binding var selection: String

    var body: some View {
        GlassSegments(options: [GlassOption(label: "全部", value: "")] + genres.map { GlassOption(label: $0.label, value: $0.slug) },
                      selection: $selection)
    }
}

/// Large featured item at the top of a catalog page.
struct FeaturedHero: View {
    let summary: SeriesSummary
    let badge: String
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .bottom, spacing: 26) {
            Button { model.open(summary) } label: {
                CoverImage(url: summary.cover, cornerRadius: 20)
                    .frame(width: 186, height: 248)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            }
            .buttonStyle(.plain)
            .help("查看详情")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(Color.hongguoRed).frame(width: 6, height: 6)
                    Text(badge)
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .glassSurface(.clear, in: Capsule())

                Text(summary.title)
                    .font(.system(size: 40, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !meta.isEmpty {
                    Text(meta).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if !summary.description.isEmpty {
                    Text(summary.description)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await PlayerController.shared.open(seriesId: summary.seriesId, title: summary.title, cover: summary.cover) }
                    } label: {
                        Label("播放第 1 集", systemImage: "play.fill")
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                    Button { model.open(summary) } label: { Label("详情", systemImage: "info.circle") }
                        .buttonStyle(GlassButtonStyle(size: .large))
                }
                .padding(.top, 4)
            }
            .padding(.bottom, 4)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private var meta: String {
        var parts = Array(summary.tags.prefix(2))
        if !summary.episodeLabel.isEmpty {
            parts.append(summary.episodeLabel)
        } else if summary.episodeCount > 0 {
            parts.append("\(summary.episodeCount) 集")
        }
        if !summary.heat.isEmpty { parts.append(summary.heat) }
        return parts.joined(separator: " · ")
    }
}

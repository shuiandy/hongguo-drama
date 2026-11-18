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

    @State private var heroIndex = 0

    private var featuredItems: [SeriesSummary] { genre.isEmpty ? Array(items.prefix(5)) : [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: kind.label, subtitle: subtitle) {
                    HeaderSearchField()
                    Button { Task { await reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(GlassIconButtonStyle(diameter: 38))
                        .help("刷新")
                }
                if !featuredItems.isEmpty {
                    FeaturedCarousel(items: featuredItems, index: $heroIndex,
                                     badge: kind.isRanking ? "\(kind.label) No.\(heroIndex + 1)" : "今日主推")
                }
                if !genres.isEmpty {
                    GenreBar(genres: genres, selection: $genre)
                }
                if let unsupported {
                    ContentUnavailableView(unsupported, systemImage: "book")
                } else if items.isEmpty {
                    LoadStateView(error: error, isLoading: isLoading) { Task { await reload() } }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(sectionTitle).font(.system(size: 20, weight: .heavy))
                        Text(kind.isRanking ? "按榜单排名" : "按热度排序").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
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
            // Current featured cover as a coloured light source, extended under the sidebar and toolbar.
            if let cover = (featuredItems.indices.contains(heroIndex) ? featuredItems[heroIndex] : items.first)?.cover, !cover.isEmpty {
                AmbientBackdrop(url: cover, opacity: 0.55)
                    .frame(height: 620)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.5), value: cover)
            }
        }
        .navigationTitle(kind.label)
        .transparentToolbar()
        .task(id: genre) { heroIndex = 0; await reload() }
    }

    private var subtitle: String {
        if items.isEmpty { return isLoading ? "加载中…" : "" }
        return totalPages > page ? "已加载 \(items.count) 部 · 向下滚动加载更多" : "共 \(items.count) 部"
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


/// Genre filter: one glass capsule that scrolls horizontally, fades at the edge, with a scroll button.
struct GenreBar: View {
    let genres: [Genre]
    @Binding var selection: String

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassSegments(options: [GlassOption(label: "全部", value: "")] + genres.map { GlassOption(label: $0.label, value: $0.slug) },
                                  selection: $selection)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                        .overlay(alignment: .trailing) { Color.clear.frame(width: 1).id("genre-end") }
                }
                .scrollClipDisabled()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                Button { withAnimation { proxy.scrollTo("genre-end", anchor: .trailing) } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(GlassIconButtonStyle(diameter: 36))
                    .help("更多题材")
            }
        }
    }
}

/// Wide featured card that pages through the top items.
struct FeaturedCarousel: View {
    let items: [SeriesSummary]
    @Binding var index: Int
    let badge: String
    @Environment(AppModel.self) private var model

    private var summary: SeriesSummary { items[min(index, items.count - 1)] }

    var body: some View {
        HStack(alignment: .bottom, spacing: 30) {
            Button { model.open(summary) } label: {
                CoverImage(url: summary.cover, cornerRadius: 20)
                    .frame(width: 186, height: 248)
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
            }
            .buttonStyle(.plain)
            .help("查看详情")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.hongguoRed).frame(width: 6, height: 6)
                        Text(badge)
                    }
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .glassSurface(.clear, in: Capsule())
                    if !summary.heat.isEmpty { GlassTag(text: summary.heat, systemImage: "flame.fill", iconColor: .orange) }
                }
                Text(summary.title)
                    .font(.system(size: 40, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !meta.isEmpty {
                    Text(meta).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                if !summary.description.isEmpty {
                    Text(summary.description)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 640, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await PlayerController.shared.open(seriesId: summary.seriesId, title: summary.title, cover: summary.cover) }
                    } label: {
                        Label("播放第 1 集", systemImage: "play.fill")
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                    Button("查看详情") { model.open(summary) }
                        .buttonStyle(GlassButtonStyle(size: .large))
                    Spacer(minLength: 12)
                    if items.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(items.indices, id: \.self) { i in
                                Capsule()
                                    .fill(i == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.35)))
                                    .frame(width: i == index ? 18 : 6, height: 6)
                            }
                        }
                        Button { step(-1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(GlassIconButtonStyle(diameter: 36))
                            .help("上一部")
                        Button { step(1) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(GlassIconButtonStyle(diameter: 36))
                            .help("下一部")
                    }
                }
                .padding(.top, 2)
            }
            .padding(.bottom, 2)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            AmbientBackdrop(url: summary.cover, blur: 40, opacity: 0.45)
                .overlay(LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing))
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .glassSurface(.clear, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .animation(.easeInOut(duration: 0.35), value: index)
        .task(id: items.map(\.id)) {
            // Auto-advance every 8 s.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                step(1)
            }
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }

    private var meta: String {
        var parts = Array(summary.tags.prefix(2))
        if !summary.episodeLabel.isEmpty {
            parts.append(summary.episodeLabel)
        } else if summary.episodeCount > 0 {
            parts.append("\(summary.episodeCount) 集")
        }
        return parts.joined(separator: " · ")
    }
}

import SwiftUI
import HongguoCore

/// 热播推荐 (port of DramaFeed + RandomDrama): one recommended series at a time from a Hongguo
/// ranking or another source's catalogue, with the next few queued below, plus 摇一摇 which draws
/// a random series from every enabled source.
struct FeedView: View {
    @Environment(AppModel.self) private var model

    enum Mode: Hashable, Sendable { case ranking(CatalogKind), sourceList, random }

    @State private var source = "hongguo"
    @State private var mode: Mode = .ranking(.hotDrama)
    @State private var items: [SeriesSummary] = []
    @State private var index = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var updatedAt: Date?
    /// Session cache, so switching tabs shows the last list at once while it refreshes.
    @State private var cache: [String: (items: [SeriesSummary], at: Date)] = [:]
    // 摇一摇
    @State private var randomScope = "all"
    @State private var pool: [SeriesSummary] = []
    @State private var drawn: SeriesSummary?
    @State private var drawCount = 0

    private var sources: [MediaSources.Entry] { model.settings.mediaSources }
    private var selected: SeriesSummary? {
        if mode == .random { return drawn }
        return items.indices.contains(index) ? items[index] : nil
    }
    private var cacheKey: String {
        switch mode {
        case .ranking(let kind): return "hongguo:\(kind.rawValue)"
        case .sourceList: return "\(source):list"
        case .random: return "random:\(randomScope)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "热播推荐", subtitle: subtitle) {
                    if mode != .random, sources.count > 1 {
                        Picker("来源", selection: $source) {
                            ForEach(sources, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                        .help("推荐来源")
                    }
                    if mode == .random, sources.count > 1 {
                        Picker("抽取范围", selection: $randomScope) {
                            Text("全部来源").tag("all")
                            ForEach(sources, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                        .help("抽取范围")
                    }
                    Button { Task { await reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(GlassIconButtonStyle(diameter: 38))
                        .help("刷新片单")
                }
                GlassSegments(options: modeOptions, selection: $mode)

                if let selected {
                    hero(selected)
                    if mode != .random { upcoming }
                } else {
                    LoadStateView(error: error, isLoading: isLoading) { Task { await reload(force: true) } }
                    if !isLoading, error == nil {
                        ContentUnavailableView("这个来源暂未返回可用片单", systemImage: "film.stack",
                                               description: Text("可以刷新，或切换来源。"))
                            .frame(maxWidth: .infinity)
                    }
                }
                if selected != nil, let error {
                    Label("片单未更新：\(error)", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(alignment: .top) {
            if let cover = selected?.cover, !cover.isEmpty {
                AmbientBackdrop(url: cover, opacity: 0.55)
                    .frame(height: 620)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.5), value: cover)
            }
        }
        .navigationTitle("热播推荐")
        .transparentToolbar()
        .task(id: cacheKey) { await reload(force: false) }
        .onChange(of: source) { _, value in
            mode = value == "hongguo" ? .ranking(.hotDrama) : .sourceList
        }
    }

    private var modeOptions: [GlassOption<Mode>] {
        var options: [GlassOption<Mode>] = source == "hongguo"
            ? CatalogKind.rankings.map { GlassOption(label: $0.label, value: Mode.ranking($0)) }
            : [GlassOption(label: "来源片单", value: Mode.sourceList)]
        options.append(GlassOption(label: "摇一摇", value: Mode.random))
        return options
    }

    private var subtitle: String {
        if mode == .random { return pool.isEmpty ? "今晚，看点意料之外的" : "随机抽取 · 共 \(pool.count) 部可抽" }
        guard !items.isEmpty else { return isLoading ? "加载中…" : "从热播榜和来源片单，遇见下一部故事。" }
        var text = "第 \(index + 1) / \(items.count) 部"
        if let updatedAt { text += " · \(updatedAt.formatted(date: .omitted, time: .shortened)) 更新" }
        if isLoading { text += " · 正在更新…" }
        return text
    }

    private func hero(_ item: SeriesSummary) -> some View {
        HStack(alignment: .bottom, spacing: 30) {
            Button { model.open(item) } label: {
                CoverImage(url: item.cover, cornerRadius: 22)
                    .frame(width: 240, height: 320)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            }
            .buttonStyle(.plain)
            .help("查看详情")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if mode == .random {
                        GlassTag(text: "随机抽取", systemImage: "dice.fill", iconColor: .hongguoRed)
                        GlassTag(text: SourceRouter.label(MediaSources.sourceId(of: item.seriesId)))
                    } else if let rank = item.rank {
                        GlassTag(text: "No.\(rank)", systemImage: "flame.fill", iconColor: .orange)
                    }
                    if !item.heat.isEmpty { GlassTag(text: item.heat, systemImage: "flame.fill", iconColor: .orange) }
                    if model.isFavorite(item.seriesId) { GlassTag(text: "已收藏", systemImage: "heart.fill", iconColor: .hongguoRed) }
                }
                Text(item.title).font(.system(size: 40, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7)
                let meta = metaLine(item)
                if !meta.isEmpty { Text(meta).font(.system(size: 14)).foregroundStyle(.secondary) }
                if !item.description.isEmpty {
                    Text(item.description).font(.system(size: 14)).lineSpacing(3).foregroundStyle(.secondary)
                        .lineLimit(4).frame(maxWidth: 640, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await PlayerController.shared.open(seriesId: item.seriesId, title: item.title, cover: item.cover) }
                    } label: { Label("播放第 1 集", systemImage: "play.fill") }
                        .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                    Button("查看详情") { model.open(item) }.buttonStyle(GlassButtonStyle(size: .large))
                    if mode == .random {
                        Button { draw() } label: { Label("再摇一次", systemImage: "dice") }
                            .buttonStyle(GlassButtonStyle(size: .large))
                            .disabled(pool.count < 2)
                    } else {
                        Spacer(minLength: 12)
                        Button { step(-1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(GlassIconButtonStyle(diameter: 36)).disabled(index == 0).help("上一部")
                        Button { step(1) } label: { Label("下一部", systemImage: "chevron.right") }
                            .buttonStyle(GlassButtonStyle(size: .large)).disabled(index >= items.count - 1)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.clear, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .id(item.seriesId)
        .transition(.opacity)
    }

    @ViewBuilder
    private var upcoming: some View {
        let next = Array(items.dropFirst(index + 1).prefix(6))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("接下来").font(.system(size: 20, weight: .heavy))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 18)], alignment: .leading, spacing: 24) {
                    ForEach(next) { PosterCell(item: $0) }
                }
            }
        }
    }

    private func metaLine(_ item: SeriesSummary) -> String {
        var parts = Array(item.tags.prefix(3))
        if !item.episodeLabel.isEmpty { parts.append(item.episodeLabel) }
        else if item.episodeCount > 0 { parts.append("\(item.episodeCount) 集") }
        return parts.joined(separator: " · ")
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { index = next }
    }

    private func draw() {
        guard !pool.isEmpty else { drawn = nil; return }
        let others = pool.filter { $0.seriesId != drawn?.seriesId }
        withAnimation(.easeInOut(duration: 0.25)) { drawn = (others.isEmpty ? pool : others).randomElement() }
        drawCount += 1
    }

    /// Shows the cached list first, then refreshes; a failed refresh keeps the old list.
    private func reload(force: Bool) async {
        let key = cacheKey
        error = nil
        if mode == .random {
            if !force, let cached = cache[key] { pool = cached.items; if drawn == nil { draw() }; return }
            pool = []; drawn = nil
        } else if let cached = cache[key] {
            items = cached.items; updatedAt = cached.at
            if !force { index = min(index, max(0, items.count - 1)); if Date().timeIntervalSince(cached.at) < 300 { return } }
        } else {
            items = []; index = 0; updatedAt = nil
        }
        isLoading = true
        defer { if key == cacheKey { isLoading = false } }
        do {
            let fresh: [SeriesSummary]
            switch mode {
            case .ranking(let kind):
                fresh = try await model.catalog.browse(kind: kind, page: 1, forceRefresh: force).results
            case .sourceList:
                fresh = try await Self.browse(source)
            case .random:
                fresh = await Self.randomPool(scope: randomScope, sources: sources, catalog: model.catalog)
                if fresh.isEmpty { throw HongguoError(.upstream, "没有读到可抽取的片单，请稍后重试") }
            }
            guard key == cacheKey else { return }
            var seen = Set<String>()
            let unique = fresh.filter { !$0.title.isEmpty && seen.insert($0.seriesId).inserted }
            cache[key] = (unique, Date())
            if mode == .random {
                pool = unique
                draw()
            } else {
                let keep = selected?.seriesId
                items = unique
                updatedAt = Date()
                index = keep.flatMap { id in unique.firstIndex { $0.seriesId == id } } ?? 0
            }
        } catch {
            guard key == cacheKey else { return }
            self.error = describe(error)
        }
    }

    private static func browse(_ sourceId: String) async throws -> [SeriesSummary] {
        guard let source = try SourceRouter.catalogue(sourceId) else { throw HongguoError(.input, "来源不可用") }
        return try await source.browse(genre: nil, page: 1).results
    }

    /// The draw pool: page 1 of the Hongguo rankings and of each enabled source, whatever answers.
    private static func randomPool(scope: String, sources: [MediaSources.Entry], catalog: CatalogService) async -> [SeriesSummary] {
        let ids = scope == "all" ? sources.map(\.id) : [scope]
        return await withTaskGroup(of: [SeriesSummary].self) { group in
            for id in ids {
                if id == "hongguo" {
                    for kind in CatalogKind.rankings + CatalogKind.categories {
                        group.addTask { (try? await catalog.browse(kind: kind, page: 1).results) ?? [] }
                    }
                } else {
                    group.addTask { (try? await browse(id)) ?? [] }
                }
            }
            var all: [SeriesSummary] = []
            for await list in group { all += list }
            return all
        }
    }
}

/// 上新日历 (port of ReleaseCalendar): the series kept on this Mac (opened or favourited) that
/// have a public first-release date, grouped by month, newest first. Watched series without a
/// date get one looked up in the background while the page is open.
struct ReleaseCalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var favoritesOnly = false

    private var months: [(month: String, series: [LibrarySeries])] {
        _ = model.libraryRevision
        return model.library.calendar(favoritesOnly: favoritesOnly)
    }

    var body: some View {
        let months = months
        let dated = months.reduce(0) { $0 + $1.series.count }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "上新日历", subtitle: "本机收录 \(model.library.recent().count) 部 · 有公开日期 \(dated) 部") {
                    GlassSegments(options: [GlassOption(label: "全部", value: false), GlassOption(label: "只看收藏", value: true)],
                                  selection: $favoritesOnly)
                }
                if let progress = model.publishBackfill {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在补全上线日期 \(progress.done)/\(progress.total)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if months.isEmpty {
                    ContentUnavailableView(favoritesOnly ? "收藏的剧里还没有带公开日期的" : "还没有带公开日期的剧", systemImage: "calendar",
                                           description: Text("看过、打开过或收藏的剧，查到首播日期后会自动出现在这里。"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    ForEach(months, id: \.month) { group in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Self.monthTitle(group.month)).font(.system(size: 20, weight: .heavy))
                                Text("\(group.series.count) 部").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 18)], alignment: .leading, spacing: 24) {
                                ForEach(group.series) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        PosterCell(item: item.summary)
                                        HStack(spacing: 4) {
                                            Text(Self.dayTitle(item.publicDateKey)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.hongguoRed)
                                            if item.favorite { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(Color.hongguoRed) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .navigationTitle("上新日历")
        .transparentToolbar()
        .onAppear { model.refreshLibrary() }
        // Cancelled when the page goes away.
        .task { await model.backfillPublishDates() }
    }

    /// "2026-11" to "2026 年 11 月".
    static func monthTitle(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return key }
        return "\(parts[0]) 年 \(month) 月"
    }

    /// "2026-11-18" to "11 月 18 日首播".
    static func dayTitle(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return key }
        return "\(month) 月 \(day) 日首播"
    }
}

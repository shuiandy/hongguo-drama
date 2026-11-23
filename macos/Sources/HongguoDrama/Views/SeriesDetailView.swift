import SwiftUI
import HongguoCore

struct SeriesDetailView: View {
    let summary: SeriesSummary
    @Environment(AppModel.self) private var model

    @State private var episodes: SeriesEpisodes?
    @State private var details: PublicDetails?
    @State private var error: String?
    @State private var isLoading = false
    @State private var expanded = false

    private var record: WatchRecord? { model.history.first { $0.seriesId == summary.seriesId } }
    private var title: String { episodes?.title ?? summary.title }
    private var cover: String { [episodes?.cover, details?.cover, summary.cover].compactMap { $0 }.first { !$0.isEmpty } ?? "" }

    @State private var showAllReviews = false
    @State private var downloadNotice: String?
    // 查找下一季 (manual sequel finder).
    @State private var foundSequels: [SeriesRef]?
    @State private var similarSeries: [SeriesRef] = []
    @State private var findingSequels = false
    @State private var sequelError = ""
    // 系列剧 from the App (other seasons of the same story).
    @State private var seasons: DiscoveryAccess.SameIPSeriesResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                info
                if let sequels = record?.sequels, !sequels.isEmpty {
                    sequelRow(sequels)
                }
                sequelFinder
                seasonShelf
                castShelf
                episodePanel
                if let reviews = details?.reviews, !reviews.isEmpty {
                    reviewList(reviews)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(alignment: .top) {
            // The top of the page is lit by the cover.
            if !cover.isEmpty {
                AmbientBackdrop(url: cover, blur: 80, opacity: 0.6)
                    .frame(height: 760)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
            }
        }
        .navigationTitle(title)
        .transparentToolbar()
        .task {
            model.acknowledgeUpdates(summary.seriesId)
            await load()
        }
        .task(id: summary.seriesId) {
            // So "继续第 N 集" shows where any device left off, not only this Mac.
            await model.syncCloudPosition(seriesId: summary.seriesId)
        }
        .task(id: summary.seriesId) {
            seasons = try? await DiscoveryAccess.sameIPSeries(seriesId: summary.seriesId)
        }
    }

    /// 系列剧: the other seasons the App lists for this story. Seasons not out yet show 待上线.
    @ViewBuilder
    private var seasonShelf: some View {
        let items = (seasons?.items ?? []).filter { !$0.title.isEmpty }
        if items.contains(where: { $0.seriesId != summary.seriesId }) {
            VStack(alignment: .leading, spacing: 10) {
                Label(seasons?.tabTitle.isEmpty == false ? seasons!.tabTitle : "系列剧", systemImage: "square.stack.3d.up")
                    .font(.system(size: 13, weight: .semibold))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in seasonCard(item) }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
            }
        }
    }

    /// 演员: the cast from the App detail; each opens the actor's page with their other works.
    @ViewBuilder
    private var castShelf: some View {
        if let cast = details?.cast, !cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("演员", systemImage: "person.2").font(.system(size: 13, weight: .semibold))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(cast) { member in
                            Button { model.openCelebrity(member) } label: {
                                VStack(spacing: 6) {
                                    CoverImage(url: member.avatar, cornerRadius: 32)
                                        .frame(width: 64, height: 64)
                                    Text(member.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    if !member.role.isEmpty {
                                        Text(member.role).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .frame(width: 84)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("查看 \(member.name) 的作品")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func seasonCard(_ item: DiscoveryAccess.RelatedSeriesItem) -> some View {
        let current = item.seriesId == summary.seriesId
        let badge = current ? "当前" : (item.disablePlay ? "待上线" : item.badgeText)
        return Button {
            model.open(SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover, episodeCount: item.episodeCount))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(url: item.cover, cornerRadius: 12)
                    .frame(width: 96, height: 128)
                    .overlay(alignment: .topLeading) {
                        if !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(current ? Color.hongguoRed : .black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                let meta = [item.seasonIndex > 0 ? "第\(item.seasonIndex)部" : "", item.episodeCount > 0 ? "\(item.episodeCount)集" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .frame(width: 96, alignment: .leading)
            .opacity(item.disablePlay && !current ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(current || item.disablePlay)
        .help(item.disablePlay ? "\(item.title) 还没上线" : "打开 \(item.title)")
    }

    /// Later seasons found by the watch-update check.
    private func sequelRow(_ sequels: [SeriesRef], label: String = "续作") -> some View {
        HStack(spacing: 8) {
            Label(label, systemImage: "rectangle.stack.badge.plus").font(.system(size: 13, weight: .semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(sequels, id: \.seriesId) { ref in
                        Button(ref.title) { model.open(SeriesSummary(seriesId: ref.seriesId, title: ref.title, cover: "")) }
                            .buttonStyle(GlassButtonStyle())
                            .help("打开 \(ref.title)")
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// 查找当前剧的下一季: searches by the title without its season marker and lists later seasons,
    /// plus similarly named series that may be renamed sequels.
    @ViewBuilder
    private var sequelFinder: some View {
        if foundSequels != nil || findingSequels || !sequelError.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if findingSequels {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在查找下一季…").foregroundStyle(.secondary) }
                        .font(.system(size: 12))
                } else if !sequelError.isEmpty {
                    Text(sequelError).font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let foundSequels {
                    let known = Set((record?.sequels ?? []).map(\.seriesId))
                    let fresh = foundSequels.filter { !known.contains($0.seriesId) }
                    if !fresh.isEmpty { sequelRow(fresh, label: "找到的续作") }
                    if !similarSeries.isEmpty { sequelRow(similarSeries, label: "可能的续作，请核对剧名") }
                    if fresh.isEmpty && similarSeries.isEmpty {
                        Text(known.isEmpty ? "没有找到下一季" : "没有找到更多续作").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func findSequels() async {
        guard !findingSequels else { return }
        findingSequels = true
        sequelError = ""
        defer { findingSequels = false }
        let current = SeriesRef(seriesId: summary.seriesId, title: title)
        let keyword = WatchHistory.sequelKeyword(title)
        guard !keyword.isEmpty else { sequelError = "这部剧的名称无法用来查找续作"; return }
        do {
            let result = try await model.search.search(keyword)
            let candidates = result.results.map { SeriesRef(seriesId: $0.seriesId, title: $0.title) }
            let sequels = WatchHistory.findSequels(of: current, in: candidates)
            foundSequels = sequels
            let taken = Set(sequels.map(\.seriesId))
            similarSeries = WatchHistory.findSimilar(to: current, in: candidates).filter { !taken.contains($0.seriesId) }
        } catch {
            sequelError = "查找失败：\(describe(error))"
        }
    }

    // MARK: Header

    private var info: some View {
        HStack(alignment: .bottom, spacing: 28) {
            CoverImage(url: cover, cornerRadius: 22)
                .frame(width: 200, height: 267)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 42, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                FlowLayout(spacing: 6) {
                    if let rating = details?.rating, rating > 0 {
                        GlassTag(text: String(format: "%.1f", rating), systemImage: "star.fill", iconColor: .hongguoGold)
                    }
                    if let label = details?.episodeLabel, !label.isEmpty {
                        GlassTag(text: label)
                    } else if let total = episodes?.total {
                        GlassTag(text: "共 \(total) 集")
                    }
                    if let likes = details?.likeCount { GlassTag(text: formatCount(likes), systemImage: "heart.fill", iconColor: .hongguoRed) }
                    if !summary.heat.isEmpty { GlassTag(text: summary.heat, systemImage: "flame.fill", iconColor: .orange) }
                    // As in the official app, a tag searches for itself.
                    ForEach((details?.tags.isEmpty == false ? details?.tags ?? [] : summary.tags).prefix(6), id: \.self) { tag in
                        Button { model.search(tag) } label: { GlassTag(text: tag, trailingSystemImage: "chevron.right") }
                            .buttonStyle(.plain)
                            .help("搜索“\(tag)”")
                    }
                }
                let description = details?.description.isEmpty == false ? details!.description : summary.description
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 3)
                        .frame(maxWidth: 860, alignment: .leading)
                        .textSelection(.enabled)
                        .onTapGesture { withAnimation { expanded.toggle() } }
                        .help(expanded ? "收起" : "展开全部")
                }
                HStack(spacing: 10) {
                    if let record, record.episodeIndex > 0 {
                        Button { continueWatching() } label: {
                            Label("继续第 \(record.episodeIndex) 集 \(formatTime(record.position))", systemImage: "play.fill")
                        }
                        .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                        Button("从第 1 集播放") { play(index: 1, resume: false) }
                            .buttonStyle(GlassButtonStyle(size: .large))
                    } else {
                        Button { play(index: 1, resume: false) } label: { Label("播放第 1 集", systemImage: "play.fill") }
                            .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                    }
                    let favorite = model.isFavorite(summary.seriesId)
                    Button { model.toggleFavorite(seriesId: summary.seriesId, title: title, cover: cover) } label: {
                        Label(favorite ? "已收藏" : "收藏", systemImage: favorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(GlassButtonStyle(size: .large))
                    .help(favorite ? "取消收藏" : "加入我的剧库")
                    Button { Task { await findSequels() } } label: { Label("查找下一季", systemImage: "rectangle.stack.badge.plus") }
                        .buttonStyle(GlassButtonStyle(size: .large))
                        .disabled(findingSequels)
                        .help("按剧名查找这部剧的下一季和可能的续作")
                    Menu {
                        if let episodes {
                            Button("下载全部 \(episodes.total) 集") { download(episodes.episodes) }
                            let next = record?.episodeIndex ?? 1
                            if next > 1 {
                                Button("从第 \(next) 集开始下载") { download(episodes.episodes.filter { $0.index >= next }) }
                            }
                            let missing = episodes.episodes.filter { model.localFiles[$0.vid] == nil }
                            if missing.count != episodes.total, !missing.isEmpty {
                                Button("下载剩余 \(missing.count) 集") { download(missing) }
                            }
                            Divider()
                            Button("下载到 NAS…") {
                                Task { if let message = await model.downloadToNAS(episodes, cover: cover) { downloadNotice = message } }
                            }
                            let localCount = episodes.episodes.filter { model.localFiles[$0.vid] != nil }.count
                            if localCount >= 2 {
                                Divider()
                                Button("合并已下载的 \(localCount) 集（快速，不重新编码）") { merge(.fast) }
                                Button("合并为兼容格式（H.264，较慢）") { merge(.compatible) }
                            }
                            Divider()
                            Button("打开下载管理") { model.selection = .downloads }
                        }
                    } label: {
                        Label(downloadLabel, systemImage: "arrow.down.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(GlassButtonStyle(size: .large))
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .disabled(episodes == nil)
                .padding(.top, 4)
                if let downloadNotice {
                    Label(downloadNotice, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .task(id: downloadNotice) {
                            try? await Task.sleep(for: .seconds(8))
                            self.downloadNotice = nil
                        }
                }
            }
            .padding(.bottom, 4)
            Spacer(minLength: 0)
        }
    }

    // MARK: Episodes

    private var episodePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("选集").font(.system(size: 20, weight: .heavy))
                if let episodes {
                    Text(record.map { "已看 \(min($0.completedEpisode, episodes.total)) / \(episodes.total)" } ?? "共 \(episodes.total) 集")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let episodes {
                EpisodeGrid(episodes: episodes.episodes,
                            current: record?.episodeIndex,
                            completed: record?.completedEpisode ?? 0,
                            minimumCellWidth: 58) { episode in
                    play(index: episode.index, resume: record?.episodeIndex == episode.index)
                }
                EpisodeLegend(showsAppSource: (episodes.webAccessibleEpisodes ?? episodes.total) < episodes.total)
                    .padding(.top, 4)
            } else {
                LoadStateView(error: error, isLoading: isLoading) { Task { await load(force: true) } }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func reviewList(_ reviews: [Review]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("热评").font(.system(size: 20, weight: .heavy))
                if let total = details?.reviewTotal { Text("\(total) 条").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(reviews.prefix(showAllReviews ? 50 : 9)) { review in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            CoverImage(url: review.avatar, cornerRadius: 12).frame(width: 24, height: 24)
                            Text(review.author.isEmpty ? "匿名用户" : review.author)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let likes = review.likes, likes > 0 {
                                Label(formatCount(likes), systemImage: "hand.thumbsup").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        EmoticonText(review.content, size: 14)
                            .lineSpacing(3)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            if reviews.count > 9 && !showAllReviews {
                Button("展开全部 \(reviews.count) 条评论") { withAnimation { showAllReviews = true } }
                    .buttonStyle(GlassButtonStyle())
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var downloadLabel: String {
        guard let episodes else { return "下载" }
        let done = episodes.episodes.filter { model.localFiles[$0.vid] != nil }.count
        return done > 0 ? "已下载 \(done)/\(episodes.total)" : "下载"
    }

    private func download(_ list: [Episode]) {
        let id = summary.seriesId, title = title, cover = cover
        Task {
            let added = await model.download(list, seriesId: id, title: title, cover: cover)
            downloadNotice = added > 0 ? "已加入下载队列：\(added) 集" : "这些集已经在下载列表里了"
        }
    }

    private func merge(_ mode: MergeExporter.Mode) {
        let id = summary.seriesId, title = title
        Task { downloadNotice = await model.startMerge(seriesId: id, title: title, mode: mode) }
    }

    private func load(force: Bool = false) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let service = model.series
        let seriesId = summary.seriesId
        async let detailsTask = try? service.publicDetails(seriesId: seriesId)
        do {
            let list = try await service.episodes(seriesId: seriesId, force: force)
            episodes = list
            // The episode the play button starts and the ones after it, in one request, so the
            // first click does not wait for the play model.
            let first = max(0, min((record?.episodeIndex ?? 1) - 1, list.episodes.count - 1))
            let vids = Array(list.episodes.dropFirst(first).prefix(6).map(\.vid))
            if !vids.isEmpty { Task { await service.prefetchPlayInfo(vids: vids) } }
            _ = try? model.library.recordOpened(seriesId: seriesId, title: list.title, cover: cover, episodeCount: list.total,
                                                publishedAt: summary.publishedAt)
        } catch {
            self.error = describe(error)
        }
        details = await detailsTask
        // Opened from a link without a cover: keep the one the page found for the library.
        if !cover.isEmpty, let kept = model.library.series(seriesId), kept.cover.isEmpty {
            _ = try? model.library.recordOpened(seriesId: seriesId, title: title, cover: cover)
            model.refreshLibrary()
        }
        // Opened from history or search, the summary has no first-release date; the detail page does.
        if summary.publishedAt == nil, let date = details?.publishedAt, let kept = model.library.series(seriesId), kept.publishedAt == nil {
            _ = try? model.library.recordPublishDate(seriesId: seriesId, title: kept.title, publishedAt: date, openedAt: kept.lastOpenedAt)
        }
    }

    private func continueWatching() {
        guard let episodes else { return }
        Task { await PlayerController.shared.resume(episodes: episodes, cover: cover) }
    }

    private func play(index: Int, resume: Bool) {
        guard let episodes else { return }
        let position = resume && record?.episodeIndex == index ? record?.position ?? 0 : 0
        PlayerController.shared.open(episodes: episodes, cover: cover, index: index, startAt: position)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "" }
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatCount(_ value: Int) -> String {
    value >= 10000 ? String(format: "%.1f万", Double(value) / 10000) : "\(value)"
}

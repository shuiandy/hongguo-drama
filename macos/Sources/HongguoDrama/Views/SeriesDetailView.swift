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

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                Group {
                    if proxy.size.width >= 1000 {
                        HStack(alignment: .top, spacing: 28) {
                            info.frame(width: min(560, proxy.size.width * 0.46))
                            episodePanel
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            info
                            episodePanel
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
        .background {
            // The whole page is lit by the cover.
            if !cover.isEmpty {
                AmbientBackdrop(url: cover, blur: 80, opacity: 0.65)
                    .overlay(LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.55)],
                                            startPoint: .leading, endPoint: .trailing))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                Button { copyShareText() } label: { Label("复制链接", systemImage: "link") }
                Button { NSWorkspace.shared.open(Site.detailURL(summary.seriesId)) } label: { Label("在官网打开", systemImage: "safari") }
            }
        }
        .task { await load() }
    }

    // MARK: Left column

    private var info: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 22) {
                CoverImage(url: cover, cornerRadius: 18)
                    .frame(width: 168, height: 224)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 34, weight: .heavy))
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
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
                        ForEach(summary.tags.prefix(3), id: \.self) { GlassTag(text: $0) }
                    }
                }
                .padding(.bottom, 4)
            }

            let description = details?.description.isEmpty == false ? details!.description : summary.description
            if !description.isEmpty {
                Text(description)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 4)
                    .textSelection(.enabled)
                    .onTapGesture { withAnimation { expanded.toggle() } }
                    .help(expanded ? "收起" : "展开全部")
            }

            HStack(spacing: 10) {
                if let record, record.episodeIndex > 0 {
                    Button { play(index: record.episodeIndex, resume: true) } label: {
                        Label("继续第 \(record.episodeIndex) 集 \(formatTime(record.position))", systemImage: "play.fill")
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                    Button("从第 1 集") { play(index: 1, resume: false) }
                        .buttonStyle(GlassButtonStyle(size: .large))
                } else {
                    Button { play(index: 1, resume: false) } label: { Label("播放第 1 集", systemImage: "play.fill") }
                        .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                }
            }
            .disabled(episodes == nil)

            if let reviews = details?.reviews, !reviews.isEmpty {
                reviewList(reviews)
            }
        }
    }

    // MARK: Right column

    private var episodePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("选集").font(.system(size: 17, weight: .bold))
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
                            completed: record?.completedEpisode ?? 0) { episode in
                    play(index: episode.index, resume: record?.episodeIndex == episode.index)
                }
                EpisodeLegend(showsAppSource: (episodes.webAccessibleEpisodes ?? episodes.total) < episodes.total)
                    .padding(.top, 4)
            } else {
                LoadStateView(error: error, isLoading: isLoading) { Task { await load(force: true) } }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func reviewList(_ reviews: [Review]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("热评").font(.system(size: 17, weight: .bold))
                if let total = details?.reviewTotal { Text("\(total) 条").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(reviews.prefix(20)) { review in
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
                        Text(review.content)
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .padding(.top, 6)
    }

    private func copyShareText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Site.detailURL(summary.seriesId).absoluteString, forType: .string)
    }

    private func load(force: Bool = false) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let service = model.series
        let seriesId = summary.seriesId
        async let detailsTask = try? service.publicDetails(seriesId: seriesId)
        do {
            episodes = try await service.episodes(seriesId: seriesId, force: force)
        } catch {
            self.error = describe(error)
        }
        details = await detailsTask
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

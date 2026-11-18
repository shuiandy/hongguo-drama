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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                info
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
        .task { await load() }
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
                    ForEach(summary.tags.prefix(3), id: \.self) { GlassTag(text: $0) }
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
                        Button { play(index: record.episodeIndex, resume: true) } label: {
                            Label("继续第 \(record.episodeIndex) 集 \(formatTime(record.position))", systemImage: "play.fill")
                        }
                        .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                        Button("从第 1 集播放") { play(index: 1, resume: false) }
                            .buttonStyle(GlassButtonStyle(size: .large))
                    } else {
                        Button { play(index: 1, resume: false) } label: { Label("播放第 1 集", systemImage: "play.fill") }
                            .buttonStyle(GlassButtonStyle(prominent: true, size: .large))
                    }
                }
                .disabled(episodes == nil)
                .padding(.top, 4)
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
                        Text(review.content)
                            .font(.system(size: 14))
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

import SwiftUI
import HongguoCore

struct SeriesDetailView: View {
    let summary: SeriesSummary
    @Environment(AppModel.self) private var model

    @State private var episodes: SeriesEpisodes?
    @State private var details: PublicDetails?
    @State private var error: String?
    @State private var isLoading = false

    private var record: WatchRecord? { model.history.first { $0.seriesId == summary.seriesId } }
    private var title: String { episodes?.title ?? summary.title }
    private var cover: String { [episodes?.cover, details?.cover, summary.cover].compactMap { $0 }.first { !$0.isEmpty } ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let episodes {
                    episodeGrid(episodes)
                } else {
                    LoadStateView(error: error, isLoading: isLoading) { Task { await load(force: true) } }
                }
                if let reviews = details?.reviews, !reviews.isEmpty {
                    reviewList(reviews)
                }
            }
            .padding(24)
        }
        .navigationTitle(title)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            CoverImage(url: cover, cornerRadius: 10)
                .frame(width: 180, height: 240)
                .shadow(radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 10) {
                    if let label = details?.episodeLabel, !label.isEmpty { Text(label) }
                    if let total = episodes?.total { Text("共 \(total) 集") }
                    if let rating = details?.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.orange)
                    }
                    if let likes = details?.likeCount { Label(formatCount(likes), systemImage: "heart") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if !summary.tags.isEmpty {
                    HStack { ForEach(summary.tags, id: \.self) { Text($0).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule()) } }
                }
                let description = details?.description.isEmpty == false ? details!.description : summary.description
                if !description.isEmpty {
                    Text(description).font(.body).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    if let record, record.episodeIndex > 0 {
                        Button { play(index: record.episodeIndex, resume: true) } label: {
                            Label("继续第 \(record.episodeIndex) 集 \(formatTime(record.position))", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        Button("从第 1 集播放") { play(index: 1, resume: false) }.controlSize(.large)
                    } else {
                        Button { play(index: 1, resume: false) } label: { Label("播放第 1 集", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Button { NSWorkspace.shared.open(Site.detailURL(summary.seriesId)) } label: { Label("官网", systemImage: "safari") }
                        .controlSize(.large)
                }
                .disabled(episodes == nil)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func episodeGrid(_ list: SeriesEpisodes) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选集").font(.title3.weight(.semibold))
                if let open = list.webAccessibleEpisodes, open < list.total {
                    Text("官网公开 \(open) 集，其余集将尝试备用片源").font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 54, maximum: 64), spacing: 8)], spacing: 8) {
                ForEach(list.episodes) { episode in
                    let isCurrent = record?.episodeIndex == episode.index
                    let watched = (record?.completedEpisode ?? 0) >= episode.index
                    Button { play(index: episode.index, resume: isCurrent) } label: {
                        Text("\(episode.index)")
                            .font(.callout.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(isCurrent ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(watched ? 0.08 : 0.15),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(isCurrent ? .white : (watched ? .secondary : .primary))
                    }
                    .buttonStyle(.plain)
                    .help(episode.webAvailable == false ? "官网未公开，将尝试备用片源" : "第 \(episode.index) 集")
                }
            }
        }
    }

    private func reviewList(_ reviews: [Review]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("评论\(details?.reviewTotal.map { "（\($0)）" } ?? "")").font(.title3.weight(.semibold))
            ForEach(reviews.prefix(20)) { review in
                HStack(alignment: .top, spacing: 10) {
                    CoverImage(url: review.avatar, cornerRadius: 14).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(review.author.isEmpty ? "匿名用户" : review.author).font(.caption.weight(.medium))
                            if let likes = review.likes, likes > 0 { Label("\(likes)", systemImage: "hand.thumbsup").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(review.content).font(.callout).textSelection(.enabled)
                    }
                }
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

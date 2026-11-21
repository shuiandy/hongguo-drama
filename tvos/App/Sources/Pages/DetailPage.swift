import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// The series page: the cover on the left, the information and the episodes on the right. The
/// episodes come in the shared ranges (`EpisodeRanges`, 30 a range), twelve to a row. Back (the
/// Menu button) closes it.
struct DetailPage: View {
    @Environment(TVAppModel.self) private var app
    let series: SeriesSummary

    /// The series' episodes, figures, cast, reviews and related series (shared with the iOS page).
    @State private var model: SeriesDetailModel
    @State private var rangeIndex = 0
    @State private var celebrity: EpisodeSocial.CastMember?
    @State private var tint = Color.gray
    @State private var attempt = 0
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case play, range(Int), episode(Int) }

    private static let columns = Array(repeating: GridItem(.fixed(96), spacing: 18), count: 12)

    init(series: SeriesSummary) {
        self.series = series
        _model = State(initialValue: SeriesDetailModel(item: series, isUpcoming: series.episodeLabel == SeriesDetailModel.upcomingLabel))
    }

    var body: some View {
        ZStack {
            AmbientBackground(tint: tint)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 50) {
                    HStack(alignment: .top, spacing: 64) {
                        PosterImage(series: SeriesSummary(seriesId: series.seriesId, title: title, cover: cover))
                            .frame(width: 400, height: 571)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shadow(radius: 24)
                        info
                    }
                    if !cast.isEmpty { castRow }
                    if !model.related.isEmpty {
                        Shelf(title: "相关推荐", items: model.related)
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
            }
            .scrollClipDisabled()
            if let celebrity {
                CelebrityPage(member: celebrity, tint: tint) { self.celebrity = nil }
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .onExitCommand { if celebrity == nil { app.detailTarget = nil } }
        // Over the tabs, nothing hands focus over by itself: start (and come back from the player) on 播放.
        .onAppear { DispatchQueue.main.async { focus = .play } }
        .onChange(of: app.playerTarget == nil) { _, closed in if closed { DispatchQueue.main.async { focus = .play } } }
        .task(id: attempt) { await load() }
        .task { await model.loadExtras(using: app.backend) }
        .task { if let color = await CoverTint.color(for: cover) { tint = color } else { tint = PlaceholderTint.color(for: series.seriesId) } }
    }

    private var title: String { model.social?.title.isEmpty == false ? model.social!.title : series.title }
    private var cover: String { series.cover.isEmpty ? (model.social?.cover ?? "") : series.cover }
    /// As on the iOS page: the episode's public intro, else the card's.
    private var synopsis: String { model.social?.intro.isEmpty == false ? model.social!.intro : series.description }
    /// The reviews' cast when it has one, else the episode page's.
    private var cast: [EpisodeSocial.CastMember] {
        (model.reviews?.cast.isEmpty == false ? model.reviews?.cast : model.social?.cast) ?? []
    }
    private var record: WatchRecord? {
        _ = app.library.libraryRevision
        return app.library.store.record(for: series.seriesId)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title).font(.title.weight(.bold)).lineLimit(2)
            Text(meta).font(.callout).foregroundStyle(.secondary)
            if !synopsis.isEmpty {
                Text(synopsis).font(.callout).lineLimit(3).foregroundStyle(.secondary)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
            actions
            switch model.phase {
            case .loading, .idle:
                LoadStateView(state: .loading).frame(height: 300)
            case .failed(let message):
                LoadStateView(state: .failed(message)) { attempt += 1 }.frame(height: 300)
            case .loaded:
                if model.release == .upcoming {
                    Text("待上线").font(.headline).foregroundStyle(.secondary)
                } else if model.episodes.isEmpty {
                    LoadStateView(state: .empty("还没有分集")).frame(height: 300)
                } else {
                    episodes
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var meta: String {
        let count = max(model.total, model.social?.episodeCount ?? 0, series.episodeCount)
        return ([count > 0 ? "全\(count)集" : "", series.heat] + series.tags.prefix(3))
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 28) {
            Button {
                if let record, record.episodeIndex > 0 {
                    app.openPlayer(summary, startEpisode: nil)
                } else {
                    app.openPlayer(summary, startEpisode: 1)
                }
            } label: {
                if let record, record.episodeIndex > 0 {
                    Label("继续看第\(record.episodeIndex)集", systemImage: "play.fill")
                } else {
                    Label("播放第1集", systemImage: "play.fill")
                }
            }
            .focused($focus, equals: .play)
            let favorite = app.library.isFavorite(series.seriesId)
            Button {
                app.library.toggleFavorite(seriesId: series.seriesId, title: title, cover: cover)
            } label: {
                Label(favorite ? "已收藏" : "收藏", systemImage: favorite ? "heart.fill" : "heart")
            }
        }
        .focusSection()
    }

    private var summary: SeriesSummary {
        SeriesSummary(seriesId: series.seriesId, title: title, cover: cover, episodeCount: max(model.total, series.episodeCount))
    }

    private var episodes: some View {
        let ranges = EpisodeRanges.ranges(total: model.total)
        let range = ranges.isEmpty ? 1...max(1, model.total) : ranges[min(rangeIndex, ranges.count - 1)]
        return VStack(alignment: .leading, spacing: 20) {
            if ranges.count > 1 {
                HStack(spacing: 16) {
                    ForEach(Array(ranges.enumerated()), id: \.offset) { index, item in
                        Button(EpisodeRanges.label(item)) { rangeIndex = index }
                            .font(.callout.weight(index == rangeIndex ? .bold : .regular))
                            .focused($focus, equals: .range(index))
                    }
                }
                .focusSection()
            }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
                ForEach(model.episodes.filter { range.contains($0.index) }) { episode in
                    EpisodeCell(number: episode.index, isCurrent: record?.episodeIndex == episode.index,
                                isDisabled: episode.disabled) {
                        app.openPlayer(summary, startEpisode: episode.index)
                    }
                    .focused($focus, equals: .episode(episode.index))
                }
            }
            .focusSection()
        }
    }

    private func load() async {
        await model.load(using: app.backend)
        if let current = record?.episodeIndex, current > 0, model.total > 0 {
            rangeIndex = EpisodeRanges.index(of: current, total: model.total)
        }
    }

    /// 演员: round pictures with name and role; one opens the actor's page.
    private var castRow: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("演员").font(.title3.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 40) {
                    ForEach(cast) { member in
                        Button { celebrity = member } label: {
                            VStack(spacing: 12) {
                                AsyncImage(url: URL(string: member.avatar)) { $0.resizable().scaledToFill() } placeholder: {
                                    Image(systemName: "person.fill").font(.system(size: 50)).foregroundStyle(.secondary)
                                }
                                .frame(width: 140, height: 140)
                                .background(Color.gray.opacity(0.3))
                                .clipShape(Circle())
                                Text(member.name).font(.callout).lineLimit(1)
                                Text(member.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 180)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// One episode in the grid: its number; the one last watched is marked.
struct EpisodeCell: View {
    let number: Int
    var isCurrent = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 96, height: 64)
                .foregroundStyle(isCurrent ? Theme.accent : .primary)
        }
        .buttonStyle(.card)
        .disabled(isDisabled)
        .overlay(alignment: .topTrailing) {
            if isCurrent {
                Image(systemName: "play.fill").font(.caption2).foregroundStyle(Theme.accent).padding(6)
            }
        }
    }
}

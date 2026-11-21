import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 推荐: the shared FeedModel (the official recommend feed live, the sample rows offline; the same
/// prefetch, history, exposure and 不感兴趣 rules as the iOS feed) in three columns: the series on
/// the left, the clip in the middle (9:16, full height), the next one on the right. The one button,
/// 观看完整剧集, holds the focus: up and down on the remote change the clip (up goes back to the
/// tab bar while it shows), pressing it opens the whole series and carries on in place. The tab bar
/// fades while a clip plays. The app opens here and starts playing (silent with -HongguoMuted).
struct RecommendPage: View {
    @Environment(TVAppModel.self) private var app
    @State private var feed: FeedModel?

    var body: some View {
        Group {
            if let feed {
                RecommendContent(feed: feed)
            } else {
                Color.black
            }
        }
        .onAppear { if feed == nil { feed = FeedModel(app: app) } }
    }
}

private struct RecommendContent: View {
    @Environment(TVAppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var feed: FeedModel
    @State private var tabBarShown = true
    @State private var tint = Color.gray
    @State private var hideToken = 0
    @FocusState private var mainFocused: Bool

    private var visible: Bool {
        app.selectedTab == .recommend && app.playerTarget == nil && app.detailTarget == nil && !app.showsAccountPicker
            && !app.showsLogin && scenePhase == .active
    }

    var body: some View {
        GeometryReader { proxy in
            let videoWidth = proxy.size.height * 9 / 16
            ZStack {
                AmbientBackground(tint: tint)
                switch feed.phase {
                case .failed(let message) where feed.items.isEmpty:
                    LoadStateView(state: .failed(message)) { Task { await feed.load(force: true) } }
                case .loaded where feed.items.isEmpty:
                    LoadStateView(state: .empty("暂时没有推荐"))
                default:
                    HStack(spacing: 60) {
                        info
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ZStack {
                            Color.black
                            VideoSurface(engine: feed.engine)
                            status
                        }
                        .frame(width: videoWidth, height: proxy.size.height)
                        next
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 80)
                }
            }
        }
        .ignoresSafeArea()
        .toolbar(tabBarShown ? .visible : .hidden, for: .tabBar)
        .animation(.easeInOut(duration: 0.4), value: tabBarShown)
        .task(id: feed.tab) { await feed.load() }
        .onAppear { feed.setVisible(visible) }
        .onDisappear { feed.setVisible(false) }
        .onChange(of: visible) { _, now in
            feed.setVisible(now)
            if now { takeFocus() }
        }
        .onChange(of: feed.currentID) { _, id in
            feed.pageChanged(to: id)
            followCover()
        }
        .onChange(of: feed.engine.isPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing && visible
            if playing { hideToken += 1 } else { tabBarShown = true }
        }
        .task(id: hideToken) {
            // The tab bar fades a few seconds into a clip, unless the focus is on it.
            guard hideToken > 0 else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, feed.engine.isPlaying, mainFocused else { return }
            tabBarShown = false
        }
    }

    // MARK: Columns

    @ViewBuilder private var info: some View {
        if let item = feed.currentItem {
            let total = feed.resolved[item.seriesId]?.total ?? item.episodeCount
            VStack(alignment: .leading, spacing: 22) {
                Text(item.title).font(.title2.weight(.bold)).lineLimit(2)
                Text(([total > 0 ? "全\(total)集" : "", item.heat] + item.tags.prefix(2)).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                let synopsis = feed.synopses[item.seriesId] ?? item.description
                if !synopsis.isEmpty {
                    Text(synopsis).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                }
                Text("第\(feed.episodeNumber(of: item.seriesId))集").font(.callout.weight(.semibold))
                Button { feed.watchFullSeries(item) } label: {
                    Label(total > 0 ? "观看完整剧集 · 全\(total)集" : "观看完整剧集", systemImage: "play.rectangle.on.rectangle")
                }
                .focused($mainFocused)
                // The one button takes the focus from the tab bar as soon as it is there.
                .onAppear(perform: takeFocus)
                .onMoveCommand(perform: move)
                .onPlayPauseCommand { feed.engine.togglePlay() }
                // Back brings the tab bar in while it is hidden; when it shows, Back is the system's.
                .onExitCommand(perform: tabBarShown ? nil : { tabBarShown = true })
                Text("上下切换短剧").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 560, alignment: .leading)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private var next: some View {
        if let current = feed.currentID, let index = feed.items.firstIndex(where: { $0.seriesId == current }),
           let upcoming = feed.items[safe: index + 1] {
            VStack(alignment: .leading, spacing: 16) {
                Text("下一部").font(.headline).foregroundStyle(.secondary)
                PosterImage(series: upcoming)
                    .frame(width: 200, height: 286)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .opacity(0.85)
                Text(upcoming.title).font(.callout).lineLimit(2).frame(width: 200, alignment: .leading)
                Label("按下方向键", systemImage: "chevron.down").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch feed.engine.phase {
        case .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            VStack(spacing: 16) {
                Text(message).font(.headline)
                Button("重试") { feed.retryCurrentCard() }
            }
        case .unsupported:
            Text("此剧集暂不支持").font(.headline)
        case .offline:
            Label("离线示例，没有视频画面", systemImage: "wifi.slash").font(.callout).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: Remote

    private func move(_ direction: MoveCommandDirection) {
        guard let current = feed.currentID, let index = feed.items.firstIndex(where: { $0.seriesId == current }) else { return }
        switch direction {
        case .down:
            if let upcoming = feed.items[safe: index + 1] { feed.currentID = upcoming.seriesId }
        case .up:
            // While the tab bar shows, up is the focus engine's way back to it.
            guard !tabBarShown, index > 0 else { return }
            feed.currentID = feed.items[index - 1].seriesId
        default:
            break
        }
    }

    /// Asks for the focus a few times: right after launch the tab bar can still be taking it.
    private func takeFocus() {
        Task { @MainActor in
            for _ in 0..<10 where !mainFocused {
                try? await Task.sleep(for: .milliseconds(300))
                guard visible else { return }
                mainFocused = true
            }
        }
    }

    private func followCover() {
        guard let item = feed.currentItem else { return }
        Task {
            if let color = await CoverTint.color(for: item.cover) { tint = color }
            else { tint = PlaceholderTint.color(for: item.seriesId) }
        }
    }
}

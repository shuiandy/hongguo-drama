import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 推荐: the shared FeedModel (the official recommend feed live, the sample rows offline; the same
/// prefetch, history, exposure and 不感兴趣 rules as the iOS feed) in three columns: the series on
/// the left, the clip in the middle (9:16, full height), the next one on the right. The one button,
/// 观看完整剧集, holds the focus: down is the next clip and up the one before, whether or not the
/// tab bar shows, one clip per swipe; only on the first clip does up go to the tab bar. Back brings
/// the tab bar in and moves the focus there. Pressing the button opens the whole series and carries
/// on in place. The tab bar shows on the first clip (so up reaches it); past it, it shows only after
/// Back (the system moves the focus up there), so the focus engine cannot take up there. The app
/// opens here and starts playing (silent with -HongguoMuted).
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
        // Made once the account is chosen, so the opening request is the chosen account's.
        .onAppear { makeFeedIfReady() }
        .onChange(of: app.showsAccountPicker) { _, _ in makeFeedIfReady() }
        .onChange(of: app.awaitingLaunchRoute) { _, _ in makeFeedIfReady() }
        .onChange(of: app.playerTarget?.id) { _, _ in makeFeedIfReady() }
        .onChange(of: app.detailTarget?.seriesId) { _, _ in makeFeedIfReady() }
    }

    private func makeFeedIfReady() {
        if feed == nil, !app.showsAccountPicker, !app.awaitingLaunchRoute, app.playerTarget == nil, app.detailTarget == nil {
            feed = FeedModel(app: app)
        }
    }
}

private struct RecommendContent: View {
    @Environment(TVAppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var feed: FeedModel
    @State private var tint = Color.gray
    @FocusState private var mainFocused: Bool
    /// Back took the focus up to the tab bar (the system does that itself); until it comes down.
    @State private var tabBarSummoned = false
    /// When the clip last changed: one swipe on the clickpad changes one clip.
    @State private var lastMove = Date.distantPast
    static let moveGate: TimeInterval = 0.4

    private var currentIndex: Int? {
        feed.currentID.flatMap { id in feed.items.firstIndex { $0.seriesId == id } }
    }

    /// The tab bar is on screen (and so reachable by up) on the first clip, and anywhere while
    /// the focus is up there after Back.
    private var tabBarVisible: Bool {
        tabBarSummoned || (currentIndex ?? 0) == 0
    }

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
                            // Rebuilt for each engine, as on iOS: the feed hands the clip to another
                            // engine on most swipes, and a view kept from the last one shows its
                            // frozen last frame while the new one plays.
                            VideoSurface(engine: feed.engine)
                                .id(ObjectIdentifier(feed.engine))
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
        .toolbar(tabBarVisible ? .visible : .hidden, for: .tabBar)
        .animation(.easeInOut(duration: 0.4), value: tabBarVisible)
        // Back moves the focus to the tab bar even while it is hidden: show it then. When the focus
        // comes back down, past the first clip it goes away again.
        .onChange(of: mainFocused) { _, focused in
            if focused { tabBarSummoned = false } else if visible { tabBarSummoned = true }
        }
        .task(id: feed.tab) { await feed.load() }
        .onAppear { feed.setVisible(visible) }
        .onDisappear { feed.setVisible(false) }
        // Another account (switched, signed in or out): the feed starts over for it, as on iOS.
        .onChange(of: app.account.profile?.id) { oldId, newId in
            Task { await feed.accountDidChange(from: oldId, to: newId) }
        }
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
                // Back is the system's: it moves the focus to the tab bar (shown then, above).
                .onExitCommand(perform: nil)
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
        guard let index = currentIndex else { return }
        let now = Date()
        switch direction {
        case .down:
            guard let upcoming = feed.items[safe: index + 1] else { return }
            guard now.timeIntervalSince(lastMove) >= Self.moveGate else { return note("down ignored") }
            lastMove = now
            note("down to=\(index + 1)")
            feed.currentID = upcoming.seriesId
        case .up:
            // The first clip: up is the focus engine's, to the tab bar (shown on the first clip).
            if index == 0 { return }
            guard now.timeIntervalSince(lastMove) >= Self.moveGate else { return note("up ignored") }
            lastMove = now
            note("up to=\(index - 1)")
            feed.currentID = feed.items[index - 1].seriesId
        default:
            break
        }
    }

    /// Each remote move with the time to the millisecond, so a device log shows whether one swipe
    /// arrives as more than one move.
    private func note(_ text: String) {
        let ms = Int(Date().timeIntervalSince1970 * 1000) % 100_000
        PlaybackLog.note("feed move \(text) ms=\(ms)")
    }

    /// Asks for the focus a few times: right after launch the tab bar can still be taking it.
    private func takeFocus() {
        Task { @MainActor in
            for _ in 0..<10 where !mainFocused {
                try? await Task.sleep(for: .milliseconds(300))
                // Not while the tab bar was asked for: the focus is meant to be up there.
                guard visible, !tabBarSummoned else { return }
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


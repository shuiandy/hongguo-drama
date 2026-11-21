import AVFoundation
import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

@main
struct HongguoDramaTVApp: App {
    @State private var app: TVAppModel

    init() {
        // First, before anything creates a store: Apple TV keeps no persistent local storage, so
        // the files go to Caches (the system may purge it) and the small state is mirrored into
        // UserDefaults. Sample runs never write the mirror.
        let launch = LaunchOptions.current
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        StorageRoot.configure(base: caches, mirror: launch.offlineFixtures ? nil : .standard)
        // The playback log and metrics go next to the other files (no writable Documents here).
        PlaybackLog.directory = caches
        // Created here, after the root is set: a `@State` default value would run before `init`.
        _app = State(initialValue: TVAppModel(launch: launch))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
        }
    }
}

/// Navigation only. The data, the account, what the viewer keeps and the player are the shared
/// models from HongguoKit, the same ones the iOS app holds. The player has no hooks here: no
/// downloads, no ByteVC2 conversion, no casting, no little window.
@MainActor
@Observable
final class TVAppModel: PlayerHost {
    let launch: LaunchOptions
    let backend: any DramaBackend
    let account: AccountModel
    let library: LibraryModel
    var player = PlayerEngine()
    var playerHandoff: PlayerHandoff?
    var selectedTab: LaunchOptions.Route
    /// The series page, over the tabs.
    var detailTarget: SeriesSummary?
    /// The player page, over everything.
    var playerTarget: PlayerTarget?

    init(launch: LaunchOptions) {
        self.launch = launch
        backend = launch.offlineFixtures ? FixtureBackend() : LiveBackend()
        account = AccountModel(mode: launch.arguments.accountMode)
        library = LibraryModel(offline: launch.offlineFixtures, account: account, backend: backend)
        selectedTab = launch.route
        player.isMuted = launch.muted
        // A muted run (automated tests on a Mac) must not claim the audio output at all.
        if !launch.muted { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback) }
        // `-HongguoRoute detail|player…` opens a series straight away: the one `-HongguoSeries`
        // names; otherwise the first sample series offline, or the first of the hot ranking.
        let routesToSeries = [.detail, .player, .playerControls, .playerEpisodes].contains(launch.route)
        if routesToSeries, !launch.arguments.seriesId.isEmpty {
            open(route: launch.route, SeriesSummary(seriesId: launch.arguments.seriesId, title: ""))
        } else if routesToSeries, launch.offlineFixtures {
            open(route: launch.route, FixtureBackend.summary(1))
        } else if routesToSeries {
            Task { [weak self] in
                guard let self, let first = try? await self.backend.catalog(kind: .hotDrama, genre: nil, page: 1).items.first else { return }
                self.open(route: launch.route, first)
            }
        }
        library.startLive { [weak self] in self?.player.hasFirstFrame ?? true }
    }

    private func open(route: LaunchOptions.Route, _ series: SeriesSummary) {
        if route == .detail { openDetail(series) } else { openPlayer(series) }
    }

    func openDetail(_ series: SeriesSummary) {
        detailTarget = series
    }

    func openPlayer(_ summary: SeriesSummary, startEpisode: Int? = nil, startAt: Double = 0,
                    continuesCurrentClip: Bool = false, resumeIfAheadOfCurrentClip: Bool = false) {
        playerTarget = PlayerTarget(seriesId: summary.seriesId, title: summary.title, cover: summary.cover,
                                    startEpisode: startEpisode, startAt: startAt,
                                    continuesCurrentClip: continuesCurrentClip,
                                    resumeIfAheadOfCurrentClip: resumeIfAheadOfCurrentClip)
    }

    func closePlayer() { playerTarget = nil }
}

/// The shell: the system's top tab bar, nothing drawn by hand. The series page and the player
/// sit over it in place; while one is up the tabs take no focus.
struct RootView: View {
    @Environment(TVAppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            TabView(selection: $app.selectedTab) {
                Tab("推荐", systemImage: "play.rectangle", value: LaunchOptions.Route.recommend) {
                    RecommendPage()
                }
                Tab("剧场", systemImage: "film.stack", value: LaunchOptions.Route.theater) {
                    TheaterPage()
                }
                Tab("排行", systemImage: "chart.bar", value: LaunchOptions.Route.ranking) {
                    RankingPage()
                }
                Tab("追剧", systemImage: "heart", value: LaunchOptions.Route.following) {
                    FollowingPage()
                }
                Tab("搜索", systemImage: "magnifyingglass", value: LaunchOptions.Route.search) {
                    SearchPage()
                }
                Tab("我的", systemImage: "person", value: LaunchOptions.Route.me) {
                    MePage()
                }
            }
            .disabled(app.detailTarget != nil || app.playerTarget != nil)

            if let series = app.detailTarget {
                DetailPage(series: series)
                    .id(series.seriesId)
                    .disabled(app.playerTarget != nil)
                    .transition(.opacity)
            }
            if let target = app.playerTarget {
                TVPlayerPage(target: target, app: app)
                    .id(target.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.detailTarget?.seriesId)
        .animation(.easeInOut(duration: 0.25), value: app.playerTarget?.id)
    }
}

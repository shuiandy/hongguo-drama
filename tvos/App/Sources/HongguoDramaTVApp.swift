import AVFoundation
import HongguoCore
import HongguoModels
import HongguoPlayback
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
        // Page models (shared with the iOS app) prefetch covers through the shared cover cache.
        CoverPrefetch.handler = { CoverImageCache.shared.prefetch($0) }
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
    /// The accounts signed in on this Apple TV.
    let roster: AccountRoster
    var player = PlayerEngine()
    var playerHandoff: PlayerHandoff?
    var selectedTab: LaunchOptions.Route
    /// The series page, over the tabs.
    var detailTarget: SeriesSummary?
    /// The player page, over everything.
    var playerTarget: PlayerTarget?
    /// 扫码登录, over the tabs.
    var showsLogin = false
    /// 选择账号, over everything; shown at launch when accounts are saved on this Apple TV.
    var showsAccountPicker = false
    /// A series page or player launch route still being opened (live: after the hot ranking
    /// arrives); the feed waits, so it does not start a clip under it.
    var awaitingLaunchRoute = false

    init(launch: LaunchOptions) {
        self.launch = launch
        backend = launch.offlineFixtures ? FixtureBackend() : LiveBackend()
        account = AccountModel(mode: launch.arguments.accountMode)
        library = LibraryModel(offline: launch.offlineFixtures, account: account, backend: backend)
        // Live: the saved accounts (an earlier single login becomes the first). Sample runs: an
        // empty roster in memory, or made-up accounts with `-HongguoRoute accounts`.
        if launch.offlineFixtures {
            roster = launch.route == .accounts ? AccountRoster.samples()
                : AccountRoster(defaults: UserDefaults(suiteName: "HongguoDrama.sampleRoster.\(UUID().uuidString)") ?? .standard,
                                vault: MemoryVault(), current: MemoryVault.Current())
        } else {
            roster = AccountRoster()
            roster.migrateIfNeeded()
        }
        // Accounts saved: choose one first; none: straight to 推荐.
        showsAccountPicker = launch.route == .accounts || (!roster.entries.isEmpty && launch.route == .recommend)
        // The series page and player routes open over 推荐.
        selectedTab = [.detail, .player, .playerControls, .playerEpisodes, .accounts].contains(launch.route) ? .recommend
            : [.newReleases, .calendar].contains(launch.route) ? .theater : launch.route
        showsLogin = launch.arguments.showsLogin
        player.isMuted = launch.muted
        // A muted run (automated tests on a Mac) must not claim the audio output at all.
        if !launch.muted { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback) }
        // `-HongguoRoute detail|player…` opens a series straight away: the one `-HongguoSeries`
        // names; otherwise the first sample series offline, or the first of the hot ranking.
        let routesToSeries = [.detail, .player, .playerControls, .playerEpisodes].contains(launch.route)
        if routesToSeries, !launch.arguments.seriesId.isEmpty {
            open(route: launch.route, SeriesSummary(seriesId: launch.arguments.seriesId, title: ""))
        } else if routesToSeries, launch.offlineFixtures {
            open(route: launch.route, FixtureBackend.summary(1), startEpisode: 1)
        } else if routesToSeries {
            awaitingLaunchRoute = true
            Task { [weak self] in
                defer { self?.awaitingLaunchRoute = false }
                guard let self, let first = try? await self.backend.catalog(kind: .hotDrama, genre: nil, page: 1).items.first else { return }
                self.open(route: launch.route, first, startEpisode: 1)
            }
        }
        // 弹幕 starts off on a TV: the first time this device runs, its own setting is turned off
        // (afterwards it is whatever the viewer chose). Sample runs start off every time.
        if launch.offlineFixtures {
            library.settings.danmaku.enabled = false
        } else if !UserDefaults.standard.bool(forKey: "tvDanmakuDefaulted") {
            library.settings.danmaku.enabled = false
            UserDefaults.standard.set(true, forKey: "tvDanmakuDefaulted")
        }
        library.startLive { [weak self] in self?.player.hasFirstFrame ?? true }
    }

    private func open(route: LaunchOptions.Route, _ series: SeriesSummary, startEpisode: Int? = nil) {
        if route == .detail { openDetail(series) } else { openPlayer(series, startEpisode: startEpisode) }
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

    /// An account was chosen (or 不登录使用): on to 推荐, which starts playing.
    func finishAccountChoice() {
        showsAccountPicker = false
        selectedTab = .recommend
    }

    /// After a QR sign-in: the account joins the roster as the current one.
    func signedIn() {
        roster.rememberCurrent(avatar: account.avatar)
        showsLogin = false
        if showsAccountPicker { finishAccountChoice() }
    }
}

/// The shell: the system's top tab bar, nothing drawn by hand. The series page and the player
/// sit over it in place; while one is up the tabs take no focus.
struct RootView: View {
    @Environment(TVAppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasActivatedOnce = false

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
            .disabled(app.detailTarget != nil || app.playerTarget != nil || app.showsLogin || app.showsAccountPicker)


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
            if app.showsAccountPicker {
                AccountPickerPage()
                    .disabled(app.showsLogin)
                    .transition(.opacity)
            }
            if app.showsLogin {
                LoginPage()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.detailTarget?.seriesId)
        .animation(.easeInOut(duration: 0.25), value: app.playerTarget?.id)
        .animation(.easeInOut(duration: 0.25), value: app.showsAccountPicker)
        .onChange(of: app.account.profile?.id) { oldId, newId in
            // The server no longer accepts a saved login: it leaves the list too.
            if let oldId, newId == nil, app.account.message.contains("过期"),
               let entry = app.roster.entries.first(where: { $0.id == oldId }) {
                Task { await app.roster.remove(entry, account: app.account) }
            }
        }
        .onChange(of: app.account.avatar) { _, avatar in
            // The picture and name arrive after a sign-in or switch: keep the roster's entry current.
            if let profile = app.account.profile { app.roster.update(id: profile.id, nickname: profile.nickname, avatar: avatar) }
        }
        .onChange(of: scenePhase) { _, phase in
            // As in the iOS app: back in front, warm the App source up and sync the account (at
            // most once a minute, then every 3 minutes); in the background, stop the loop.
            if phase == .active {
                if hasActivatedOnce {
                    if !app.launch.offlineFixtures {
                        Task { await EpisodeResolver.shared.warmUpAppSource() }
                    }
                    app.library.sceneBecameActive()
                }
                hasActivatedOnce = true
            } else if phase == .background {
                app.library.sceneEnteredBackground()
            }
        }
    }
}

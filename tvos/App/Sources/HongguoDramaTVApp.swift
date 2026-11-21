import HongguoCore
import HongguoModels
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
        // Created here, after the root is set: a `@State` default value would run before `init`.
        _app = State(initialValue: TVAppModel(launch: launch))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(.accentColor)
                .preferredColorScheme(.dark)
        }
    }
}

/// Navigation only. The data, the account and what the viewer keeps are the shared models from
/// HongguoKit, the same ones the iOS app holds.
@MainActor
@Observable
final class TVAppModel {
    let launch: LaunchOptions
    let backend: any DramaBackend
    let account: AccountModel
    let library: LibraryModel
    var selectedTab: LaunchOptions.Route

    init(launch: LaunchOptions) {
        self.launch = launch
        backend = launch.offlineFixtures ? FixtureBackend() : LiveBackend()
        account = AccountModel(mode: launch.arguments.accountMode)
        library = LibraryModel(offline: launch.offlineFixtures, account: account, backend: backend)
        selectedTab = launch.route
        // No player yet: nothing to wait for before warming up and restoring the saved login.
        library.startLive { true }
    }
}

/// The shell: the system's top tab bar, nothing drawn by hand.
struct RootView: View {
    @Environment(TVAppModel.self) private var app

    var body: some View {
        @Bindable var app = app
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
    }
}

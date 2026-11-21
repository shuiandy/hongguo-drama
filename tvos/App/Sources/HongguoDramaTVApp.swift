import HongguoCore
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

@MainActor
@Observable
final class TVAppModel {
    let launch: LaunchOptions
    var selectedTab: LaunchOptions.Route

    init(launch: LaunchOptions) {
        self.launch = launch
        selectedTab = launch.route
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

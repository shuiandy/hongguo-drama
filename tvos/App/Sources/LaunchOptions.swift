import Foundation

/// Switches read once at launch, the same names the iOS app uses, so the app can be driven from
/// `simctl launch` without the remote:
///
///     xcrun simctl launch <udid> io.github.shuiandy.hongguo-drama.tvos \
///         -HongguoOfflineFixtures YES -HongguoMuted YES -HongguoRoute theater
struct LaunchOptions: Sendable {
    /// The six top tabs; `-HongguoRoute` opens one of them.
    enum Route: String, Sendable, CaseIterable {
        case recommend, theater, ranking, following, search, me
    }

    /// Built-in sample rows instead of the network.
    var offlineFixtures: Bool
    /// Silence playback (automated runs on a Mac with speakers).
    var muted: Bool
    var route: Route

    static var current: LaunchOptions {
        let defaults = UserDefaults.standard
        return LaunchOptions(
            offlineFixtures: defaults.bool(forKey: "HongguoOfflineFixtures")
                || ProcessInfo.processInfo.environment["HONGGUO_OFFLINE"] == "1",
            muted: defaults.bool(forKey: "HongguoMuted"),
            route: defaults.string(forKey: "HongguoRoute").flatMap(Route.init(rawValue:)) ?? .recommend
        )
    }
}

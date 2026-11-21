import Foundation
import HongguoModels

/// The common launch switches (`LaunchArguments`, the same names as the iOS app) mapped to this
/// app's tabs, so the app can be driven from `simctl launch` without the remote:
///
///     xcrun simctl launch <udid> io.github.shuiandy.hongguo-drama.tvos \
///         -HongguoOfflineFixtures YES -HongguoMuted YES -HongguoRoute theater
struct LaunchOptions: Sendable {
    /// The six top tabs, and the series page and player for screenshots (`-HongguoSeries` picks
    /// the series; offline the sample series).
    enum Route: String, Sendable, CaseIterable {
        case recommend, theater, ranking, following, search, me
        case detail, player
        case playerControls = "player-controls", playerEpisodes = "player-episodes"
    }

    var arguments: LaunchArguments
    var route: Route

    var offlineFixtures: Bool { arguments.offlineFixtures }
    var muted: Bool { arguments.muted }

    static var current: LaunchOptions {
        let arguments = LaunchArguments.current
        return LaunchOptions(arguments: arguments, route: Route(rawValue: arguments.route) ?? .recommend)
    }
}

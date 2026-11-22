import Foundation

/// The launch switches every app reads the same way, so each can be driven from `simctl launch`
/// without touching the screen (`-HongguoOfflineFixtures YES -HongguoMuted YES -HongguoRoute …`).
/// Each app maps `route` to its own screens and adds switches of its own.
public struct LaunchArguments: Sendable, Equatable {
    /// Built-in sample rows instead of the network.
    public var offlineFixtures: Bool
    /// Silence playback (automated runs on a Mac with speakers).
    public var muted: Bool
    /// `-HongguoRoute`: the screen to open, as the app names it; empty when not given.
    public var route: String
    /// `-HongguoSeries`: series to open for the player routes. Empty: the app picks one.
    public var seriesId: String
    /// Show 我的 as if signed in, with a made-up account and no request (sample runs only).
    public var accountPreview: Bool
    /// Open the sign-in page at launch.
    public var showsLogin: Bool
    /// Ask each read-only account endpoint once and write the shape of the replies.
    public var accountProbe: Bool
    /// With `accountPreview`: show the made-up account as if its last sync failed (sample runs
    /// only; nothing is requested), to look at and test the failure text and 重试.
    public var syncFailurePreview: Bool

    public init(offlineFixtures: Bool = false, muted: Bool = false, route: String = "", seriesId: String = "",
                accountPreview: Bool = false, showsLogin: Bool = false, accountProbe: Bool = false,
                syncFailurePreview: Bool = false) {
        self.offlineFixtures = offlineFixtures
        self.muted = muted
        self.route = route
        self.seriesId = seriesId
        self.accountPreview = accountPreview
        self.showsLogin = showsLogin
        self.accountProbe = accountProbe
        self.syncFailurePreview = syncFailurePreview
    }

    public init(defaults: UserDefaults, environment: [String: String]) {
        self.init(
            offlineFixtures: defaults.bool(forKey: "HongguoOfflineFixtures") || environment["HONGGUO_OFFLINE"] == "1",
            muted: defaults.bool(forKey: "HongguoMuted"),
            route: defaults.string(forKey: "HongguoRoute") ?? "",
            seriesId: defaults.string(forKey: "HongguoSeries") ?? "",
            accountPreview: defaults.bool(forKey: "HongguoAccountPreview"),
            showsLogin: defaults.bool(forKey: "HongguoShowLogin"),
            accountProbe: defaults.bool(forKey: "HongguoAccountProbe"),
            syncFailurePreview: defaults.bool(forKey: "HongguoSyncFailurePreview")
        )
    }

    /// What this process was launched with.
    public static var current: LaunchArguments {
        LaunchArguments(defaults: .standard, environment: ProcessInfo.processInfo.environment)
    }

    /// The account mode these switches ask for: sample runs never touch the real account.
    public var accountMode: AccountModel.Mode {
        offlineFixtures ? (accountPreview ? .preview : .offline) : .live
    }
}

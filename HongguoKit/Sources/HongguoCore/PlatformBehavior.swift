import Foundation

/// The places where the Mac and iOS apps still behave differently on purpose. HongguoKit's first
/// migration shares the code without changing what either app does; each app sets `current` once
/// at launch, before the first request, and the default keeps the Mac app's behavior. The source
/// order is unified later, from comparison data (HongguoKit/README.md).
public struct PlatformBehavior: Sendable, Equatable {
    /// The client the App play requests imitate when a caller does not say.
    public var clientProfile: AppClientProfile
    /// How `URLGuard` checks hosts whose DNS answer is a local proxy's virtual address.
    public var proxyPolicy: URLGuard.ProxyPolicy
    /// Discovery, catalogue, book mall, account and social requests use the registered playback
    /// device (`PersistentAppDevice`: Keychain, renewed every 6 hours, `x-tt-dt` header) instead of
    /// the fixed metadata device.
    public var persistentDataDevice: Bool
    /// `SeriesService.playInfo` tries the website's fallback channel (360p H.264) right after the
    /// fast App source.
    public var websiteFallbackChannel: Bool
    /// `SeriesService` asks `AuthenticatedPlaybackSource` (the iOS app's source: official iOS 7.4.3
    /// profile, persistent device with its token, model disk cache) first, for lookups, warm-up and
    /// prefetch, and keeps its own order after it. Off for the iOS app, whose `EpisodeResolver`
    /// already asks that source first and uses `SeriesService` only as the fallback.
    public var authenticatedSourceFirst: Bool

    public init(clientProfile: AppClientProfile, proxyPolicy: URLGuard.ProxyPolicy,
                persistentDataDevice: Bool, websiteFallbackChannel: Bool, authenticatedSourceFirst: Bool = false) {
        self.clientProfile = clientProfile
        self.proxyPolicy = proxyPolicy
        self.persistentDataDevice = persistentDataDevice
        self.websiteFallbackChannel = websiteFallbackChannel
        self.authenticatedSourceFirst = authenticatedSourceFirst
    }

    /// The Mac app (the default). Since 2026-11-20 it asks the iOS app's source first: the Mac's own
    /// order fell back to the 360p website channel after empty replies, about 13 s to the first frame.
    public static let mac = PlatformBehavior(clientProfile: .android, proxyPolicy: .strict,
                                             persistentDataDevice: false, websiteFallbackChannel: true,
                                             authenticatedSourceFirst: true)
    /// The iOS app as of iOS HEAD 382e2c2 (2026-11-20). The tvOS app starts from this too.
    public static let iOS = PlatformBehavior(clientProfile: .ios, proxyPolicy: .mobileProxy,
                                             persistentDataDevice: true, websiteFallbackChannel: false)

    private static let storage = LockedValue(PlatformBehavior.mac)

    /// The behavior of this process.
    public static var current: PlatformBehavior {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// The device identity behind data-access requests (`PlatformBehavior.persistentDataDevice`).
enum DataDevice {
    static var persistent: Bool { PlatformBehavior.current.persistentDataDevice }

    /// Requests signed with a registered identity (discovery, account): the persistent device and
    /// its token when on, otherwise the search identity with no token.
    static func registered(transport: AppTransport) async throws -> (identity: PlaybackIdentity, dToken: String) {
        guard persistent else {
            let identity = try await AppSearchIdentity.shared.get(transport: transport)
            return (identity, "")
        }
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let token = await PersistentAppDevice.shared.dTokenValue()
        return (identity, token)
    }

    /// Requests that otherwise use a fixed device (catalogue, book mall, comments): the persistent
    /// device and its token when on and reachable; nil and "" keep the fixed device.
    static func optional(transport: AppTransport) async -> (identity: PlaybackIdentity?, dToken: String) {
        guard persistent else { return (nil, "") }
        let identity = try? await PersistentAppDevice.shared.get(transport: transport)
        let token = await PersistentAppDevice.shared.dTokenValue()
        return (identity, token)
    }

    /// `PersistentAppDevice.authHeaders()` when on.
    static var authHeaders: [(String, String)] { persistent ? PersistentAppDevice.authHeaders() : [] }
}

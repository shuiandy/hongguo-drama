import AppLogic
import Foundation
import HongguoCore
import HongguoPlayback
import Observation

/// What the viewer keeps: history, favourites, likes, reservations, 不感兴趣, the feed's recent
/// exposures and where each episode was left, on this device and, when signed in, on the
/// account. Moved unchanged from the iOS app's `AppModel`: local writes first, the account write
/// queued per record and put back only when it fails and the local value is still the failed
/// target; cloud history merged into the device's store and isolated per account; a sync once a
/// minute at most and every 3 minutes while the app is in front.
@MainActor
@Observable
public final class LibraryModel {
    public let backend: any DramaBackend
    public let account: AccountModel
    @ObservationIgnored public let store: LibraryStore
    @ObservationIgnored public let seriesLibrary: SeriesLibrary
    /// Sample runs: nothing is read from or written to the real files, the account or the network.
    public let offline: Bool
    @ObservationIgnored private let defaults: UserDefaults

    /// Where each episode was left (see `EpisodePositionBook`), written to a file of the app's own.
    @ObservationIgnored public private(set) var episodePositions = EpisodePositionBook()
    @ObservationIgnored private var episodePositionsFile: URL?
    /// Local reservations saved on this device (read-only account reservations are merged in 我的).
    public struct LocalReservation: Codable, Identifiable, Equatable, Sendable {
        public var seriesId: String
        public var title: String
        public var cover: String
        public var releaseText: String
        public var reservedAt: Date
        public var id: String { seriesId }

        public init(seriesId: String, title: String, cover: String, releaseText: String, reservedAt: Date) {
            self.seriesId = seriesId
            self.title = title
            self.cover = cover
            self.releaseText = releaseText
            self.reservedAt = reservedAt
        }
    }
    @ObservationIgnored private var localReservations: [LocalReservation] = []
    @ObservationIgnored private var reservationsFile: URL?

    public func rememberEpisode(seriesId: String, episode: Int, position: Double?) {
        episodePositions.set(seriesId: seriesId, episode: episode, position: position)
        guard let file = episodePositionsFile, let data = try? JSONEncoder().encode(episodePositions) else { return }
        try? data.write(to: file, options: [.atomic])
    }

    /// Bumped when history or favourites change, so lists re-read the stores.
    public private(set) var libraryRevision = 0
    public var settings: AppSettings {
        didSet { if settings != oldValue { store.settings = settings } }
    }

    /// - Parameters:
    ///   - offline: sample runs keep their history and favourites in a temporary folder, away
    ///     from the real ones, and are seeded with a few sample rows.
    ///   - defaults: where 不感兴趣 and the feed's recent exposures are kept.
    ///   - base: the storage root for live runs. nil (the apps): `StorageRoot.base` and the shared
    ///     stores. A folder (tests): the stores and the files live there instead.
    public init(offline: Bool, account: AccountModel, backend: any DramaBackend,
                defaults: UserDefaults = .standard, base: URL? = nil) {
        self.offline = offline
        self.account = account
        self.backend = backend
        self.defaults = defaults
        if offline {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HongguoFixtures-\(UUID().uuidString)")
            store = LibraryStore(directory: directory, mirror: nil)
            seriesLibrary = SeriesLibrary(directory: directory)
        } else if let base {
            let folder = base.appendingPathComponent("HongguoDrama", isDirectory: true)
            store = LibraryStore(directory: folder, mirror: nil)
            seriesLibrary = SeriesLibrary(directory: folder)
        } else {
            store = .shared
            seriesLibrary = .shared
        }
        settings = store.settings
        dislikedSeriesIds = Set(DislikeStore.decode(defaults.string(forKey: Self.dislikedKey) ?? ""))
        recentFeedOrder = FeedSeenStore.decode(defaults.string(forKey: Self.recentFeedKey) ?? "")
        recentFeedSet = Set(recentFeedOrder)
        // Sample runs keep nothing; live runs read what earlier visits left.
        if !offline {
            let folder = base ?? StorageRoot.base
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("episode-positions.json")
            episodePositionsFile = file
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(EpisodePositionBook.self, from: data) {
                episodePositions = saved
            }
            let resFile = folder.appendingPathComponent("reservations.json")
            reservationsFile = resFile
            if let data = try? Data(contentsOf: resFile), let saved = try? JSONDecoder().decode([LocalReservation].self, from: data) {
                localReservations = saved
            }
        }
        if offline { seedFixtures() }
    }

    /// Live runs only, once at launch: hands the account's history to the store, isolates it per
    /// account, then (after the opening video's first frame, at most 1.2 s, so the cold start's
    /// network goes to it) warms the App source up, restores the saved login and starts syncing.
    public func startLive(firstFrameReady: @escaping @MainActor () -> Bool) {
        guard !offline else { return }
        account.onHistoryRows = { [weak self] rows in
            guard let self, self.store.mergeCloudHistory(rows, accountId: self.account.session.current?.accountId) > 0 else { return }
            self.libraryChanged()
        }
        account.onSessionChanged = { [weak self] accountId in
            guard let self else { return }
            self.store.clearCloudHistory(exceptAccountId: accountId)
            self.libraryChanged()
        }
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(1.2)
            while self != nil, !firstFrameReady(), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await EpisodeResolver.shared.warmUpAppSource()
            if AccountDataAccess.hasSavedLogin {
                await self?.account.restoreIfNeeded(refresh: false)
                await self?.syncAccount(force: true)
                self?.startForegroundSyncLoop()
            }
        }
    }

    private func seedFixtures() {
        for (offset, progress) in [(1, 3), (2, 65), (3, 12), (4, 80)].enumerated() {
            let summary = FixtureBackend.summary(progress.0)
            store.savePosition(seriesId: summary.seriesId, title: summary.title, cover: "", total: summary.episodeCount,
                               episodeIndex: min(progress.1, summary.episodeCount), vid: "\(summary.seriesId)-ep\(progress.1)",
                               position: 31, duration: 95, finished: offset % 2 == 1 && progress.1 >= summary.episodeCount)
            _ = try? seriesLibrary.setFavorite(offset < 3, seriesId: summary.seriesId, title: summary.title)
        }
    }

    public func libraryChanged() { libraryRevision += 1 }

    // MARK: Account sync

    @ObservationIgnored private var accountSync = AccountSyncThrottle(interval: 60)
    @ObservationIgnored private var foregroundSyncLoop: Task<Void, Never>?

    /// Reads the account's lists and (unless 云端观看记录 is off) its whole history, which is
    /// merged into this device's store. Runs only signed in and online, once per minute unless
    /// forced, and never twice at the same time.
    public func syncAccount(force: Bool = false) async {
        guard !offline, !backend.isOffline, account.isSignedIn else { return }
        guard accountSync.begin(now: Date(), force: force) else { return }
        defer { accountSync.end() }
        await account.refreshAccountData(includeHistory: settings.cloudHistorySync)
    }

    /// Back in the app: sync once, then every 3 minutes while it stays in front.
    public func sceneBecameActive() {
        guard !offline else { return }
        Task { await syncAccount(force: account.hasListFailure) }
        startForegroundSyncLoop()
    }

    public func startForegroundSyncLoop() {
        guard !offline else { return }
        foregroundSyncLoop?.cancel()
        foregroundSyncLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled else { return }
                await self?.syncAccount()
            }
        }
    }

    public func sceneEnteredBackground() {
        foregroundSyncLoop?.cancel()
        foregroundSyncLoop = nil
    }

    // MARK: Public counts and the local like

    /// What the public player page says about an episode (likes, comment total) and its series
    /// (collect count), by episode id. Loaded once per episode, read by the action buttons.
    public private(set) var social: [String: EpisodeSocial] = [:]
    @ObservationIgnored private var socialOrder: [String] = []
    @ObservationIgnored private var socialLoading: Set<String> = []

    public func loadSocial(seriesId: String, vid: String) {
        guard social[vid] == nil, !socialLoading.contains(vid) else { return }
        socialLoading.insert(vid)
        Task {
            if let loaded = try? await backend.social(seriesId: seriesId, vid: vid) {
                socialOrder.removeAll { $0 == vid }
                socialOrder.append(vid)
                social[vid] = loaded
                while socialOrder.count > 64 {
                    social[socialOrder.removeFirst()] = nil
                }
            }
            socialLoading.remove(vid)
        }
    }

    /// Reflects a newly posted episode comment in the cached social snapshot immediately so the
    /// action bar's comment count and subsequent panel opens stay up to date.
    public func recordPostedComment(_ comment: EpisodeSocial.Comment, vid: String) {
        guard var current = social[vid] else { return }
        if !current.comments.contains(where: { $0.id == comment.id }) {
            current.comments.insert(comment, at: 0)
            current.commentTotal = (current.commentTotal ?? current.comments.count - 1) + 1
            social[vid] = current
        }
    }

    /// Checks account likes when signed in, falling back to local likes when signed out.
    public func isLiked(seriesId: String, vid: String, episodeIndex: Int) -> Bool {
        _ = libraryRevision
        if account.isSignedIn { return account.isLiked(seriesId: seriesId, vid: vid, episodeIndex: episodeIndex) }
        return seriesLibrary.series(seriesId)?.likedEpisodeIds.contains(vid) ?? false
    }

    public func toggleLike(seriesId: String, title: String, cover: String = "", vid: String, episodeIndex: Int = 0) {
        let next = !isLiked(seriesId: seriesId, vid: vid, episodeIndex: episodeIndex)
        if !cover.isEmpty {
            _ = try? seriesLibrary.recordOpened(seriesId: seriesId, title: title, cover: cover)
        }
        let localLiked = seriesLibrary.series(seriesId)?.likedEpisodeIds.contains(vid) ?? false
        let localChanged = localLiked != next
        if localChanged {
            _ = try? seriesLibrary.toggleEpisodeLike(seriesId: seriesId, title: title, vid: vid)
        }
        libraryChanged()
        if account.isSignedIn {
            account.enqueue(.like(vid), desired: next) { [weak self] account in
                let outcome = await account.syncLike(seriesId: seriesId, title: title, cover: cover, vid: vid, episodeIndex: episodeIndex, liked: next)
                guard outcome == .failed, localChanged, let self else { return }
                let local = self.seriesLibrary.series(seriesId)?.likedEpisodeIds.contains(vid) ?? false
                guard LocalRollback.shouldRevert(local: local, failedTarget: next) else { return }
                _ = try? self.seriesLibrary.toggleEpisodeLike(seriesId: seriesId, title: title, vid: vid)
                self.libraryChanged()
            }
        }
    }

    public func likedSeries() -> [LibrarySeries] {
        _ = libraryRevision
        return seriesLibrary.recent().filter { !$0.likedEpisodeIds.isEmpty }
    }

    public func removeLocalLike(seriesId: String, vid: String) {
        guard let item = seriesLibrary.series(seriesId), item.likedEpisodeIds.contains(vid) else { return }
        _ = try? seriesLibrary.toggleEpisodeLike(seriesId: seriesId, title: item.title, vid: vid)
        libraryChanged()
    }

    public func clearLocalLikes(seriesId: String) {
        guard let item = seriesLibrary.series(seriesId) else { return }
        for vid in item.likedEpisodeIds {
            _ = try? seriesLibrary.toggleEpisodeLike(seriesId: seriesId, title: item.title, vid: vid)
        }
        libraryChanged()
    }

    private func saveLocalReservations() {
        if let file = reservationsFile, let data = try? JSONEncoder().encode(localReservations) {
            try? data.write(to: file, options: [.atomic])
        }
    }

    public func reservations() -> [LocalReservation] {
        _ = libraryRevision
        return localReservations.sorted { $0.reservedAt > $1.reservedAt }
    }

    public func isReserved(_ seriesId: String) -> Bool {
        _ = libraryRevision
        if account.isSignedIn { return account.isReserved(seriesId) }
        return localReservations.contains { $0.seriesId == seriesId }
    }

    public func toggleReservation(seriesId: String, subscribeItemId: String = "", title: String, cover: String, releaseText: String = "已预约") {
        let alreadyReserved = isReserved(seriesId) || (!subscribeItemId.isEmpty && isReserved(subscribeItemId))
        let next = !alreadyReserved
        // Only a change this tap made to the device's own list is put back if the write fails.
        let localChanged = localReservations.contains(where: { $0.seriesId == seriesId }) != next
        if next {
            if !localReservations.contains(where: { $0.seriesId == seriesId }) {
                localReservations.insert(LocalReservation(seriesId: seriesId, title: title, cover: cover,
                                                          releaseText: releaseText, reservedAt: Date()), at: 0)
            }
        } else {
            localReservations.removeAll { $0.seriesId == seriesId }
        }
        saveLocalReservations()
        libraryChanged()
        if account.isSignedIn {
            account.enqueue(account.reservationKey(seriesId, itemId: subscribeItemId), desired: next) { [weak self] account in
                let outcome = await account.syncReservation(seriesId: seriesId, subscribeItemId: subscribeItemId,
                                                            title: title, cover: cover, releaseText: releaseText, reserved: next)
                guard outcome == .failed, localChanged, let self else { return }
                let local = self.localReservations.contains { $0.seriesId == seriesId }
                guard LocalRollback.shouldRevert(local: local, failedTarget: next) else { return }
                if next {
                    self.localReservations.removeAll { $0.seriesId == seriesId }
                } else {
                    self.localReservations.insert(LocalReservation(seriesId: seriesId, title: title, cover: cover,
                                                                   releaseText: releaseText, reservedAt: Date()), at: 0)
                }
                self.saveLocalReservations()
                self.libraryChanged()
            }
        }
    }

    public func syncWatchHistory(seriesId: String, title: String, cover: String, total: Int, vid: String,
                                 episodeIndex: Int, position: Double, duration: Double, finished: Bool, force: Bool = false) {
        guard account.isSignedIn else { return }
        account.enqueue(.history(seriesId)) { account in
            await account.syncHistory(seriesId: seriesId, title: title, cover: cover, total: total,
                                      vid: vid, episodeIndex: episodeIndex, position: position,
                                      duration: duration, finished: finished, force: force)
        }
    }

    /// Series the viewer explicitly marked as "不感兴趣", kept locally and reported best-effort.
    private static let dislikedKey = "dislikedSeriesIds"
    public private(set) var dislikedSeriesIds: Set<String>
    /// Set by the player when the viewer taps "不感兴趣" so the feed removes the card and shows undo.
    public var pendingFeedDislikeSeriesId: String?

    public func isDisliked(_ seriesId: String) -> Bool {
        dislikedSeriesIds.contains(seriesId)
    }

    public func removeLocalReservation(seriesId: String) {
        let before = localReservations.count
        localReservations.removeAll { $0.seriesId == seriesId }
        if localReservations.count != before {
            saveLocalReservations()
            libraryChanged()
        }
    }

    public func markNotInterested(seriesId: String) {
        let current = DislikeStore.decode(defaults.string(forKey: Self.dislikedKey) ?? "")
        let updated = DislikeStore.add(seriesId, to: current)
        defaults.set(DislikeStore.encode(updated), forKey: Self.dislikedKey)
        dislikedSeriesIds = Set(updated)
        if account.isSignedIn, account.mode == .live, !offline {
            let accountId = account.profile?.id
            Task { try? await AccountDataAccess.reportNotInterested(accountId: accountId, seriesId: seriesId, recall: false) }
        }
    }

    public func undoNotInterested(seriesId: String) {
        let current = DislikeStore.decode(defaults.string(forKey: Self.dislikedKey) ?? "")
        let updated = DislikeStore.remove(seriesId, from: current)
        defaults.set(DislikeStore.encode(updated), forKey: Self.dislikedKey)
        dislikedSeriesIds = Set(updated)
        if account.isSignedIn, account.mode == .live, !offline {
            let accountId = account.profile?.id
            Task { try? await AccountDataAccess.reportNotInterested(accountId: accountId, seriesId: seriesId, recall: true) }
        }
    }

    /// Series recently shown in the home feed (`recent_impr_gid` / client-side session dedupe),
    /// matching the official app's `SSBizStoreSessionRecordManager`.
    private static let recentFeedKey = "recentFeedSeriesIds"
    @ObservationIgnored private var recentFeedOrder: [String]
    @ObservationIgnored public private(set) var recentFeedSet: Set<String>

    public func recordFeedImpression(_ seriesId: String) {
        guard !seriesId.isEmpty else { return }
        if recentFeedOrder.first == seriesId { return }
        recentFeedOrder = FeedSeenStore.record(seriesId, in: recentFeedOrder)
        recentFeedSet = Set(recentFeedOrder)
        defaults.set(FeedSeenStore.encode(recentFeedOrder), forKey: Self.recentFeedKey)
    }

    public var recentFeedImprIds: [String] { recentFeedOrder }

    /// Disliked IDs first (never crowded out by the 30-item cap), then recent exposures.
    public var feedForceFilterIds: [String] {
        var seen = Set<String>()
        var combined: [String] = []
        let dislikedOrdered = DislikeStore.decode(defaults.string(forKey: Self.dislikedKey) ?? "")
        for id in dislikedOrdered where seen.insert(id).inserted { combined.append(id) }
        for id in recentFeedOrder where seen.insert(id).inserted { combined.append(id) }
        return combined
    }

    public func history() -> [WatchRecord] {
        _ = libraryRevision
        return store.history()
    }

    public func favorites() -> [LibrarySeries] {
        _ = libraryRevision
        return seriesLibrary.favorites()
    }

    public func isFavorite(_ seriesId: String) -> Bool {
        _ = libraryRevision
        if account.isSignedIn { return account.isInShelf(seriesId) }
        return seriesLibrary.isFavorite(seriesId)
    }

    /// Toggles favourite locally and syncs to the signed-in account's video bookshelf.
    public func toggleFavorite(seriesId: String, title: String, cover: String) {
        let next = !isFavorite(seriesId)
        let localChanged = seriesLibrary.isFavorite(seriesId) != next
        _ = try? seriesLibrary.setFavorite(next, seriesId: seriesId, title: title, cover: cover)
        libraryChanged()
        if account.isSignedIn {
            account.enqueue(.favorite(seriesId), desired: next) { [weak self] account in
                let outcome = await account.syncFavorite(seriesId: seriesId, title: title, cover: cover, collected: next)
                guard outcome == .failed, localChanged, let self else { return }
                guard LocalRollback.shouldRevert(local: self.seriesLibrary.isFavorite(seriesId), failedTarget: next) else { return }
                _ = try? self.seriesLibrary.setFavorite(!next, seriesId: seriesId, title: title, cover: cover)
                self.libraryChanged()
            }
        }
    }
}

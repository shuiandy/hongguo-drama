import AppLogic
import Foundation
import HongguoCore
import Observation

/// The signed-in account, as far as the core knows one: a nickname, an id and the account's
/// watch history. Read only. Nothing here logs or exposes the login cookie.
@MainActor
@Observable
public final class AccountModel {
    public enum Mode { case live, offline, preview }

    public struct Identity: Equatable {
        public var id: String
        public var nickname: String
        public init(id: String, nickname: String) { self.id = id; self.nickname = nickname }
    }
    /// A series on the account's bookshelf, with what is needed to show and open it.
    public struct ShelfSeries: Identifiable, Equatable {
        public var seriesId: String
        public var title: String
        public var cover: String
        public var episodeCount: Int
        public var watchedEpisode: Int = 0
        public var category: String = ""
        public var id: String { seriesId }

        public init(seriesId: String, title: String, cover: String, episodeCount: Int, watchedEpisode: Int = 0,
                    category: String = "") {
            self.seriesId = seriesId
            self.title = title
            self.cover = cover
            self.episodeCount = episodeCount
            self.watchedEpisode = watchedEpisode
            self.category = category
        }
    }
    /// A liked series from the account.
    public struct LikedSeries: Identifiable, Equatable {
        public var seriesId: String
        public var vid: String = ""
        public var title: String
        public var cover: String
        public var episodeIndex: Int = 0
        public var episodeCount: Int
        public var diggedCount: Int = 0
        public var category: String = ""
        public var detail: String
        public var id: String { "\(seriesId):\(vid.isEmpty ? String(episodeIndex) : vid)" }

        public func matches(seriesId: String, vid: String, episode: Int) -> Bool {
            guard self.seriesId == seriesId else { return false }
            if !self.vid.isEmpty && !vid.isEmpty { return self.vid == vid }
            return episode > 0 && episodeIndex == episode
        }

        public init(seriesId: String, vid: String = "", title: String, cover: String, episodeIndex: Int = 0,
                    episodeCount: Int, diggedCount: Int = 0, category: String = "", detail: String) {
            self.seriesId = seriesId
            self.vid = vid
            self.title = title
            self.cover = cover
            self.episodeIndex = episodeIndex
            self.episodeCount = episodeCount
            self.diggedCount = diggedCount
            self.category = category
            self.detail = detail
        }
    }
    /// A reserved series from the account.
    public struct ReservedSeries: Identifiable, Equatable {
        public var seriesId: String
        public var subscribeItemId: String = ""
        public var title: String
        public var cover: String
        public var isOnline: Bool
        public var releaseText: String
        public var subtitle: String = ""
        public var heatText: String = ""
        public var category: String = ""
        public var description: String
        public var id: String { seriesId }

        public init(seriesId: String, subscribeItemId: String = "", title: String, cover: String, isOnline: Bool,
                    releaseText: String, subtitle: String = "", heatText: String = "", category: String = "",
                    description: String) {
            self.seriesId = seriesId
            self.subscribeItemId = subscribeItemId
            self.title = title
            self.cover = cover
            self.isOnline = isOnline
            self.releaseText = releaseText
            self.subtitle = subtitle
            self.heatText = heatText
            self.category = category
            self.description = description
        }
    }

    /// The account's picture inside the app; empty until it is known.
    public private(set) var avatar = ""
    /// The account's video bookshelf (收藏 / 追剧), read only.
    public private(set) var shelf: [ShelfSeries] = []
    /// The account's liked videos/series (点赞), read only.
    public private(set) var likes: [LikedSeries] = []
    /// The account's reserved series (预约), read only.
    public private(set) var reservations: [ReservedSeries] = []

    public private(set) var profile: Identity?
    /// The account's watch history, in the shape the 历史 wall merges with this device's.
    public private(set) var history: [HistoryEntry] = []
    /// Text safe to show (the core strips addresses and cookies from its messages).
    public private(set) var message = ""
    public private(set) var isLoadingHistory = false
    public let mode: Mode
    @ObservationIgnored private let service: AccountService
    @ObservationIgnored private var restored = false
    /// A new session on every sign-in and sign-out, so in-flight refreshes from a previous
    /// session (or another account) can never write stale avatar, history or bookshelf rows back.
    @ObservationIgnored public private(set) var session = AccountSessionGate()
    /// Numbers history requests; only the newest one writes. A refresh never waits for (or is
    /// skipped because of) an earlier request, which may belong to a cancelled sync.
    @ObservationIgnored private var historyRequest = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// What the last list refresh said about lists it could not read; cleared once all read again.
    public private(set) var listFailureMessage = ""
    public var hasListFailure: Bool { !listFailureMessage.isEmpty }
    /// The account's whole history, handed to the device's own store after every successful read
    /// (set by `AppModel`, which owns the store).
    @ObservationIgnored public var onHistoryRows: (@MainActor ([AccountHistoryItem]) -> Void)?
    /// Called whenever the active account changes (nil when signed out / expired) so `AppModel`
    /// can isolate cloud-synced history per account.
    @ObservationIgnored public var onSessionChanged: (@MainActor (String?) -> Void)?
    @ObservationIgnored private var shelfWriteGen = 0
    @ObservationIgnored private var likesWriteGen = 0
    @ObservationIgnored private var reservationsWriteGen = 0
    @ObservationIgnored private var historyWriteGen = 0
    @ObservationIgnored private var authMutationCount = 0

    /// How a write to the account ended: `skipped` when nothing was sent (signed out, or the
    /// session changed before the answer came back).
    public enum WriteOutcome { case saved, failed, skipped }

    public init(mode: Mode, service: AccountService = .shared) {
        self.mode = mode
        self.service = service
        if mode == .live {
            // Seed the saved profile synchronously from Keychain (~1 ms, zero network) so cold-start
            // LandingCache lookup matches the signed-in account at T = 0 and Me/Drawer never flash "未登录".
            if let saved = try? KeychainCredentialStore().load()?.profile,
               saved.id.matchesDigits(min: 1, max: 30) {
                profile = Identity(id: saved.id, nickname: saved.nickname)
                session.signedIn(accountId: saved.id)
            }
            // The core cleared an expired saved login: end the session here the same way.
            NotificationCenter.default.addObserver(forName: AccountService.sessionExpiredNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sessionExpired() }
            }
        }
        if mode == .preview {
            // A made-up session for looking at the signed-in layout. No request is made.
            profile = Identity(id: "0000000000", nickname: "示例用户")
            history = Self.previewHistory
            shelf = [ShelfSeries(seriesId: "preview-shelf-1", title: "账号收藏里的一部剧", cover: "", episodeCount: 88, watchedEpisode: 12)]
            likes = [LikedSeries(seriesId: "preview-like-1", title: "账号点赞过的一部剧", cover: "", episodeCount: 60, detail: "第3集")]
            reservations = [ReservedSeries(seriesId: "preview-reserve-1", title: "账号预约的一部新剧", cover: "", isOnline: false, releaseText: "即将上线", description: "")]
        }
    }

    public var isSignedIn: Bool { profile != nil }
    /// Sign-in needs the real website; sample runs have no network.
    public var canSignIn: Bool { mode == .live }

    /// Reads the saved login once (the core checks it with the website in the background).
    public func restoreIfNeeded(refresh: Bool = true) async {
        guard mode == .live, !restored else { return }
        restored = true
        let mutation = authMutationCount
        let status = await service.status()
        // If the user manually signed in/out or expired while `status()` was awaiting, do not clobber.
        guard authMutationCount == mutation else { return }
        message = status.error
        if let verified = status.profile {
            let next = Identity(id: verified.id, nickname: verified.nickname)
            if profile != next { profile = next }
            if session.current?.accountId != next.id {
                session.signedIn(accountId: next.id)
            }
            onSessionChanged?(next.id)
            if refresh { await refreshAccountData() }
        } else if !status.error.isEmpty && AccountDataAccess.hasSavedLogin {
            // Transient offline/network failure with credentials still saved: allow retry later
            // and never wipe cloud-synced local watch history.
            restored = false
        } else {
            if profile != nil { clearSession() } else { onSessionChanged?(nil) }
        }
    }

    /// History, the in-app profile (name and picture), bookshelf, likes and reservations,
    /// fetched in parallel so avatar/nickname appear immediately without waiting for history.
    public func refreshAccountData(includeHistory: Bool = true) async {
        guard mode == .live, profile != nil, let token = session.current else { return }
        let userId = token.accountId
        let startShelfGen = shelfWriteGen
        let startReservationsGen = reservationsWriteGen
        let startLikesGen = likesWriteGen
        refreshTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // The profile only gives the picture and name, so a failure there stays quiet.
            async let profileTask = try? AccountDataAccess.profile()
            async let shelfVideosTask = Self.result { try await AccountDataAccess.bookshelfVideos() }
            async let reservationsTask = Self.result { try await AccountDataAccess.reservations() }
            async let likesTask = Self.result { try await AccountDataAccess.likedVideos(userId: userId) }
            async let historyTask: Void = includeHistory ? self.refreshHistory(token: token) : ()
            var failures: [String] = []

            if let info = await profileTask {
                guard !Task.isCancelled, self.session.accepts(token) else { return }
                self.avatar = info.avatar
                if !info.name.isEmpty, let current = self.profile {
                    self.profile = Identity(id: current.id, nickname: info.name)
                }
            }
            switch await shelfVideosTask {
            case .failure(let error): failures.append("收藏：\(Self.describe(error))")
            case .success(let videos):
                guard !Task.isCancelled, self.session.accepts(token) else { return }
                if self.shelfWriteGen == startShelfGen && !self.hasPendingWrites(matching: { if case .favorite = $0 { return true }; return false }) {
                    self.shelf = videos.map {
                        ShelfSeries(seriesId: $0.seriesId, title: $0.title, cover: $0.cover,
                                    episodeCount: $0.episodeCount, watchedEpisode: $0.watchedEpisode,
                                    category: $0.category)
                    }
                }
            }
            switch await reservationsTask {
            case .failure(let error): failures.append("预约：\(Self.describe(error))")
            case .success(let items):
                guard !Task.isCancelled, self.session.accepts(token) else { return }
                if self.reservationsWriteGen == startReservationsGen && !self.hasPendingWrites(matching: { if case .reservation = $0 { return true }; return false }) {
                    self.reservations = items.map {
                        ReservedSeries(seriesId: $0.seriesId, subscribeItemId: $0.subscribeItemId,
                                       title: $0.title, cover: $0.cover,
                                       isOnline: $0.isOnline, releaseText: $0.releaseText,
                                       subtitle: $0.subtitle, heatText: $0.heatText,
                                       category: $0.category, description: $0.description)
                    }
                }
            }
            switch await likesTask {
            case .failure(let error): failures.append("点赞：\(Self.describe(error))")
            case .success(let items):
                guard !Task.isCancelled, self.session.accepts(token) else { return }
                if self.likesWriteGen == startLikesGen && !self.hasPendingWrites(matching: { if case .like = $0 { return true }; return false }) {
                    self.likes = items.map {
                        LikedSeries(seriesId: $0.seriesId, vid: $0.vid, title: $0.title, cover: $0.cover,
                                    episodeIndex: $0.episodeIndex, episodeCount: $0.episodeCount,
                                    diggedCount: $0.diggedCount, category: $0.category, detail: $0.detail)
                    }
                }
            }
            await historyTask
            guard !Task.isCancelled, self.session.accepts(token) else { return }
            // A list that could not be read keeps what it showed before; say which ones.
            if failures.isEmpty {
                if !self.listFailureMessage.isEmpty, self.message == self.listFailureMessage { self.message = "" }
                self.listFailureMessage = ""
            } else {
                self.listFailureMessage = "同步失败 · " + failures.joined(separator: "；")
                self.message = self.listFailureMessage
            }
        }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    // MARK: - Two-Way Account Sync

    @ObservationIgnored private var lastHistoryUpload: [String: (vid: String, at: Date)] = [:]

    public enum WriteKey: Hashable {
        case favorite(String), like(String), reservation(String), history(String)
    }

    private var writes: [WriteKey: (id: UUID, desired: Bool?, task: Task<Void, Never>)] = [:]

    /// Capture the session at the tap, and preserve submission order for the same record.
    public func enqueue(_ key: WriteKey, desired: Bool? = nil, _ action: @escaping @MainActor (AccountModel) async -> Void) {
        guard mode == .live, let token = session.current else { return }
        switch key {
        case .favorite: shelfWriteGen += 1
        case .like: likesWriteGen += 1
        case .reservation: reservationsWriteGen += 1
        case .history: historyWriteGen += 1
        }
        let previous = writes[key]?.task
        let id = UUID()
        let task = Task { @MainActor in
            defer { if writes[key]?.id == id { writes[key] = nil } }
            await previous?.value
            guard session.accepts(token), !Task.isCancelled else { return }
            await action(self)
        }
        writes[key] = (id, desired, task)
    }

    private func hasPendingWrites(matching predicate: (WriteKey) -> Bool) -> Bool {
        writes.keys.contains(where: predicate)
    }

    private func cancelPendingWrites() {
        for entry in writes.values { entry.task.cancel() }
        writes.removeAll()
    }

    public func isInShelf(_ seriesId: String) -> Bool {
        guard isSignedIn else { return false }
        return writes[.favorite(seriesId)]?.desired ?? shelf.contains { $0.seriesId == seriesId }
    }

    public func isLiked(seriesId: String, vid: String, episodeIndex: Int) -> Bool {
        guard isSignedIn else { return false }
        return writes[.like(vid)]?.desired ?? likes.contains { $0.matches(seriesId: seriesId, vid: vid, episode: episodeIndex) }
    }

    public func reservationKey(_ seriesId: String, itemId: String = "") -> WriteKey {
        if !itemId.isEmpty { return .reservation(itemId) }
        let row = reservations.first { $0.seriesId == seriesId || $0.subscribeItemId == seriesId }
        return .reservation(row.flatMap { $0.subscribeItemId.isEmpty ? nil : $0.subscribeItemId } ?? seriesId)
    }

    public func isReserved(_ seriesId: String, itemId: String = "") -> Bool {
        guard isSignedIn else { return false }
        if !itemId.isEmpty, let desired = writes[.reservation(itemId)]?.desired { return desired }
        if let desired = writes[reservationKey(seriesId, itemId: itemId)]?.desired { return desired }
        if let desired = writes[.reservation(seriesId)]?.desired { return desired }
        return reservations.contains {
            $0.seriesId == seriesId || $0.subscribeItemId == seriesId || (!itemId.isEmpty && $0.subscribeItemId == itemId)
        }
    }

    @discardableResult
    public func syncFavorite(seriesId: String, title: String, cover: String, collected: Bool) async -> WriteOutcome {
        guard mode == .live, let token = session.current else { return .skipped }
        let previous = shelf.enumerated().first { $0.element.seriesId == seriesId }
        if collected {
            if !shelf.contains(where: { $0.seriesId == seriesId }) {
                shelf.insert(ShelfSeries(seriesId: seriesId, title: title.isEmpty ? "剧集 \(seriesId)" : title,
                                         cover: cover, episodeCount: 0), at: 0)
            }
        } else {
            shelf.removeAll { $0.seriesId == seriesId }
        }
        do {
            try await AccountDataAccess.setBookshelfVideo(accountId: token.accountId, seriesId: seriesId, collected: collected)
            guard session.accepts(token) else { return .skipped }
            message = ""
            return .saved
        } catch {
            guard session.accepts(token) else { return .skipped }
            AccountListRollback.restore(&shelf, prior: previous) { $0.seriesId == seriesId }
            message = "收藏同步失败：\((error as? HongguoError)?.message ?? "请稍后重试")"
            return .failed
        }
    }

    @discardableResult
    public func syncLike(seriesId: String, title: String, cover: String, vid: String, episodeIndex: Int = 0, liked: Bool) async -> WriteOutcome {
        guard mode == .live, let token = session.current, !vid.isEmpty else { return .skipped }
        let matches: (LikedSeries) -> Bool = { item in
            item.matches(seriesId: seriesId, vid: vid, episode: episodeIndex)
        }
        let previous = likes.enumerated().first { matches($0.element) }
        if liked {
            if previous == nil {
                let detail = episodeIndex > 0 ? "第\(episodeIndex)集" : "已赞"
                likes.insert(LikedSeries(seriesId: seriesId, vid: vid,
                                         title: title.isEmpty ? "剧集 \(seriesId)" : title,
                                         cover: cover, episodeIndex: episodeIndex, episodeCount: 0,
                                         diggedCount: 0, category: "", detail: detail), at: 0)
            }
        } else {
            likes.removeAll(where: matches)
        }
        do {
            try await AccountDataAccess.setEpisodeDigg(accountId: token.accountId, vid: vid, seriesId: seriesId, liked: liked)
            guard session.accepts(token) else { return .skipped }
            message = ""
            return .saved
        } catch {
            guard session.accepts(token) else { return .skipped }
            AccountListRollback.restore(&likes, prior: previous, matching: matches)
            message = "点赞同步失败：\((error as? HongguoError)?.message ?? "请稍后重试")"
            return .failed
        }
    }

    @discardableResult
    public func syncReservation(seriesId: String, subscribeItemId: String = "", title: String, cover: String,
                         releaseText: String = "待上线", isOnline: Bool = false, reserved: Bool) async -> WriteOutcome {
        guard mode == .live, let token = session.current else { return .skipped }
        let matches: (ReservedSeries) -> Bool = { row in
            row.seriesId == seriesId || row.subscribeItemId == seriesId ||
                (!subscribeItemId.isEmpty && row.subscribeItemId == subscribeItemId)
        }
        let previous = reservations.enumerated().first { matches($0.element) }
        let existing = previous?.element
        let targetItemId = !subscribeItemId.isEmpty ? subscribeItemId : (existing?.subscribeItemId.isEmpty == false ? existing!.subscribeItemId : seriesId)
        let targetOnline = existing?.isOnline ?? isOnline
        if reserved {
            if existing == nil {
                reservations.insert(ReservedSeries(seriesId: seriesId, subscribeItemId: targetItemId,
                                                   title: title.isEmpty ? "剧集 \(seriesId)" : title,
                                                   cover: cover, isOnline: false, releaseText: releaseText,
                                                   subtitle: releaseText, description: ""), at: 0)
            }
        } else {
            reservations.removeAll { $0.seriesId == seriesId || $0.subscribeItemId == targetItemId }
        }
        do {
            if reserved {
                try await AccountDataAccess.setReservation(accountId: token.accountId, itemId: targetItemId, reserved: true)
            } else if targetOnline {
                try await AccountDataAccess.deleteReservation(accountId: token.accountId, itemId: targetItemId, isOnline: true)
            } else {
                try await AccountDataAccess.setReservation(accountId: token.accountId, itemId: targetItemId, reserved: false)
            }
            guard session.accepts(token) else { return .skipped }
            message = ""
            return .saved
        } catch {
            guard session.accepts(token) else { return .skipped }
            AccountListRollback.restore(&reservations, prior: previous, matching: matches)
            message = "预约同步失败：\((error as? HongguoError)?.message ?? "请稍后重试")"
            return .failed
        }
    }

    public func syncHistory(seriesId: String, title: String, cover: String, total: Int, vid: String,
                     episodeIndex: Int, position: Double, duration: Double, finished: Bool, force: Bool = false) async {
        guard mode == .live, let token = session.current, episodeIndex > 0 else { return }
        let now = Date()
        let prev = history.first { $0.seriesId == seriesId }
        let completed = finished
            ? max(prev?.completedEpisode ?? 0, episodeIndex)
            : max(prev?.completedEpisode ?? 0,
                  HistoryMerge.completedEpisode(episodeIndex: episodeIndex, total: total,
                                                position: position, duration: duration))
        let updated = HistoryEntry(
            seriesId: seriesId,
            title: title.isEmpty ? (prev?.title ?? "剧集 \(seriesId)") : title,
            cover: cover.isEmpty ? (prev?.cover ?? "") : cover,
            episodeIndex: episodeIndex,
            total: max(total, prev?.total ?? 0),
            completedEpisode: completed,
            position: finished ? 0 : position,
            updatedAt: now,
            fromAccount: true,
            category: prev?.category ?? ""
        )
        history.removeAll { $0.seriesId == seriesId }
        history.insert(updated, at: 0)

        if !force, let last = lastHistoryUpload[seriesId], last.vid == vid, now.timeIntervalSince(last.at) < 15 {
            return
        }
        do {
            try await AccountDataAccess.uploadReadHistory(
                accountId: token.accountId,
                seriesId: seriesId,
                vid: vid,
                episodeIndex: episodeIndex,
                positionSeconds: finished ? duration : position,
                durationSeconds: duration,
                delete: false
            )
            guard session.accepts(token) else { return }
            lastHistoryUpload[seriesId] = (vid, now)
        } catch {
            // Silent retry on next tick or close; never interrupt playback with a banner.
        }
    }

    @discardableResult
    public func deleteHistory(seriesId: String, vid: String = "", episodeIndex: Int = 1) async -> Bool {
        guard mode == .live, let token = session.current else { return false }
        historyWriteGen += 1
        let previous = history.enumerated().first { $0.element.seriesId == seriesId }
        history.removeAll { $0.seriesId == seriesId }
        do {
            try await AccountDataAccess.uploadReadHistory(
                accountId: token.accountId,
                seriesId: seriesId,
                vid: vid,
                episodeIndex: max(1, episodeIndex),
                positionSeconds: 0,
                delete: true
            )
            guard session.accepts(token) else { return false }
            lastHistoryUpload[seriesId] = nil
            await service.evictCachedHistory(seriesId: seriesId)
            message = ""
            return true
        } catch {
            guard session.accepts(token) else { return false }
            AccountListRollback.restore(&history, prior: previous) { $0.seriesId == seriesId }
            message = "删除历史同步失败：\((error as? HongguoError)?.message ?? "请稍后重试")"
            return false
        }
    }

    /// The account's current row for one series, read fresh right before playback (at most
    /// `timeout` seconds), so continuing never misses a newer position from another device.
    /// The history wall's row follows when the fresh one is newer.
    public func latestHistoryRow(seriesId: String, timeout: Double = 3) async -> AccountHistoryItem? {
        guard mode == .live, let token = session.current else { return nil }
        guard let row = await service.latestHistoryRow(seriesId: seriesId, timeout: timeout),
              session.accepts(token) else { return nil }
        if let at = history.firstIndex(where: { $0.seriesId == seriesId }), history[at].updatedAt < row.updatedAt, row.episodeIndex > 0 {
            history[at].episodeIndex = row.episodeIndex
            history[at].position = row.position
            history[at].updatedAt = row.updatedAt
            history[at].total = max(history[at].total, row.total)
            history[at].completedEpisode = max(history[at].completedEpisode,
                                               HistoryMerge.completedEpisode(episodeIndex: row.episodeIndex, total: history[at].total,
                                                                             position: row.position, duration: row.duration))
        }
        return row
    }

    public func refreshHistory() async {
        guard let token = session.current else { return }
        await refreshHistory(token: token)
    }

    private func refreshHistory(token: AccountSessionGate.Token) async {
        guard mode == .live, session.accepts(token) else { return }
        let startHistoryGen = historyWriteGen
        historyRequest += 1
        let request = historyRequest
        isLoadingHistory = true
        defer { if historyRequest == request { isLoadingHistory = false } }
        do {
            let categorized = try await AccountDataAccess.historyWithCategories()
            guard !Task.isCancelled, session.accepts(token), historyRequest == request else { return }
            guard historyWriteGen == startHistoryGen && !hasPendingWrites(matching: { if case .history = $0 { return true }; return false }) else {
                return
            }
            // The whole history also goes into this device's store, as on the Mac, so a series
            // watched elsewhere resumes from there even when opened from the shelf or a feed.
            onHistoryRows?(categorized.map(\.item))
            history = categorized.map { row in
                let item = row.item
                return HistoryEntry(seriesId: item.seriesId, title: item.seriesTitle, cover: item.cover,
                                    episodeIndex: item.episodeIndex, total: item.total,
                                    completedEpisode: HistoryMerge.completedEpisode(episodeIndex: item.episodeIndex, total: item.total,
                                                                                    position: item.position, duration: item.duration),
                                    position: item.position, updatedAt: item.updatedAt, fromAccount: true,
                                    category: row.category)
            }
            message = ""
        } catch {
            guard !Task.isCancelled, session.accepts(token), historyRequest == request else { return }
            message = (error as? HongguoError)?.message ?? "账号历史暂时取不到"
        }
    }

    public func startQR() async throws -> AccountLoginQR { try await service.startLogin() }

    /// nil while waiting; true once signed in; false when the code expired or was cancelled.
    public func pollQR(_ loginId: String) async throws -> Bool? {
        let status = try await service.pollLogin(loginId)
        switch status {
        case .pending: return nil
        case .expired, .cancelled: return false
        case .signedIn: return await apply(status)
        }
    }

    public func cancelQR(_ loginId: String?) async { await service.cancelLogin(loginId) }

    /// Finishes sign-in with cookies captured from the embedded desktop web view.
    public func completeWebLogin(cookie: String) async throws -> Bool {
        let status = try await service.completeWebLogin(cookie: cookie)
        return await apply(status)
    }

    /// Sign-in ends once the login is verified: the login screen closes while history,
    /// favourites (up to 60 lookups when the bookshelf only gives ids), likes and reservations
    /// load in the background. That sync writes only while this session lasts.
    private func apply(_ status: AccountLoginStatus) async -> Bool {
        guard case .signedIn(let next, let warning) = status else { return false }
        authMutationCount += 1
        restored = true
        cancelPendingWrites()
        refreshTask?.cancel()
        refreshTask = nil
        lastHistoryUpload.removeAll()
        listFailureMessage = ""
        avatar = ""
        shelf = []
        likes = []
        reservations = []
        history = []
        session.signedIn(accountId: next.id)
        profile = Identity(id: next.id, nickname: next.nickname)
        message = warning
        onSessionChanged?(next.id)
        Task { await self.refreshAccountData() }
        return true
    }

    /// Switches to another login saved on this device (AccountRoster), through the same steps as
    /// a sign-in (`apply`): a new session, the old session's queued writes dropped, cloud history
    /// that is not the new account's cleared, the account's lists read again. Live, the core makes
    /// it the current login without a request; sample runs only change the session here.
    public func switchAccount(to saved: AccountCredentials) async -> Bool {
        let status: AccountLoginStatus
        if mode == .live {
            status = await service.switchTo(saved)
        } else if let profile = saved.profile {
            status = .signedIn(profile, storageWarning: "")
        } else {
            return false
        }
        return await apply(status)
    }

    public func signOut() async {
        clearSession()
        if mode == .live { message = await service.logout() }
    }

    /// The core found the saved login no longer accepted and already removed it, so this only
    /// ends the session here (no second logout).
    private func sessionExpired() {
        guard mode == .live, profile != nil else { return }
        clearSession()
        message = "登录已过期，请重新扫码登录"
    }

    private func clearSession() {
        authMutationCount += 1
        session.signedOut()
        cancelPendingWrites()
        refreshTask?.cancel()
        refreshTask = nil
        lastHistoryUpload.removeAll()
        listFailureMessage = ""
        profile = nil
        history = []
        avatar = ""
        shelf = []
        likes = []
        reservations = []
        onSessionChanged?(nil)
    }

    private nonisolated static func result<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private static func describe(_ error: Error) -> String {
        (error as? HongguoError)?.message ?? "暂时取不到"
    }

    private static let previewHistory: [HistoryEntry] = [
        HistoryEntry(seriesId: "preview-account-1", title: "只在账号里的一部剧", cover: "", episodeIndex: 8, total: 80, completedEpisode: 7,
                     position: 12, updatedAt: Date(), fromAccount: true),
        HistoryEntry(seriesId: "preview-account-2", title: "账号里看完的一部剧", cover: "", episodeIndex: 40, total: 40, completedEpisode: 40,
                     position: 88, updatedAt: Date().addingTimeInterval(-7200), fromAccount: true),
    ]
}

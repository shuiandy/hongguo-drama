import Foundation
import HongguoCore
import Observation

/// Two-way sync between this Mac and the signed-in Hongguo account: favourites (bookshelf),
/// episode likes (digg), watch progress and removed history rows. Same requests and rules as
/// the iOS app's account model.
///
/// - A local change is written to the account in the background, in tap order per record, and
///   only while the same account is signed in. A failed write keeps the local change and says so.
/// - On every pull the account's favourites and likes are merged in. Something that was on both
///   sides before and is now gone from the account was removed elsewhere, and goes here too, but
///   only when the account list came back whole (below the request's page cap).
/// - Local favourites and likes the account has never seen (made before signing in) are written
///   up once on the first pull.
/// - Watch progress is written at most every 15 seconds per series while playing, and at once
///   when an episode ends or the player closes. Clearing the whole history stays on this Mac.
@MainActor
@Observable
final class AccountSync {
    static let shared = AccountSync()

    private(set) var message = ""
    private(set) var isPulling = false
    private(set) var lastPull = Date.distantPast
    private(set) var cloudFavoriteCount = 0
    private(set) var cloudLikeCount = 0
    /// The account's own lists from the last pull, for the 我的 page. Read whenever signed in,
    /// whether or not two-way sync is on.
    private(set) var shelf: [AccountDataAccess.BookshelfVideo] = []
    private(set) var likes: [AccountDataAccess.LikedVideo] = []
    private(set) var reservations: [AccountDataAccess.Reservation] = []
    /// When watch progress last reached the account, and the last failure (empty when it worked).
    private(set) var lastProgressUpload = Date.distantPast
    private(set) var progressError = ""

    init() {
        AccountDataAccess.onWriteLog = { line in AccountSyncLog.append(line) }
    }

    /// The request caps of `bookshelfVideos` (4 x 60) and `likedVideos` (4 x 50).
    private static let favoriteCap = 240
    private static let likeCap = 200

    @ObservationIgnored private var lastProgressSent: [String: (vid: String, at: Date)] = [:]
    @ObservationIgnored private var writes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard

    private var model: AppModel { AppModel.shared }
    private var enabled: Bool { model.settings.accountWriteSync }

    /// The signed-in account id, or nil. Checked again before every write.
    private func accountId() async -> String? {
        await AccountService.shared.status().profile?.id
    }

    // MARK: Pull

    /// Brings the account's favourites and likes here and writes up what the account lacks.
    func pull() async {
        guard !isPulling, let id = await accountId() else { return }
        isPulling = true
        defer { isPulling = false }
        async let shelfTask = Self.capture { try await AccountDataAccess.bookshelfVideos() }
        async let likesTask = Self.capture { try await AccountDataAccess.likedVideos(userId: id) }
        async let reservationsTask = Self.capture { try await AccountDataAccess.reservations() }
        let shelfResult = await shelfTask, likesResult = await likesTask, reservationsResult = await reservationsTask
        guard await accountId() == id else { return }
        var problems: [String] = []
        switch shelfResult {
        case .success(let rows):
            shelf = rows
            cloudFavoriteCount = rows.count
            if enabled { mergeFavorites(rows, accountId: id) }
        case .failure(let error): problems.append("收藏：\(Self.text(error))")
        }
        switch likesResult {
        case .success(let rows):
            likes = rows
            cloudLikeCount = rows.count
            if enabled { mergeLikes(rows, accountId: id) }
        case .failure(let error): problems.append("点赞：\(Self.text(error))")
        }
        switch reservationsResult {
        case .success(let rows): reservations = rows
        case .failure(let error): problems.append("预约：\(Self.text(error))")
        }
        lastPull = Date()
        message = problems.isEmpty ? "" : "账号同步未完成（\(problems.joined(separator: "；"))）"
    }

    /// Cancels a reservation on the account (the user's own action on the 我的 page). Same requests
    /// as the iOS app: an online one is deleted from the list, an upcoming one is unsubscribed.
    func cancelReservation(_ item: AccountDataAccess.Reservation) {
        let itemId = item.subscribeItemId.isEmpty ? item.seriesId : item.subscribeItemId
        guard itemId.allSatisfy(\.isNumber), !itemId.isEmpty else { return }
        let previous = reservations
        reservations.removeAll { $0.seriesId == item.seriesId || $0.subscribeItemId == itemId }
        let online = item.isOnline
        enqueue("reservation:\(itemId)") { account in
            if online {
                try await AccountDataAccess.deleteReservation(accountId: account, itemId: itemId, isOnline: true)
            } else {
                do {
                    try await AccountDataAccess.setReservation(accountId: account, itemId: itemId, reserved: false)
                } catch {
                    if error is CancellationError || (error as? HongguoError)?.kind == .cancelled { throw error }
                    try await AccountDataAccess.deleteReservation(accountId: account, itemId: itemId, isOnline: false)
                }
            }
        } failure: { [weak self] text in
            self?.reservations = previous
            return "预约同步失败：\(text)"
        }
    }

    private func mergeFavorites(_ rows: [AccountDataAccess.BookshelfVideo], accountId id: String) {
        let cloud = Set(rows.map(\.seriesId))
        let seenKey = "accountSync.favorites.\(id)"
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        let local = Set(model.favorites.map(\.seriesId))
        let complete = rows.count < Self.favoriteCap
        for row in rows where !local.contains(row.seriesId) {
            _ = try? model.library.setFavorite(true, seriesId: row.seriesId, title: row.title, cover: row.cover)
        }
        for seriesId in local.subtracting(cloud) {
            if seen.contains(seriesId) {
                // Removed from the account elsewhere.
                if complete { _ = try? model.library.setFavorite(false, seriesId: seriesId, title: "") }
            } else if let item = model.library.series(seriesId) {
                favoriteChanged(seriesId: seriesId, title: item.title, collected: true)
            }
        }
        defaults.set(Array(cloud.union(local.subtracting(seen))), forKey: seenKey)
        model.refreshLibrary()
    }

    private func mergeLikes(_ rows: [AccountDataAccess.LikedVideo], accountId id: String) {
        let cloud = rows.filter { !$0.vid.isEmpty }
        let cloudVids = Set(cloud.map(\.vid))
        let seenKey = "accountSync.likes.\(id)"
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        var local: [String: String] = [:]  // vid -> seriesId
        for series in model.library.recent() {
            for vid in series.likedEpisodeIds { local[vid] = series.seriesId }
        }
        let complete = rows.count < Self.likeCap
        for row in cloud where local[row.vid] == nil {
            _ = try? model.library.setEpisodeLike(true, seriesId: row.seriesId, title: row.title, vid: row.vid)
        }
        for (vid, seriesId) in local where !cloudVids.contains(vid) {
            if seen.contains(vid) {
                if complete { _ = try? model.library.setEpisodeLike(false, seriesId: seriesId, title: "", vid: vid) }
            } else {
                likeChanged(seriesId: seriesId, vid: vid, liked: true)
            }
        }
        defaults.set(Array(cloudVids.union(Set(local.keys).subtracting(seen))), forKey: seenKey)
        model.refreshLibrary()
    }

    // MARK: Local changes

    func favoriteChanged(seriesId: String, title: String, collected: Bool) {
        if !collected { shelf.removeAll { $0.seriesId == seriesId } }
        guard enabled, SourceRouter.isHongguo(seriesId), seriesId.allSatisfy(\.isNumber) else { return }
        remember(collected, id: seriesId, in: "favorites")
        enqueue("favorite:\(seriesId)") { account in
            try await AccountDataAccess.setBookshelfVideo(accountId: account, seriesId: seriesId, collected: collected)
        } failure: { "收藏同步失败：\($0)" }
    }

    func likeChanged(seriesId: String, vid: String, liked: Bool) {
        if !liked { likes.removeAll { $0.vid == vid } }
        guard enabled, SourceRouter.isHongguo(seriesId), vid.allSatisfy(\.isNumber), !vid.isEmpty else { return }
        remember(liked, id: vid, in: "likes")
        enqueue("like:\(vid)") { account in
            try await AccountDataAccess.setEpisodeDigg(accountId: account, vid: vid, seriesId: seriesId, liked: liked)
        } failure: { "点赞同步失败：\($0)" }
    }

    /// Called whenever the player saves a position. `force` for episode end and player close.
    func progressSaved(seriesId: String, vid: String, episodeIndex: Int, position: Double, duration: Double,
                       finished: Bool, force: Bool = false) {
        guard enabled, model.settings.cloudHistorySync, SourceRouter.isHongguo(seriesId), episodeIndex > 0 else { return }
        let now = Date()
        if !force, !finished, let last = lastProgressSent[seriesId], last.vid == vid, now.timeIntervalSince(last.at) < 15 { return }
        lastProgressSent[seriesId] = (vid, now)
        enqueue("history:\(seriesId)", quiet: true) { account in
            try await AccountDataAccess.uploadReadHistory(accountId: account, seriesId: seriesId, vid: vid, episodeIndex: episodeIndex,
                                                          positionSeconds: finished ? duration : position,
                                                          durationSeconds: duration, delete: false)
        } success: { [weak self] in
            self?.lastProgressUpload = Date()
            self?.progressError = ""
        } failure: { [weak self] text in
            self?.progressError = text
            return ""
        }
    }

    func historyRemoved(_ record: WatchRecord) {
        guard enabled, model.settings.cloudHistorySync, SourceRouter.isHongguo(record.seriesId) else { return }
        lastProgressSent[record.seriesId] = nil
        enqueue("history:\(record.seriesId)") { account in
            try await AccountDataAccess.uploadReadHistory(accountId: account, seriesId: record.seriesId, vid: record.vid,
                                                          episodeIndex: max(1, record.episodeIndex), positionSeconds: 0, delete: true)
        } failure: { "删除记录同步失败：\($0)" }
    }

    /// Forgets the pending writes when the account signs out.
    func signedOut() {
        shelf = []
        likes = []
        reservations = []
        for task in writes.values { task.cancel() }
        writes.removeAll()
        lastProgressSent.removeAll()
        message = ""
    }

    // MARK: Helpers

    /// Runs `write` after the previous write for the same record, for the account signed in now.
    private func enqueue(_ key: String, quiet: Bool = false,
                         _ write: @escaping @Sendable (String) async throws -> Void,
                         success: @escaping @MainActor () -> Void = {},
                         failure: @escaping @MainActor (String) -> String) {
        let previous = writes[key]
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, let account = await self.accountId() else { return }
            do {
                try await write(account)
                success()
                if !quiet { self.message = "" }
            } catch {
                if error is CancellationError || (error as? HongguoError)?.kind == .cancelled { return }
                let text = failure(Self.text(error))
                if !quiet { self.message = text }
            }
        }
        writes[key] = task
    }

    /// Keeps the "seen on both sides" list in step with a local change, so the next pull does not
    /// read a fresh local add as "removed elsewhere" or write a removal back up.
    private func remember(_ present: Bool, id: String, in list: String) {
        Task { @MainActor in
            guard let account = await accountId() else { return }
            let key = "accountSync.\(list).\(account)"
            var seen = Set(defaults.stringArray(forKey: key) ?? [])
            if present { seen.insert(id) } else { seen.remove(id) }
            defaults.set(Array(seen), forKey: key)
        }
    }

    private static func text(_ error: Error) -> String {
        (error as? HongguoError)?.message ?? (error as? LocalizedError)?.errorDescription ?? "请稍后重试"
    }
}

extension AccountSync {
    nonisolated static func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

/// Write outcomes (path and status code only, never ids or the login) in
/// ~/Library/Logs/HongguoDrama/account-sync.log, so a failed sync can be looked into.
enum AccountSyncLog {
    private static let queue = DispatchQueue(label: "account-sync-log")

    static func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/HongguoDrama", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("account-sync.log")
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 512_000 {
                try? FileManager.default.removeItem(at: url)
            }
            let data = Data("\(stamp) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

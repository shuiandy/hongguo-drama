import SwiftUI
import UserNotifications
import HongguoCore

enum SidebarItem: Hashable, Identifiable {
    case category(CatalogKind)
    case ranking(CatalogKind)
    case search
    /// 热播推荐 (one series at a time, plus 摇一摇).
    case feed
    /// 上新日历.
    case calendar
    /// 我的: history, favourites, likes, reservations and downloads on one page (MeView).
    case me
    /// Older pages now inside 我的; selecting one opens 我的 on that tab.
    case history
    case library
    case downloads
    case account
    /// Another catalogue: "xifan", "hema", "reelshort", "dramabox" or "custom:<uuid>".
    case source(String)

    var id: String {
        switch self {
        case .category(let kind), .ranking(let kind): return kind.rawValue
        case .search: return "search"
        case .feed: return "feed"
        case .calendar: return "calendar"
        case .me: return "me"
        case .history: return "history"
        case .library: return "library"
        case .downloads: return "downloads"
        case .account: return "account"
        case .source(let id): return "source:\(id)"
        }
    }

    var title: String {
        switch self {
        case .category(let kind), .ranking(let kind): return kind.label
        case .search: return "搜索"
        case .feed: return "热播推荐"
        case .calendar: return "上新日历"
        case .me: return "我的"
        case .history: return "观看记录"
        case .library: return "我的剧库"
        case .downloads: return "下载"
        case .account: return "账号"
        case .source(let id): return SourceRouter.label(id)
        }
    }

    /// Stable key saved as `AppSettings.lastPage` (`id` is the same for a category and its ranking).
    var persistKey: String {
        switch self {
        case .category(let kind): return "category:\(kind.rawValue)"
        case .ranking(let kind): return "ranking:\(kind.rawValue)"
        case .source(let id): return "source:\(id)"
        default: return id
        }
    }

    init?(persistKey key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "category": if let raw = parts.last, let kind = CatalogKind(rawValue: raw) { self = .category(kind) } else { return nil }
        case "ranking": if let raw = parts.last, let kind = CatalogKind(rawValue: raw) { self = .ranking(kind) } else { return nil }
        case "source": guard parts.count == 2 else { return nil }; self = .source(parts[1])
        case "search": self = .search
        case "feed": self = .feed
        case "calendar": self = .calendar
        case "me": self = .me
        case "history": self = .history
        case "library": self = .library
        case "downloads": self = .downloads
        case "account": self = .account
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .category(.realDrama): return "person.2"
        case .category(.comicDrama): return "paintpalette"
        case .category: return "sparkles"
        case .ranking: return "flame"
        case .search: return "magnifyingglass"
        case .feed: return "sparkles.tv"
        case .calendar: return "calendar"
        case .me: return "person.crop.circle"
        case .history: return "clock.arrow.circlepath"
        case .library: return "heart"
        case .downloads: return "arrow.down.circle"
        case .account: return "person.crop.circle"
        case .source: return "film.stack"
        }
    }
}

/// What a sidebar column's navigation stack shows: a series, or an actor and their works.
enum DetailRoute: Hashable {
    case series(SeriesSummary)
    case celebrity(EpisodeSocial.CastMember)
}

/// App-wide state: services, settings and navigation.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let search = AppSearchService()
    let catalog = CatalogService()
    let series = SourceRouter.series
    let store = LibraryStore.shared

    var selection: SidebarItem? = .category(.realDrama) {
        didSet {
            if let tab = Self.meTab(for: selection) {
                meTab = tab
                selection = .me
                return
            }
            if showingSettings, selection != oldValue { showingSettings = false }
            guard let key = selection?.persistKey, key != settings.lastPage else { return }
            settings.lastPage = key
        }
    }
    /// The tab open on 我的.
    var meTab: MeTab = .history
    var paths: [SidebarItem: [DetailRoute]] = [:]

    /// The 我的 tab an older page maps to, or nil for any other page.
    static func meTab(for item: SidebarItem?) -> MeTab? {
        switch item {
        case .history: return .history
        case .library: return .favorites
        case .downloads: return .downloads
        default: return nil
        }
    }
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.settings = settings
            if settings.theme != oldValue.theme { applyTheme() }
            if settings.playbackCacheLimitGB != oldValue.playbackCacheLimitGB { applyCacheLimit() }
            if settings.byteVC2Conversion != oldValue.byteVC2Conversion || settings.fastConversion != oldValue.fastConversion {
                ByteVC2Converter.configure(enabled: settings.byteVC2Conversion, fast: settings.fastConversion)
            }
            if settings.preferredQuality != oldValue.preferredQuality || settings.downloadNameFormat != oldValue.downloadNameFormat
                || settings.maxConcurrentDownloads != oldValue.maxConcurrentDownloads || settings.downloadRoot != oldValue.downloadRoot {
                applyDownloadSettings()
            }
        }
    }
    var history: [WatchRecord] = []
    /// Set when the saved manual proxy could not be used at launch (the app connects directly).
    var proxyStartupError: String?

    /// Saves and applies 网络代理 settings; `password` nil keeps the saved one.
    func applyProxy(_ proxy: ProxySettings, password: String?) throws {
        try proxy.validate()
        if let password { try ProxyKeychain.save(password) }
        try NetworkProxy.shared.apply(proxy, password: password)
        settings.proxy = proxy
        proxyStartupError = nil
    }
    /// Query typed into a page header search field, consumed by the search page.
    var pendingSearch: String?
    /// Settings are a mode of the main window: the sidebar lists the categories and the detail
    /// column shows `settingsPane`.
    var showingSettings = false
    var settingsPane: SettingsPane = .general

    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { settingsPane = pane }
        showingSettings = true
    }

    func closeSettings() { showingSettings = false }

    // MARK: Library (favorites and recently opened series)

    let library = SeriesLibrary.shared
    private(set) var favorites: [LibrarySeries] = []
    private(set) var recentSeries: [LibrarySeries] = []

    // MARK: Downloads

    let downloads: DownloadManager
    private(set) var downloadTasks: [DownloadTask] = []
    /// Completed downloads by episode vid, read synchronously by the player.
    private(set) var localFiles: [String: URL] = [:]

    private init() {
        let settings = LibraryStore.shared.settings
        self.settings = settings
        ByteVC2Converter.configure(enabled: settings.byteVC2Conversion, fast: settings.fastConversion)
        // A broken manual proxy falls back to a direct connection so the window can still open.
        do { try NetworkProxy.shared.apply(settings.proxy) } catch { proxyStartupError = describe(error) }
        let start = Self.startSelection(settings)
        if let tab = Self.meTab(for: start) { meTab = tab; selection = .me } else { selection = start }
        history = LibraryStore.shared.history()
        downloads = DownloadManager(configuration: Self.downloadConfiguration(settings))
        refreshLibrary()
        library.onChange = { Task { @MainActor in AppModel.shared.refreshLibrary() } }
        Task { await observeDownloads() }
        applyCacheLimit()
    }

    /// Sidebar page for 打开时显示.
    static func startSelection(_ settings: AppSettings) -> SidebarItem {
        switch settings.startPage {
        case "history": return .history
        case "library": return .library
        case "downloads": return .downloads
        case "discover": return .category(.realDrama)
        default:
            // Other sources are picked inside 发现, and an unknown key falls back to it too.
            guard let key = settings.lastPage, let item = SidebarItem(persistKey: key) else { return .category(.realDrama) }
            if case .source = item { return .category(.realDrama) }
            return item
        }
    }

    func applyCacheLimit() {
        PlaybackCache.shared.setLimit(bytes: Int64(settings.playbackCacheLimitGB) * 1_000_000_000)
    }

    /// Called once at launch (not from init: PlayerController's init reads AppModel.shared).
    func connectPlayer() {
        PlayerController.shared.localFileProvider = { episode in
            MainActor.assumeIsolated { AppModel.shared.localFiles[episode.vid] }
        }
    }

    static func downloadConfiguration(_ settings: AppSettings) -> DownloadConfiguration {
        var config = DownloadConfiguration(nameFormat: settings.downloadNameFormat, maxConcurrent: settings.maxConcurrentDownloads)
        config.preferredQuality = settings.preferredQuality
        if let root = settings.downloadRoot, !root.isEmpty { config.root = URL(fileURLWithPath: root, isDirectory: true) }
        return config
    }

    // MARK: Release calendar backfill

    /// Progress of the first-release date lookup shown on 上新日历, or nil when idle.
    private(set) var publishBackfill: (done: Int, total: Int)?
    /// Series already looked up since launch (found or not), so a page revisit does not ask again.
    private var publishAttempted: Set<String> = []
    private static let publishBackfillLimit = 60

    /// Watched and kept Hongguo series that still have no first-release date, newest first.
    private func publishBackfillCandidates() -> [(seriesId: String, title: String, cover: String, total: Int, openedAt: Date)] {
        var seen = Set<String>()
        var result: [(seriesId: String, title: String, cover: String, total: Int, openedAt: Date)] = []
        func add(_ id: String, _ title: String, _ cover: String, _ total: Int, _ openedAt: Date) {
            guard SourceRouter.isHongguo(id), id.count >= 6, id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), !title.isEmpty,
                  !publishAttempted.contains(id), seen.insert(id).inserted,
                  library.series(id)?.publishedAt == nil else { return }
            result.append((id, title, cover, total, openedAt))
        }
        for record in LibraryStore.shared.history() { add(record.seriesId, record.title, record.cover, record.total, record.updatedAt) }
        for item in library.recent() { add(item.seriesId, item.title, item.cover, item.episodeCount, item.lastOpenedAt) }
        return result
    }

    /// Fills in first-release dates for 上新日历 from the public detail page: one series at a
    /// time, about one request a second, at most 60 per launch. Read-only; cancelling the calling
    /// task (leaving the page) stops it.
    func backfillPublishDates() async {
        guard publishBackfill == nil else { return }
        let budget = Self.publishBackfillLimit - publishAttempted.count
        let pending = Array(publishBackfillCandidates().prefix(max(0, budget)))
        guard !pending.isEmpty else { return }
        publishBackfill = (0, pending.count)
        defer { publishBackfill = nil }
        for (index, item) in pending.enumerated() {
            if Task.isCancelled { return }
            publishAttempted.insert(item.seriesId)
            if let date = (try? await series.publicDetails(seriesId: item.seriesId))?.publishedAt {
                _ = try? library.recordPublishDate(seriesId: item.seriesId, title: item.title, cover: item.cover,
                                                   episodeCount: item.total, publishedAt: date, openedAt: item.openedAt)
            }
            publishBackfill = (index + 1, pending.count)
            if index + 1 < pending.count { try? await Task.sleep(for: .seconds(1)) }
        }
    }

    /// Bumped on every library change so views reading per-episode likes re-render.
    private(set) var libraryRevision = 0

    func refreshLibrary() {
        // A series opened from a sequel link or the account is saved without a cover; the watch
        // history usually has one.
        let covers = Dictionary(history.filter { !$0.cover.isEmpty }.map { ($0.seriesId, $0.cover) }, uniquingKeysWith: { first, _ in first })
        func filled(_ item: LibrarySeries) -> LibrarySeries {
            guard item.cover.isEmpty, let cover = covers[item.seriesId] else { return item }
            var copy = item
            copy.cover = cover
            return copy
        }
        favorites = library.favorites().map(filled)
        recentSeries = library.recent(limit: 60).map(filled)
        libraryRevision &+= 1
    }

    /// The local "little red heart" on one episode (本机分集小红心).
    func isEpisodeLiked(seriesId: String, vid: String) -> Bool {
        _ = libraryRevision
        return library.series(seriesId)?.likedEpisodeIds.contains(vid) ?? false
    }

    @discardableResult
    func toggleEpisodeLike(seriesId: String, title: String, vid: String) -> Bool {
        do {
            let liked = try library.toggleEpisodeLike(seriesId: seriesId, title: title, vid: vid)
            refreshLibrary()
            AccountSync.shared.likeChanged(seriesId: seriesId, vid: vid, liked: liked)
            return liked
        } catch {
            PlayerController.shared.show(toast: describe(error))
            return isEpisodeLiked(seriesId: seriesId, vid: vid)
        }
    }

    func isFavorite(_ seriesId: String) -> Bool { favorites.contains { $0.seriesId == seriesId } }

    // MARK: Player like / favourite (this Mac and the account)

    /// Liked here or on the account (the account row may carry only the episode number).
    func isEpisodeLikedAnywhere(seriesId: String, vid: String, index: Int) -> Bool {
        isEpisodeLiked(seriesId: seriesId, vid: vid) || AccountSync.shared.accountLikes(seriesId: seriesId, vid: vid, index: index)
    }

    /// Flips what the player shows, so a like made on the phone can be taken back here too.
    func setEpisodeLike(_ liked: Bool, seriesId: String, title: String, vid: String, index: Int = 0) {
        do {
            _ = try library.setEpisodeLike(liked, seriesId: seriesId, title: title, vid: vid)
            refreshLibrary()
        } catch {
            PlayerController.shared.show(toast: describe(error))
            return
        }
        AccountSync.shared.likeChanged(seriesId: seriesId, vid: vid, liked: liked, index: index)
    }

    /// Favourited here or on the account's shelf.
    func isFavoriteAnywhere(_ seriesId: String) -> Bool {
        isFavorite(seriesId) || AccountSync.shared.shelf.contains { $0.seriesId == seriesId }
    }

    func setFavorite(_ collected: Bool, seriesId: String, title: String, cover: String) {
        let before = library.isFavorite(seriesId)
        if before != collected { _ = try? library.setFavorite(collected, seriesId: seriesId, title: title, cover: cover) }
        refreshLibrary()
        AccountSync.shared.favoriteChanged(seriesId: seriesId, title: title, collected: collected)
    }

    @discardableResult
    func toggleFavorite(seriesId: String, title: String, cover: String) -> Bool {
        let before = library.isFavorite(seriesId)
        let value = (try? library.toggleFavorite(seriesId: seriesId, title: title, cover: cover)) ?? before
        refreshLibrary()
        if value != before { AccountSync.shared.favoriteChanged(seriesId: seriesId, title: title, collected: value) }
        return value
    }

    private func observeDownloads() async {
        for await tasks in await downloads.updates() {
            exportFinishedSeries(previous: downloadTasks, current: tasks)
            downloadTasks = tasks
            localFiles = Dictionary(tasks.filter { $0.status == .completed }.map { ($0.vid, $0.fileURL) },
                                    uniquingKeysWith: { first, _ in first })
        }
    }

    /// 同时导出弹幕和评论: once every queued episode of a series has finished, saves its danmaku and
    /// episode comments next to the videos. Existing sidecars are skipped by TextExport.
    private func exportFinishedSeries(previous: [DownloadTask], current: [DownloadTask]) {
        guard settings.autoExportText, !previous.isEmpty else { return }
        let before = Set(previous.filter { $0.status == .completed }.map(\.id))
        let newlyDone = Set(current.filter { $0.status == .completed && !before.contains($0.id) }.map(\.seriesId))
        for seriesId in newlyDone {
            let series = current.filter { $0.seriesId == seriesId }
            guard series.allSatisfy({ $0.status == .completed || $0.status == .failed }),
                  let title = series.first?.seriesTitle else { continue }
            Task { _ = await TextExportActions.exportSidecars(seriesId: seriesId, seriesTitle: title) }
        }
    }

    func applyDownloadSettings() {
        let config = Self.downloadConfiguration(settings)
        Task { await downloads.setConfiguration(config) }
    }

    /// Queues episodes for download; returns how many were added.
    @discardableResult
    func download(_ episodes: [Episode], seriesId: String, title: String, cover: String) async -> Int {
        do {
            let added = try await downloads.enqueue(seriesId: seriesId, seriesTitle: title, cover: cover, episodes: episodes)
            if settings.downloadMetadata, SourceRouter.isHongguo(seriesId) {
                let directory = DownloadNaming.seriesDirectory(root: Self.downloadConfiguration(settings).root, seriesId: seriesId, seriesTitle: title)
                Task.detached(priority: .utility) { await Self.saveSeriesMetadata(seriesId: seriesId, title: title, cover: cover, into: directory) }
            }
            return added
        } catch {
            PlayerController.shared.show(toast: describe(error))
            return 0
        }
    }

    func refreshHistory() {
        history = store.history()
    }

    private(set) var lastCloudSync = Date.distantPast
    @ObservationIgnored private var lastFullCloudSync = Date.distantPast
    private(set) var lastCloudSyncCount = 0
    private(set) var cloudSyncing = false
    var cloudSyncMessage = ""

    /// Pulls the signed-in account's cloud watch history into the local history (newer side wins),
    /// then, with 双向同步 on, the account's favourites and likes (`AccountSync`). Local progress
    /// goes up as it is saved. `force` skips the one-minute throttle; `manual` (a button) also
    /// runs when 显示云端观看记录 is off.
    /// Reads the account's current row for one series and merges it when it is newer, so continuing
    /// never starts from a position another device has already moved past. Gives up after `timeout`
    /// seconds and keeps this Mac's record (playback does not wait on a slow network).
    func syncCloudPosition(seriesId: String, timeout: Double = 3) async {
        guard settings.cloudHistorySync, SourceRouter.isHongguo(seriesId) else { return }
        guard let row = await AccountService.shared.latestHistoryRow(seriesId: seriesId, timeout: timeout) else { return }
        if store.mergeCloudHistory([row]) > 0 { refreshHistory() }
    }

    func syncCloudHistory(force: Bool = false, manual: Bool = false) async {
        guard !cloudSyncing, force || Date().timeIntervalSince(lastCloudSync) > 60 else { return }
        guard await AccountService.shared.status().profile != nil else { return }
        cloudSyncing = true
        defer { cloudSyncing = false }
        await AccountSync.shared.pull()
        if AccountState.shared.avatar.isEmpty { await AccountState.shared.loadAvatar() }
        guard manual || settings.cloudHistorySync else { lastCloudSync = Date(); return }
        do {
            // Every page at launch, on demand and every 30 minutes; the 3-minute checks read the newest page.
            let full = force || manual || Date().timeIntervalSince(lastFullCloudSync) > 30 * 60
            let items = try await AccountService.shared.history(refresh: true, firstPageOnly: !full)
            if full { lastFullCloudSync = Date() }
            lastCloudSync = Date()
            lastCloudSyncCount = items.count
            store.mergeCloudHistory(items)
            cloudSyncMessage = ""
            refreshHistory()
        } catch {
            cloudSyncMessage = (error as? HongguoError)?.message ?? "云端观看记录同步失败，请稍后重试"
        }
    }

    // MARK: Background checks (new episodes, sequels, app updates, announcements)

    let watchChecker = WatchUpdateChecker()
    let announcements = AnnouncementService()
    private(set) var watchChecking = false
    var availableRelease: AvailableRelease?
    var updateMessage = ""
    /// The announcement currently shown as a sheet.
    var announcement: Announcement?
    private var backgroundStarted = false

    /// Starts the launch checks and their timers once: update check at launch, announcements at
    /// launch and every 5 minutes (emergency only), watch updates every 30 minutes for due records.
    func startBackgroundChecks() {
        guard !backgroundStarted else { return }
        backgroundStarted = true
        // Register the anonymous playback device now, so the first episode does not wait for it.
        Task { await series.warmUpPlayback() }
        if settings.checkUpdatesAtLaunch { Task { await checkForUpdate(manual: false) } }
        Task {
            var first = true
            while !Task.isCancelled {
                if announcement == nil, let next = await announcements.check(urgentOnly: !first) { announcement = next }
                first = false
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
        // Account sync runs by itself: at launch, when the app comes forward, and every 3 minutes.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3 * 60))
                await syncCloudHistory()
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await checkWatchUpdates(force: false)
                // Wake often enough for the shortest interval; only due records are checked.
                try? await Task.sleep(for: .seconds(min(30 * 60, settings.watchCheckHours * 3600)))
            }
        }
    }

    /// Checks watched series for new episodes and sequels (only due ones unless forced).
    @discardableResult
    func checkWatchUpdates(force: Bool) async -> WatchUpdateChecker.Summary? {
        guard settings.watchUpdatesEnabled, !watchChecking else { return nil }
        watchChecking = true
        defer { watchChecking = false }
        let before = Set(store.history().filter(\.hasUpdates).map(\.seriesId))
        let summary = await watchChecker.refresh(force: force, includeSequels: settings.watchSequelsEnabled,
                                                 every: TimeInterval(settings.watchCheckHours) * 3600)
        refreshHistory()
        if settings.watchNotifications {
            let fresh = history.filter { $0.hasUpdates && !before.contains($0.seriesId) }
            if !fresh.isEmpty { Self.notifyUpdates(fresh) }
        }
        return summary
    }

    /// Asks for notification permission (from the settings switch). Returns whether it was granted.
    static func requestNotificationPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private static func notifyUpdates(_ records: [WatchRecord]) {
        let content = UNMutableNotificationContent()
        content.title = records.count == 1 ? "《\(records[0].title)》有更新" : "\(records.count) 部剧有更新"
        content.body = records.count == 1
            ? (records[0].unreadEpisodes > 0 ? "更新了 \(records[0].unreadEpisodes) 集" : "出了续作")
            : records.prefix(3).map { "《\($0.title)》" }.joined(separator: "、") + (records.count > 3 ? " 等" : "")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "watch-updates-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Clears the "更新 N 集" / "有续作" badges once the user opens the series.
    func acknowledgeUpdates(_ seriesId: String) {
        guard let record = store.record(for: seriesId), record.hasUpdates else { return }
        _ = store.updateRecord(seriesId) { $0.acknowledging() }
        refreshHistory()
    }

    func checkForUpdate(manual: Bool) async {
        if manual { updateMessage = "正在检查…" }
        do {
            availableRelease = try await UpdateChecker().check()
            updateMessage = availableRelease.map { "发现新版本 \($0.version)" } ?? "已是最新版本（\(UpdateChecker.currentVersion)）"
        } catch {
            if manual { updateMessage = (error as? HongguoError)?.message ?? "检查更新失败，请稍后重试" }
        }
    }

    // MARK: Merge export

    private(set) var mergeJobs: [MergeExporter.Job] = []
    private var observingMerges = false

    /// 合并导出: joins the downloaded episodes of a series into one MP4 next to them.
    func startMerge(seriesId: String, title: String, mode: MergeExporter.Mode) async -> String {
        if !observingMerges {
            observingMerges = true
            Task { for await jobs in await MergeExporter.shared.updates() { mergeJobs = jobs.sorted { $0.seriesTitle < $1.seriesTitle } } }
        }
        let files = await downloads.localFiles(seriesId: seriesId)
        let total = library.series(seriesId)?.episodeCount ?? store.record(for: seriesId)?.total
        do {
            let output = try await MergeExporter.shared.start(seriesId: seriesId, seriesTitle: title, files: files,
                                                              total: total.flatMap { $0 > 0 ? $0 : nil }, mode: mode)
            return "开始合并 \(files.count) 集，完成后保存为“\(output.lastPathComponent)”"
        } catch {
            return describe(error)
        }
    }

    // MARK: In-app update

    private(set) var updatePhase: AppUpdateInstaller.Phase = .idle
    private var observingUpdates = false

    /// 下载更新: downloads, checks and unpacks the release archive in the background.
    func downloadUpdate() {
        guard let release = availableRelease else { return }
        if !observingUpdates {
            observingUpdates = true
            Task { for await phase in await AppUpdateInstaller.shared.updates() { updatePhase = phase } }
        }
        Task { await AppUpdateInstaller.shared.prepare(release) }
    }

    func cancelUpdate() { Task { await AppUpdateInstaller.shared.cancel() } }

    /// 重启并安装: hands over to the helper that swaps the app, then quits.
    func installUpdate() async {
        do {
            try await AppUpdateInstaller.shared.installAndRelaunch()
            NSApp.terminate(nil)
        } catch {
            updateMessage = describe(error)
        }
    }

    /// "查看公告" in settings: whatever is current, ignoring mutes.
    func showCurrentAnnouncement() async -> Bool {
        guard let current = await announcements.current() else { return false }
        announcement = current
        return true
    }

    func open(_ summary: SeriesSummary) {
        guard let selection else { return }
        paths[selection, default: []].append(.series(summary))
    }

    /// Opens the search page with `query`, as tapping a tag does in the official app.
    func search(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingSearch = text
        paths[.search] = []
        selection = .search
    }

    /// An actor's page (their works), pushed onto the current column like a series.
    func openCelebrity(_ member: EpisodeSocial.CastMember) {
        guard let selection else { return }
        paths[selection, default: []].append(.celebrity(member))
    }

    func path(for item: SidebarItem) -> Binding<[DetailRoute]> {
        Binding(get: { self.paths[item] ?? [] }, set: { self.paths[item] = $0 })
    }

    func applyTheme() {
        switch settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func rememberSearch(_ keyword: String) {
        var list = settings.searchHistory.filter { $0 != keyword }
        list.insert(keyword, at: 0)
        settings.searchHistory = Array(list.prefix(20))
    }
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

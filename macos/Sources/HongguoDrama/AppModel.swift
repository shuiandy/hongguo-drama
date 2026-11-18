import SwiftUI
import HongguoCore

enum SidebarItem: Hashable, Identifiable {
    case category(CatalogKind)
    case ranking(CatalogKind)
    case search
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
        case .history: return "观看记录"
        case .library: return "我的剧库"
        case .downloads: return "下载"
        case .account: return "账号"
        case .source(let id): return SourceRouter.label(id)
        }
    }

    var symbol: String {
        switch self {
        case .category(.realDrama): return "person.2"
        case .category(.comicDrama): return "paintpalette"
        case .category: return "sparkles"
        case .ranking: return "flame"
        case .search: return "magnifyingglass"
        case .history: return "clock.arrow.circlepath"
        case .library: return "heart"
        case .downloads: return "arrow.down.circle"
        case .account: return "person.crop.circle"
        case .source: return "film.stack"
        }
    }
}

/// App-wide state: services, settings and navigation.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let search = SearchService()
    let catalog = CatalogService()
    let series = SourceRouter.series
    let store = LibraryStore.shared

    var selection: SidebarItem? = .category(.realDrama)
    var paths: [SidebarItem: [SeriesSummary]] = [:]
    var settings: AppSettings {
        didSet { if settings != oldValue { store.settings = settings; applyTheme() } }
    }
    var history: [WatchRecord] = []
    /// Query typed into a page header search field, consumed by the search page.
    var pendingSearch: String?

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
        history = LibraryStore.shared.history()
        downloads = DownloadManager(configuration: Self.downloadConfiguration(settings))
        refreshLibrary()
        library.onChange = { Task { @MainActor in AppModel.shared.refreshLibrary() } }
        Task { await observeDownloads() }
    }

    /// Called once at launch (not from init: PlayerController's init reads AppModel.shared).
    func connectPlayer() {
        PlayerController.shared.localFileProvider = { episode in
            MainActor.assumeIsolated { AppModel.shared.localFiles[episode.vid] }
        }
    }

    static func downloadConfiguration(_ settings: AppSettings) -> DownloadConfiguration {
        var config = DownloadConfiguration(nameFormat: settings.downloadNameFormat, maxConcurrent: settings.maxConcurrentDownloads)
        if let root = settings.downloadRoot, !root.isEmpty { config.root = URL(fileURLWithPath: root, isDirectory: true) }
        return config
    }

    func refreshLibrary() {
        favorites = library.favorites()
        recentSeries = library.recent(limit: 60)
    }

    func isFavorite(_ seriesId: String) -> Bool { favorites.contains { $0.seriesId == seriesId } }

    @discardableResult
    func toggleFavorite(seriesId: String, title: String, cover: String) -> Bool {
        let value = (try? library.toggleFavorite(seriesId: seriesId, title: title, cover: cover)) ?? false
        refreshLibrary()
        return value
    }

    private func observeDownloads() async {
        for await tasks in await downloads.updates() {
            downloadTasks = tasks
            localFiles = Dictionary(tasks.filter { $0.status == .completed }.map { ($0.vid, $0.fileURL) },
                                    uniquingKeysWith: { first, _ in first })
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
            return try await downloads.enqueue(seriesId: seriesId, seriesTitle: title, cover: cover, episodes: episodes)
        } catch {
            PlayerController.shared.show(toast: describe(error))
            return 0
        }
    }

    func refreshHistory() {
        history = store.history()
    }

    private var lastCloudSync = Date.distantPast
    private(set) var cloudSyncing = false
    var cloudSyncMessage = ""

    /// Pulls the signed-in account's cloud watch history into the local history (newer side wins).
    /// The website only exposes reading the cloud history, so local progress is not uploaded.
    func syncCloudHistory(force: Bool = false) async {
        guard !cloudSyncing, force || Date().timeIntervalSince(lastCloudSync) > 60 else { return }
        guard await AccountService.shared.status().profile != nil else { return }
        cloudSyncing = true
        defer { cloudSyncing = false }
        do {
            let items = try await AccountService.shared.history(refresh: true)
            lastCloudSync = Date()
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
        Task { await checkForUpdate(manual: false) }
        Task {
            var first = true
            while !Task.isCancelled {
                if announcement == nil, let next = await announcements.check(urgentOnly: !first) { announcement = next }
                first = false
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await checkWatchUpdates(force: false)
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    /// Checks watched series for new episodes and sequels (only due ones unless forced).
    @discardableResult
    func checkWatchUpdates(force: Bool) async -> WatchUpdateChecker.Summary? {
        guard settings.watchUpdatesEnabled, !watchChecking else { return nil }
        watchChecking = true
        defer { watchChecking = false }
        let summary = await watchChecker.refresh(force: force, includeSequels: settings.watchSequelsEnabled)
        refreshHistory()
        return summary
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

    /// "查看公告" in settings: whatever is current, ignoring mutes.
    func showCurrentAnnouncement() async -> Bool {
        guard let current = await announcements.current() else { return false }
        announcement = current
        return true
    }

    func open(_ summary: SeriesSummary) {
        guard let selection else { return }
        paths[selection, default: []].append(summary)
    }

    func path(for item: SidebarItem) -> Binding<[SeriesSummary]> {
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

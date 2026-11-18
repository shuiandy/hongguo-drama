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

    var id: String {
        switch self {
        case .category(let kind), .ranking(let kind): return kind.rawValue
        case .search: return "search"
        case .history: return "history"
        case .library: return "library"
        case .downloads: return "downloads"
        case .account: return "account"
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
    let series = SeriesService()
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

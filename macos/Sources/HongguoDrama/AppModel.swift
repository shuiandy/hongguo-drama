import SwiftUI
import HongguoCore

enum SidebarItem: Hashable, Identifiable {
    case category(CatalogKind)
    case ranking(CatalogKind)
    case search
    case history

    var id: String {
        switch self {
        case .category(let kind), .ranking(let kind): return kind.rawValue
        case .search: return "search"
        case .history: return "history"
        }
    }

    var title: String {
        switch self {
        case .category(let kind), .ranking(let kind): return kind.label
        case .search: return "搜索"
        case .history: return "观看记录"
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

    private init() {
        settings = LibraryStore.shared.settings
        history = LibraryStore.shared.history()
    }

    func refreshHistory() {
        history = store.history()
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

import AppLogic
import Foundation
import HongguoCore
import HongguoPlayback
import Observation

/// 剧场: a category (真人剧, 漫剧, AI 剧), an optional genre and the paged cover grid. Moved
/// unchanged from the iOS TheaterView: a change of filter clears the grid and only the newest
/// request may write; more pages append without duplicates; a failed refresh keeps what showed.
@MainActor
@Observable
public final class TheaterModel {
    public var kind: CatalogKind = .realDrama {
        didSet {
            guard kind != oldValue else { return }
            genre = nil
            genres = []
        }
    }
    public var genre: GenreChoice?
    public private(set) var genres: [GenreChoice] = []
    public private(set) var items: [SeriesSummary] = []
    public private(set) var page = 1
    public private(set) var totalPages = 1
    public private(set) var phase: LoadPhase = .idle
    public private(set) var requests = PageRequests<String>()
    @ObservationIgnored private let backend: any DramaBackend

    public init(backend: any DramaBackend) {
        self.backend = backend
    }

    /// Changes whenever the category or the genre does; the page reloads on it.
    public var filterKey: String { "\(kind.rawValue)|\(genre?.slug ?? "")" }
    public var hasMore: Bool { page < totalPages }

    public func load(forceRefresh: Bool) async {
        let key = filterKey
        let filterChanged = requests.filter != key
        if filterChanged { items = [] }
        let ticket = requests.reload(key)
        phase = .loading
        page = 1
        totalPages = 1
        do {
            let result = try await backend.catalog(kind: kind, genre: genre?.slug, page: 1, forceRefresh: forceRefresh)
            guard !Task.isCancelled, requests.accepts(ticket, showing: filterKey) else { return }
            items = result.items
            page = result.page
            totalPages = max(result.page, result.totalPages)
            if !result.genres.isEmpty { genres = result.genres }
            phase = .loaded
            CoverPrefetch.prefetch(result.items.map(\.cover))
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, requests.accepts(ticket, showing: filterKey) else { return }
            if filterChanged || items.isEmpty {
                items = []
                phase = .failed(describeError(error))
            } else {
                phase = .loaded
            }
        }
    }

    public func loadMore() async {
        let key = filterKey
        guard page < totalPages, let ticket = requests.beginMore(showing: key) else { return }
        defer { requests.finishMore(ticket) }
        let nextPage = page + 1
        do {
            let result = try await backend.catalog(kind: kind, genre: genre?.slug, page: nextPage, forceRefresh: false)
            guard !Task.isCancelled, requests.accepts(ticket, showing: filterKey), page == nextPage - 1 else { return }
            let existing = Set(items.map(\.seriesId))
            let added = result.items.filter { !existing.contains($0.seriesId) }
            items.append(contentsOf: added)
            page = result.page
            totalPages = added.isEmpty ? result.page : max(result.page, result.totalPages)
            CoverPrefetch.prefetch(added.map(\.cover))
        } catch {
        }
    }
}

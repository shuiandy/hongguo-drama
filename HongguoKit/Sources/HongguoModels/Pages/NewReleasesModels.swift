import AppLogic
import Foundation
import HongguoCore
import HongguoPlayback
import Observation

/// The 上新日历 content filter.
public enum CalendarContentFilter: CaseIterable {
    case all, real, comic

    public var label: String {
        switch self {
        case .all: return "全部"
        case .real: return "真人剧"
        case .comic: return "漫剧"
        }
    }

    public func matches(_ categoryLabel: String) -> Bool {
        switch self {
        case .all: return true
        case .real: return categoryLabel == "真人剧"
        case .comic: return categoryLabel == "漫剧"
        }
    }
}

/// 新剧推荐: the new-drama list for a gender, paged with the service's offset and session. Moved
/// unchanged from the iOS NewReleasesView: a new gender clears the list and only the newest
/// request writes; more pages append without duplicates and stop when the offset no longer
/// advances; offline the sample rows stand in.
@MainActor
@Observable
public final class NewDramaModel {
    public var gender: DiscoveryAccess.NewDramaGender = .all
    public private(set) var items: [DiscoveryAccess.NewDramaItem] = []
    public private(set) var hasMore = false
    public private(set) var nextOffset = 0
    public private(set) var sessionId = ""
    public private(set) var phase: LoadPhase = .idle
    public private(set) var requests = PageRequests<String>()
    @ObservationIgnored private let backend: any DramaBackend

    public init(backend: any DramaBackend) {
        self.backend = backend
    }

    public func load(refresh: Bool = false) async {
        let filterChanged = requests.filter != gender.rawValue
        if filterChanged { items = [] }
        let ticket = requests.reload(gender.rawValue)
        if !refresh || items.isEmpty { phase = .loading }
        if !refresh {
            hasMore = false
            nextOffset = 0
            sessionId = ""
        }
        if backend.isOffline {
            await FixtureDebug.wait()
            let sample = (try? await backend.newReleases()) ?? []
            guard !Task.isCancelled, requests.accepts(ticket, showing: gender.rawValue) else { return }
            items = sample.map {
                DiscoveryAccess.NewDramaItem(
                    seriesId: $0.seriesId, title: FixtureDebug.title($0.title, tab: "新剧推荐"), cover: $0.cover, episodeCount: $0.episodeCount,
                    heatText: $0.heat, badgeText: "新剧", categoryLabel: "", subtitle: $0.episodeLabel, description: $0.description
                )
            }
            phase = .loaded
            return
        }
        do {
            let page = try await DiscoveryAccess.newDramaRecommendations(gender: gender, offset: 0, sessionId: "")
            guard !Task.isCancelled, requests.accepts(ticket, showing: gender.rawValue) else { return }
            items = page.items
            hasMore = page.hasMore
            nextOffset = page.nextOffset
            sessionId = page.sessionId
            phase = .loaded
            CoverPrefetch.prefetch(page.items.map(\.cover))
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, requests.accepts(ticket, showing: gender.rawValue) else { return }
            if filterChanged || items.isEmpty {
                items = []
                phase = .failed(describeError(error))
            } else {
                phase = .loaded
            }
        }
    }

    public func loadMore() async {
        guard hasMore, !backend.isOffline, let ticket = requests.beginMore(showing: gender.rawValue) else { return }
        defer { requests.finishMore(ticket) }
        let offset = nextOffset
        let session = sessionId
        do {
            let page = try await DiscoveryAccess.newDramaRecommendations(gender: gender, offset: offset, sessionId: session)
            guard !Task.isCancelled, requests.accepts(ticket, showing: gender.rawValue), nextOffset == offset && sessionId == session else { return }
            let existing = Set(items.map(\.seriesId))
            let added = page.items.filter { !existing.contains($0.seriesId) }
            items.append(contentsOf: added)
            let advanced = page.nextOffset > offset
            hasMore = page.hasMore && advanced
            if advanced { nextOffset = page.nextOffset }
            if !page.sessionId.isEmpty { sessionId = page.sessionId }
            CoverPrefetch.prefetch(added.map(\.cover))
        } catch {
        }
    }
}

/// 上新日历 (追剧日历): the days around today, the one chosen, a content filter and that day's
/// paged list, with the same rules as 新剧推荐.
@MainActor
@Observable
public final class CalendarModel {
    public private(set) var days: [DiscoveryAccess.CalendarDay] = DiscoveryAccess.calendarDays()
    public var selectedDate: String = DiscoveryAccess.calendarDays().first(where: \.isToday)?.targetDate ?? ""
    public var filter: CalendarContentFilter = .all
    public private(set) var items: [DiscoveryAccess.CalendarItem] = []
    public private(set) var hasMore = false
    public private(set) var nextOffset = 0
    public private(set) var sessionId = ""
    public private(set) var phase: LoadPhase = .idle
    public private(set) var requests = PageRequests<String>()
    @ObservationIgnored private let backend: any DramaBackend

    public init(backend: any DramaBackend) {
        self.backend = backend
    }

    /// The chosen day's rows that pass the filter.
    public var filtered: [DiscoveryAccess.CalendarItem] { items.filter { filter.matches($0.categoryLabel) } }

    public func load(refresh: Bool = false) async {
        let filterChanged = requests.filter != selectedDate
        if filterChanged { items = [] }
        let ticket = requests.reload(selectedDate)
        if !refresh || items.isEmpty { phase = .loading }
        if !refresh {
            hasMore = false
            nextOffset = 0
            sessionId = ""
        }
        if backend.isOffline {
            await FixtureDebug.wait()
            let sample = (try? await backend.newReleases()) ?? []
            guard !Task.isCancelled, requests.accepts(ticket, showing: selectedDate) else { return }
            items = sample.enumerated().map { idx, s in
                DiscoveryAccess.CalendarItem(
                    seriesId: s.seriesId, title: FixtureDebug.title(s.title, tab: selectedDate), cover: s.cover, isOnline: idx % 2 == 0,
                    heatText: idx % 2 == 0 ? s.heat : "120万人预约",
                    categoriesLine: s.tags.joined(separator: "·"), categoryLabel: "",
                    episodeCount: s.episodeCount, description: s.description
                )
            }
            phase = .loaded
            return
        }
        do {
            let page = try await DiscoveryAccess.calendar(targetDate: selectedDate, offset: 0, sessionId: "")
            guard !Task.isCancelled, requests.accepts(ticket, showing: selectedDate) else { return }
            items = page.items
            hasMore = page.hasMore
            nextOffset = page.nextOffset
            sessionId = page.sessionId
            phase = .loaded
            CoverPrefetch.prefetch(page.items.map(\.cover))
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, requests.accepts(ticket, showing: selectedDate) else { return }
            if filterChanged || items.isEmpty {
                items = []
                phase = .failed(describeError(error))
            } else {
                phase = .loaded
            }
        }
    }

    public func loadMore() async {
        guard hasMore, !backend.isOffline, let ticket = requests.beginMore(showing: selectedDate) else { return }
        defer { requests.finishMore(ticket) }
        let offset = nextOffset
        let session = sessionId
        do {
            let page = try await DiscoveryAccess.calendar(
                targetDate: selectedDate,
                offset: offset,
                sessionId: session
            )
            guard !Task.isCancelled, requests.accepts(ticket, showing: selectedDate), nextOffset == offset && sessionId == session else { return }
            let existing = Set(items.map(\.seriesId))
            let added = page.items.filter { !existing.contains($0.seriesId) }
            items.append(contentsOf: added)
            let advanced = page.nextOffset > offset
            hasMore = page.hasMore && advanced
            if advanced { nextOffset = page.nextOffset }
            if !page.sessionId.isEmpty { sessionId = page.sessionId }
            CoverPrefetch.prefetch(added.map(\.cover))
        } catch {
        }
    }
}

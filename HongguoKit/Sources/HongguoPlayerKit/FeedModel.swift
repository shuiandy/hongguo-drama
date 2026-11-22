#if canImport(UIKit)
import AppLogic
import HongguoCore
import HongguoModels
import HongguoPlayback
import Observation
import SwiftUI

public enum FeedTab: String, CaseIterable, Identifiable, Sendable {
    case comic, real, recommend
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .comic: return "漫剧"
        case .real: return "真人剧"
        case .recommend: return "推荐"
        }
    }
}

/// One clip in the feed.
public struct FeedEntry: Sendable {
    public init(series: SeriesSummary, firstVid: String? = nil, commentCount: Int? = nil) {
        self.series = series
        self.firstVid = firstVid
        self.commentCount = commentCount
    }

    public var series: SeriesSummary
    /// Episode 1's video id when the source already knows it; nil means "fetch the episode list".
    public var firstVid: String?
    public var commentCount: Int?
}

public struct FeedPage: Sendable {
    public init(entries: [FeedEntry], next: AppFeedCursor?) {
        self.entries = entries
        self.next = next
    }

    public var entries: [FeedEntry]
    /// Opaque position of the next page; nil when there is no more.
    public var next: AppFeedCursor?
}

/// Where the home feed gets its clips. `BookMallFeedProvider` reads the official recommend
/// feed; `CoreFeedProvider` builds the offline sample page.
public protocol FeedProvider: Sendable {
    func page(for tab: FeedTab, after cursor: AppFeedCursor?) async throws -> FeedPage
    func page(for tab: FeedTab, after cursor: AppFeedCursor?, context: BookMallFeedContext) async throws -> FeedPage
}

extension FeedProvider {
    public func page(for tab: FeedTab, after cursor: AppFeedCursor?, context: BookMallFeedContext) async throws -> FeedPage {
        try await page(for: tab, after: cursor)
    }
}

/// Official recommendation feed via `/reading/bookapi/bookmall/tab/v/` + `/reading/bookapi/bookmall/cell/change/v`.
public struct BookMallFeedProvider: FeedProvider {
    public init() {}

    public func page(for tab: FeedTab, after cursor: AppFeedCursor?) async throws -> FeedPage {
        try await page(for: tab, after: cursor, context: .initial)
    }

    public func page(for tab: FeedTab, after cursor: AppFeedCursor?, context: BookMallFeedContext) async throws -> FeedPage {
        let channel: BookMallFeedChannel = tab == .comic ? .comic : tab == .real ? .liveAction : .recommend
        let page = try await Self.load(channel: channel, cursor: cursor ?? .first, context: context)
        let entries = page.entries.map { FeedEntry(series: $0.series, firstVid: $0.firstVid, commentCount: $0.commentCount) }
        return FeedPage(entries: entries, next: page.next)
    }

    /// Signed in: the account's own feed. Signed out: the anonymous feed.
    private static func load(channel: BookMallFeedChannel, cursor: AppFeedCursor, context: BookMallFeedContext) async throws -> AppFeedPage {
        if AccountDataAccess.hasSavedLogin {
            return try await BookMallFeed.accountPage(channel: channel, cursor: cursor, context: context)
        }
        return try await BookMallFeed.page(channel: channel, cursor: cursor, context: context)
    }
}

/// Ranking + new releases + catalogue, de-duplicated and shuffled per tab. One page only.
public struct CoreFeedProvider: FeedProvider {
    public init(backend: any DramaBackend) {
        self.backend = backend
    }

    public let backend: any DramaBackend

    public func page(for tab: FeedTab, after cursor: AppFeedCursor?) async throws -> FeedPage {
        guard cursor == nil else { return FeedPage(entries: [], next: nil) }
        return FeedPage(entries: try await series(for: tab).map { FeedEntry(series: $0) }, next: nil)
    }

    private func series(for tab: FeedTab) async throws -> [SeriesSummary] {
        var lists: [[SeriesSummary]] = []
        var firstError: Error?
        func add(_ load: () async throws -> [SeriesSummary]) async {
            do { lists.append(try await load()) } catch { firstError = firstError ?? error }
        }
        switch tab {
        case .recommend:
            await add { try await backend.catalog(kind: .hotDrama, genre: nil, page: 1).items }
            await add { try await backend.newReleases() }
            await add { try await backend.catalog(kind: .realDrama, genre: nil, page: 1).items }
        case .real:
            await add { try await backend.catalog(kind: .hotRealDrama, genre: nil, page: 1).items }
            await add { try await backend.catalog(kind: .realDrama, genre: nil, page: 1).items }
        case .comic:
            await add { try await backend.catalog(kind: .hotComicDrama, genre: nil, page: 1).items }
            await add { try await backend.catalog(kind: .comicDrama, genre: nil, page: 1).items }
        }
        if lists.allSatisfy(\.isEmpty), let firstError { throw firstError }
        var byId: [String: SeriesSummary] = [:]
        for item in lists.joined() where byId[item.seriesId] == nil { byId[item.seriesId] = item }
        let order = FeedMixer.mix(lists.map { $0.map(\.seriesId) }, seed: UInt64.random(in: 0...UInt64.max))
        return order.compactMap { byId[$0] }
    }
}

@MainActor
@Observable
public final class FeedModel {
    public enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    /// How many clips ahead of the current one get their source resolved in advance.
    /// Each costs an episode list request plus a source lookup, so this stays small.
    /// The official app keeps the next three clips ready; so does this.
    public static let prefetchDepth = 3

    public var engine: PlayerEngine { app.player }
    @ObservationIgnored private var previousPlayer: PlayerEngine?
    /// The player page has taken over the clip that was playing here.
    public private(set) var handedOff = false
    /// Outer display in landscape: keep playing this clip in a loop instead of moving on.
    public var loopsCurrentClip = false
    public var tab: FeedTab = .recommend
    public private(set) var phase: Phase = .idle
    public private(set) var items: [SeriesSummary] = []
    /// Comment counts and episode 1 ids that came with the feed rows.
    public private(set) var commentCounts: [String: Int] = [:]
    /// Danmaku of the clip that is playing (display only).
    public private(set) var danmaku: [DanmakuItem] = []
    @ObservationIgnored private var danmakuKey = ""
    @ObservationIgnored private var firstVids: [String: String] = [:]
    @ObservationIgnored private var nextCursor: AppFeedCursor?
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var loadMoreGeneration = 0
    @ObservationIgnored private var landingBackfillTask: Task<Void, Never>?
    public private(set) var flow = FeedFlow()
    /// Bound to the paging scroll view.
    public var currentID: String?
    /// Episode lists resolved so far (for 全N集 and episode 1).
    public private(set) var resolved: [String: DramaSeries] = [:]
    public private(set) var synopses: [String: String] = [:]
    public private(set) var unsupported: Set<String> = []
    public private(set) var failed: [String: String] = [:]
    /// Most recently disliked clip, kept briefly for the bottom Undo ("撤销") toast.
    public private(set) var lastDisliked: (tab: FeedTab, item: SeriesSummary, index: Int)?
    @ObservationIgnored private var dislikeUndoTimer: Task<Void, Never>?

    @ObservationIgnored private let app: any PlayerHost
    @ObservationIgnored private let provider: any FeedProvider
    @ObservationIgnored private var cache: [FeedTab: (items: [SeriesSummary], next: AppFeedCursor?, currentID: String?)] = [:]
    @ObservationIgnored private var sessionUuid = UUID().uuidString
    @ObservationIgnored private var channelLoads = ChannelLoads<FeedTab>()
    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var prefetch: Task<Void, Never>?
    @ObservationIgnored private var batchPrefetch: Task<Void, Never>?
    @ObservationIgnored private var unsupportedSkip: Task<Void, Never>?
    @ObservationIgnored private var startedOnce = false
    @ObservationIgnored private var wasPlayingBeforeHide = true
    @ObservationIgnored private var activeFeedAccountId: String?
    @ObservationIgnored private var feedStartedWithSavedLogin = false
    @ObservationIgnored public var isScrolling = false
    // Two slots let A survive when leaving B to swipe back to A. No media is written to disk.
    public private(set) var returnFrames: [(vid: String, image: CGImage)] = []
    @ObservationIgnored private var isVisible = false

    public init(app: any PlayerHost, provider: (any FeedProvider)? = nil) {
        self.app = app
        self.activeFeedAccountId = app.account.profile?.id
        self.feedStartedWithSavedLogin = !app.backend.isOffline && AccountDataAccess.hasSavedLogin
        // Sample mode stays on the built-in rows; live mode uses the official bookmall recommend feed.
        self.provider = provider ?? (app.backend.isOffline ? CoreFeedProvider(backend: app.backend) : BookMallFeedProvider())
        // The player's callbacks are taken when the feed comes on screen (`setVisible`), not
        // here: SwiftUI builds and throws away extra copies of this model whenever the root
        // view is evaluated again, and a discarded copy that had taken the callbacks left the
        // player page with nobody to tell that an episode ended, so the next one never started.
    }

    public var currentItem: SeriesSummary? { items.first { $0.seriesId == currentID } }

    private func requestContext(isRefresh: Bool) -> BookMallFeedContext {
        BookMallFeedContext(
            clientReqType: isRefresh ? 1 : 0,
            sessionUuid: sessionUuid,
            recentImprGids: app.library.recentFeedImprIds,
            forceFilterIds: app.library.feedForceFilterIds
        )
    }

    /// Pulls page 1 and starts playback immediately when at least 1 fresh clip is available,
    /// avoiding 2-3 serial network hops before the first frame. If page 1 is completely stale,
    /// performs up to 2 extra hops before rolling back so the feed never turns blank.
    private func fetchInitialPage(
        for targetTab: FeedTab,
        isRefresh: Bool,
        excluding: Set<String> = [],
        fillTarget: Int = 1
    ) async throws -> (items: [SeriesSummary], next: AppFeedCursor?, needsBackgroundFill: Bool) {
        let context = requestContext(isRefresh: isRefresh)
        let first = try await provider.page(for: targetTab, after: nil, context: context)
        remember(first.entries)
        var raw = first.entries.map(\.series)
        var cursor = first.next

        let seen = app.library.recentFeedSet.union(excluding)
        let disliked = app.library.dislikedSeriesIds
        var fresh = FeedSeenStore.filter(raw, id: \.seriesId, seen: seen, disliked: disliked, allowRollback: false)
        var known = Set(raw.map(\.seriesId))

        var extraHops = 0
        while fresh.count < fillTarget, extraHops < 2, let next = cursor {
            extraHops += 1
            guard let more = try? await provider.page(for: targetTab, after: next, context: context) else { break }
            remember(more.entries)
            let added = more.entries.map(\.series).filter { known.insert($0.seriesId).inserted }
            raw += added
            fresh += FeedSeenStore.filter(added, id: \.seriesId, seen: seen, disliked: disliked, allowRollback: false)
            cursor = more.next
        }

        if !fresh.isEmpty {
            return (fresh, cursor, fresh.count < 4 && cursor != nil)
        }
        // Mirror official `shouldRollbackForEmptyFilterResult:`: keep non-disliked items rather than blanking.
        let rolledBack = FeedSeenStore.filter(raw, id: \.seriesId, seen: excluding, disliked: disliked, allowRollback: true)
        let result = rolledBack.isEmpty ? raw : rolledBack
        return (result, cursor, result.count < 4 && cursor != nil)
    }

    private func fetchFreshBatch(for targetTab: FeedTab, isRefresh: Bool, excluding: Set<String> = []) async throws -> (items: [SeriesSummary], next: AppFeedCursor?) {
        let res = try await fetchInitialPage(for: targetTab, isRefresh: isRefresh, excluding: excluding, fillTarget: 4)
        return (res.items, res.next)
    }

    /// Explicitly refreshes the currently active channel (e.g. tapping the selected channel tab again),
    /// rotating `session_uuid` and sending `client_req_type=1` with recent impression IDs.
    public func refresh() async {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadMoreGeneration += 1
        landingBackfillTask?.cancel()
        landingBackfillTask = nil
        failed.removeAll()
        sessionUuid = UUID().uuidString
        cache[tab] = nil
        await load(force: true, isRefresh: true)
    }

    /// Handles account changes from `FeedView`. Ignores cold-start profile hydration when the
    /// feed was already opened under the same saved login so `LandingCache` and the opening
    /// request are never discarded on launch.
    public func accountDidChange(from oldId: String?, to newId: String?) async {
        guard oldId != newId else { return }
        if oldId == nil, let newId, feedStartedWithSavedLogin, activeFeedAccountId == nil {
            activeFeedAccountId = newId
            return
        }
        activeFeedAccountId = newId
        feedStartedWithSavedLogin = (newId != nil)
        await accountChanged()
    }

    /// Clears all channel caches and reloads the active feed when the signed-in account changes.
    public func accountChanged() async {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadMoreGeneration += 1
        landingBackfillTask?.cancel()
        landingBackfillTask = nil
        cache.removeAll()
        failed.removeAll()
        LandingCache.clear()
        sessionUuid = UUID().uuidString
        await load(force: true, isRefresh: false)
    }

    public func retryCurrentCard() {
        if let id = currentID { failed[id] = nil }
        activate(index: flow.feedIndex)
    }

    public func load(force: Bool = false, isRefresh: Bool = false) async {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadMoreGeneration += 1
        landingBackfillTask?.cancel()
        landingBackfillTask = nil
        if lastDisliked?.tab != tab {
            dislikeUndoTimer?.cancel()
            lastDisliked = nil
        }
        if !force, let cached = cache[tab] {
            show(cached.items, next: cached.next, preferredID: cached.currentID)
            return
        }
        if !force, !app.backend.isOffline, await startFromLanding() { return }
        phase = .loading
        engine.stop()
        // The viewer can switch channels before this answers: the reply belongs to the channel
        // it was asked for, and only reaches the screen while that channel is shown.
        let ticket = channelLoads.begin(tab)
        do {
            let batch = try await fetchInitialPage(for: ticket.channel, isRefresh: isRefresh, fillTarget: 1)
            let outcome = channelLoads.succeeded(ticket, shown: tab)
            guard outcome.show else {
                if outcome.cache {
                    cache[ticket.channel] = (batch.items, batch.next, batch.items.first?.seriesId)
                }
                FeedLog.note("first page for \(ticket.channel.rawValue) landed after a switch: cached=\(outcome.cache)")
                return
            }
            FeedLog.note("first page: \(batch.items.count) rows (refresh=\(isRefresh)), more=\(batch.next != nil)")
            show(batch.items, next: batch.next)
            if batch.needsBackgroundFill, let cursor = batch.next {
                scheduleBackgroundFill(for: ticket.channel, after: cursor, isRefresh: isRefresh)
            }
        } catch {
            // A late failure must not clear the list of the channel now on screen.
            guard channelLoads.failed(ticket, shown: tab) else { return }
            items = []
            phase = .failed(describeError(error))
        }
    }

    /// Tops up a short page-1 feed (< 4 clips) after the opening clip has rendered its first frame
    /// so cold start never stalls behind extra `cell/change/v` round-trips.
    private func scheduleBackgroundFill(for targetTab: FeedTab, after initialCursor: AppFeedCursor, isRefresh: Bool) {
        let gen = loadMoreGeneration
        landingBackfillTask?.cancel()
        landingBackfillTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(1.5)
            while !engine.hasFirstFrame, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, self.loadMoreGeneration == gen, targetTab == tab else { return }
            }
            guard !Task.isCancelled, self.loadMoreGeneration == gen, targetTab == tab,
                  self.loadMoreTask == nil, items.count < 4 else { return }
            let context = requestContext(isRefresh: isRefresh)
            var cursor: AppFeedCursor? = initialCursor
            var known = Set(items.map(\.seriesId))
            let seen = app.library.recentFeedSet
            let disliked = app.library.dislikedSeriesIds
            var appended: [SeriesSummary] = []
            var fallback: [SeriesSummary] = []
            var hops = 0
            while items.count + appended.count < 4, hops < 2, let next = cursor {
                hops += 1
                guard let page = try? await provider.page(for: targetTab, after: next, context: context) else { break }
                guard !Task.isCancelled, self.loadMoreGeneration == gen, targetTab == tab else { return }
                remember(page.entries)
                let newRows = page.entries.map(\.series).filter { known.insert($0.seriesId).inserted }
                let allowed = newRows.filter { !disliked.contains($0.seriesId) }
                fallback += allowed
                appended += allowed.filter { !seen.contains($0.seriesId) }
                cursor = page.next
            }
            guard !Task.isCancelled, self.loadMoreGeneration == gen, targetTab == tab, items.count < 4 else { return }
            let toAdd = appended.isEmpty ? fallback : appended
            guard !toAdd.isEmpty || cursor != initialCursor else { return }
            let hadOnlyOne = items.count <= 1
            items += toAdd
            nextCursor = cursor
            cache[targetTab] = (items, cursor, currentID)
            flow.setFeedCount(items.count)
            FeedLog.note("background fill: +\(toAdd.count) rows, \(items.count) clips, more=\(cursor != nil)")
            if hadOnlyOne, isVisible, flow.feedIndex == 0, items.count > 1 {
                schedulePrefetch(after: 0)
            }
        }
    }

    /// Cold-start instant play: shows ONLY 1 saved placeholder clip (matching official
    /// `SSShortVideoFeedColdPlayManager`), and inserts a freshly deduplicated batch right after it
    /// so swiping to clip #2 immediately enters new recommendations instead of 12 stale clips.
    private func startFromLanding() async -> Bool {
        guard cache[tab] == nil,
              let saved = LandingCache.load(tab: tab.rawValue, accountId: app.account.profile?.id),
              let firstRow = saved.rows.first,
              !app.library.isDisliked(firstRow.series.seriesId) else { return false }
        let requestedTab = tab
        remember([FeedEntry(series: firstRow.series, firstVid: firstRow.firstVid, commentCount: firstRow.commentCount)])
        if let fresh = saved.freshSource(), saved.sourceVid == firstRow.firstVid {
            await EpisodeResolver.shared.seed(fresh.info, expiresAt: fresh.expiresAt, preferredShortSide: saved.sourceShortSide)
        }
        guard requestedTab == tab else { return false }
        FeedLog.note("landing: 1 saved row, source=\(saved.freshSource() != nil)")
        show([firstRow.series], next: nil)
        let ticket = channelLoads.begin(requestedTab)
        landingBackfillTask?.cancel()
        landingBackfillTask = Task { [weak self] in
            guard let self else { return }
            // Let the opening landing clip reach its first frame before spending cold-start
            // sockets/bandwidth on the background recommend-feed refresh (cap at 1.5s).
            let deadline = Date().addingTimeInterval(1.5)
            while !engine.hasFirstFrame, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                if requestedTab != tab { break }
            }
            guard !Task.isCancelled else { return }
            let excluding: Set<String> = [firstRow.series.seriesId]
            guard let batch = try? await fetchFreshBatch(for: requestedTab, isRefresh: false, excluding: excluding),
                  !Task.isCancelled else {
                // If backfill failed after switching away, clear the 1-clip placeholder so returning reloads cleanly.
                if requestedTab != tab, cache[requestedTab]?.items.count == 1, cache[requestedTab]?.next == nil {
                    cache[requestedTab] = nil
                }
                return
            }
            let outcome = channelLoads.succeeded(ticket, shown: tab)
            if !outcome.show {
                if outcome.cache {
                    let combined = [firstRow.series] + batch.items.filter { $0.seriesId != firstRow.series.seriesId }
                    cache[requestedTab] = (combined, batch.next, firstRow.series.seriesId)
                }
                return
            }
            let known = Set(items.map(\.seriesId))
            items += batch.items.filter { !known.contains($0.seriesId) }
            nextCursor = batch.next
            cache[requestedTab] = (items, batch.next, currentID)
            flow.setFeedCount(items.count)
            FeedLog.note("landing: fresh batch behind, \(items.count) clips, more=\(batch.next != nil)")
            // Now that clip #2+ exist behind the landing clip, trigger prefetch/pre-render and
            // save clip #2 into LandingCache with its 5 MiB prefix for the next cold launch.
            if isVisible, flow.feedIndex == 0, items.count > 1 {
                schedulePrefetch(after: 0)
            }
        }
        return true
    }

    /// Writes ONLY the single next upcoming clip for instant cold-start playback on next launch.
    private func saveLanding(after index: Int) async {
        guard !app.backend.isOffline, let nextItem = items[safe: index + 1] else { return }
        let preferred = app.library.settings.preferredQuality
        var saved = LandingCache(savedAt: Date(), tab: tab.rawValue,
                                 rows: [.init(series: nextItem, firstVid: firstVids[nextItem.seriesId], commentCount: commentCounts[nextItem.seriesId])],
                                 accountId: app.account.profile?.id)
        if let vid = firstVids[nextItem.seriesId],
           let meta = await EpisodeResolver.shared.resolvedMeta(vid: vid, preferredShortSide: preferred) {
            saved.source = PlayInfoArchive.encode(meta.info)
            saved.sourceVid = vid
            saved.sourceShortSide = preferred
            saved.sourceSavedAt = Date()
            saved.sourceExpiresAt = meta.expiresAt
        }
        saved.save()
    }

    private func remember(_ entries: [FeedEntry]) {
        for entry in entries {
            if let vid = entry.firstVid { firstVids[entry.series.seriesId] = vid }
            if let count = entry.commentCount { commentCounts[entry.series.seriesId] = count }
        }
    }

    private func show(_ list: [SeriesSummary], next: AppFeedCursor?, preferredID: String? = nil) {
        let filtered = list.filter { !app.library.isDisliked($0.seriesId) }
        let display = filtered.isEmpty ? list : filtered
        items = display
        nextCursor = next
        let startIdx = preferredID.flatMap { id in display.firstIndex { $0.seriesId == id } } ?? 0
        let targetID = display[safe: startIdx]?.seriesId
        cache[tab] = (display, next, targetID)
        flow = FeedFlow(feedCount: display.count)
        if startIdx > 0 { _ = flow.userPaged(to: startIdx) }
        phase = .loaded
        currentID = targetID
        activate(index: startIdx)
    }

    /// Appends the next page when only a few clips are left, filtering out recently seen/disliked
    /// items and continuing up to 2 hops if a page is heavily duplicated.
    private func loadMoreIfNeeded() {
        guard flow.needsMoreItems, loadMoreTask == nil, let initialCursor = nextCursor else { return }
        let requestedTab = tab
        let gen = loadMoreGeneration
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.loadMoreGeneration == gen { self.loadMoreTask = nil }
            }
            let context = requestContext(isRefresh: false)
            var cursor: AppFeedCursor? = initialCursor
            var collected: [SeriesSummary] = []
            var fallbackAllowed: [SeriesSummary] = []
            var known = Set(items.map(\.seriesId))
            let seen = app.library.recentFeedSet
            let disliked = app.library.dislikedSeriesIds
            var hops = 0

            while collected.count < 4, hops < 2, let next = cursor {
                hops += 1
                guard let page = try? await provider.page(for: requestedTab, after: next, context: context) else {
                    break
                }
                guard !Task.isCancelled, self.loadMoreGeneration == gen, requestedTab == tab else { return }
                remember(page.entries)
                let newRows = page.entries.map(\.series).filter { known.insert($0.seriesId).inserted }
                let allowed = newRows.filter { !disliked.contains($0.seriesId) }
                fallbackAllowed += allowed
                collected += allowed.filter { !seen.contains($0.seriesId) }
                cursor = page.next
            }

            guard !Task.isCancelled, self.loadMoreGeneration == gen, requestedTab == tab else { return }
            let toAppend = collected.isEmpty ? fallbackAllowed : collected
            guard !toAppend.isEmpty || cursor != initialCursor else { return }
            items += toAppend
            nextCursor = cursor
            cache[requestedTab] = (items, cursor, currentID)
            flow.setFeedCount(items.count)
            FeedLog.note("page appended: +\(toAppend.count) rows (hops=\(hops)), \(items.count) clips, more=\(cursor != nil)")
        }
    }

    /// Marks `seriesId` as "不感兴趣", removes it from the current feed, advances immediately
    /// to the next clip, and exposes a 4-second Undo window.
    public func dislike(seriesId: String, alreadyReported: Bool = false) {
        if !alreadyReported {
            app.library.markNotInterested(seriesId: seriesId)
        }
        dislikeUndoTimer?.cancel()
        guard let idx = items.firstIndex(where: { $0.seriesId == seriesId }) else { return }
        let removed = items.remove(at: idx)
        lastDisliked = (tab, removed, idx)
        cache[tab] = (items, nextCursor, items[safe: min(idx, max(0, items.count - 1))]?.seriesId)
        flow.setFeedCount(items.count)

        if items.isEmpty {
            currentID = nil
            engine.stop()
            Task { await load(force: true) }
        } else {
            let nextIdx = min(idx, items.count - 1)
            let target = items[nextIdx]
            currentID = target.seriesId
            if case .showFeedItem(let flowIndex) = flow.userPaged(to: nextIdx) {
                activate(index: flowIndex)
            } else {
                activate(index: nextIdx)
            }
            loadMoreIfNeeded()
        }

        dislikeUndoTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.lastDisliked = nil
        }
    }

    /// Reverses the most recent "不感兴趣" action and jumps back to the restored clip.
    public func undoLastDislike() {
        dislikeUndoTimer?.cancel()
        dislikeUndoTimer = nil
        guard let saved = lastDisliked else { return }
        lastDisliked = nil
        app.library.undoNotInterested(seriesId: saved.item.seriesId)
        guard saved.tab == tab else {
            if var cached = cache[saved.tab], !cached.items.contains(where: { $0.seriesId == saved.item.seriesId }) {
                cached.items.insert(saved.item, at: min(saved.index, cached.items.count))
                cache[saved.tab] = cached
            }
            return
        }
        guard !items.contains(where: { $0.seriesId == saved.item.seriesId }) else { return }
        let insertIdx = min(saved.index, items.count)
        items.insert(saved.item, at: insertIdx)
        cache[tab] = (items, nextCursor, saved.item.seriesId)
        flow.setFeedCount(items.count)
        currentID = saved.item.seriesId
        if case .showFeedItem(let flowIndex) = flow.userPaged(to: insertIdx) {
            activate(index: flowIndex)
        } else {
            activate(index: insertIdx)
        }
    }

    // MARK: Paging

    /// The scroll view settled on another page.
    public func pageChanged(to id: String?) {
        guard let id, let index = items.firstIndex(where: { $0.seriesId == id }) else { return }
        cache[tab] = (items, nextCursor, id)
        if case .showFeedItem(let target) = flow.userPaged(to: index) { activate(index: target) }
    }

    private func takeEngine() {
        engine.activeOwner = self
        if engine.rate != 1 { engine.rate = 1 }
        engine.onEnded = { [weak self] in self?.clipEnded() }
        engine.onUnsupported = { [weak self] in self?.currentUnsupported() }
    }

    /// Episode 1 of a feed item, when it is already known without a request.
    public func knownFirstVid(of seriesId: String) -> String? {
        firstVids[seriesId] ?? resolved[seriesId]?.episodes.first?.vid
    }

    /// The episode a card is on. Episode 1 until the player page was left on a later one; from
    /// then the card shows and plays that episode.
    public private(set) var cardEpisodes: [String: PlayerHandoff] = [:]

    /// Where the card's clip was when the feed was covered (观看完整剧集, another screen). If the
    /// player page then plays something else, coming back reloads the clip, from its parked
    /// player when there is one, and must go on from here: loading it at 0 made the parked
    /// player seek back to the start while its last frame stayed up (a frozen picture, then the
    /// clip again from the beginning). Used by the next activation only.
    private var returnPosition: (vid: String, time: Double)?

    public func episodeNumber(of seriesId: String) -> Int { cardEpisodes[seriesId]?.episode ?? 1 }

    /// The episode id the card plays, when known without a request.
    public func knownClipVid(of seriesId: String) -> String? {
        cardEpisodes[seriesId]?.vid ?? knownFirstVid(of: seriesId)
    }

    private func activate(index: Int, outgoingFinished: Bool = false) {
        if let incoming = items[safe: index], let incomingVid = knownClipVid(of: incoming.seriesId) {
            EpisodeResolver.shared.markForegroundTarget(vid: incomingVid, preferredShortSide: app.library.settings.preferredQuality)
        }
        activation?.cancel()
        prefetch?.cancel()
        batchPrefetch?.cancel()
        unsupportedSkip?.cancel()
        loadMoreIfNeeded()
        // Not on screen: the player belongs to whoever covers the feed (the player page), so leave
        // it alone. Stopping it here cut off the player page's clip when the feed finished loading
        // its first page underneath.
        guard isVisible else { return }
        // Kept until a load uses it: the feed can activate more than once on its way back
        // (the earlier activation's task is cancelled), and the last one must still see it.
        let resume = returnPosition
        guard let item = items[safe: index] else { engine.stop(); return }
        failed[item.seriesId] = nil
        app.library.recordFeedImpression(item.seriesId)
        cache[tab] = (items, nextCursor, item.seriesId)
        schedulePrefetch(after: index)
        // Already on this clip (a rotation, a fold, or coming back from the player page):
        // keep the player as it is, preserving an intentional pause.
        if let vid = knownClipVid(of: item.seriesId), engine.currentVid == vid, [.ready, .loading, .offline].contains(engine.phase) {
            returnPosition = nil
            let shouldPlay = wasPlayingBeforeHide
            wasPlayingBeforeHide = true
            if shouldPlay { engine.play() }
            engine.refreshSurface()
            loadDanmakuIfWanted()
            return
        }
        wasPlayingBeforeHide = true
        danmakuKey = ""
        danmaku = []
        if !outgoingFinished { recordFeedHistory(finished: false) }
        if let vid = engine.currentVid, let image = engine.departingFrame() {
            FeedLog.swipe("saved vid=\(vid)")
            returnFrames.removeAll { $0.vid == vid }
            returnFrames.insert((vid, image), at: 0)
            if returnFrames.count > 2 { returnFrames.removeLast() }
        }
        if switchFeedPlayer(to: knownClipVid(of: item.seriesId)) {
            FeedLog.swipe("resume card=\(item.seriesId) time=\(engine.player.currentTime().seconds)")
            engine.play()
            loadDanmakuIfWanted()
            return
        }
        activation = Task {
            // Debounce cold requests only while the pager is actively scrolling; settled transitions
            // and pre-rendered warm items start immediately without paying 250ms (Codex #12).
            let warm = knownClipVid(of: item.seriesId).map {
                engine.hasWarmItem(vid: $0, preferredShortSide: app.library.settings.preferredQuality)
            } ?? false
            if startedOnce && !warm && isScrolling {
                let deadline = Date().addingTimeInterval(0.25)
                while isScrolling, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(25))
                    guard !Task.isCancelled else { return }
                }
            }
            startedOnce = true
            guard !Task.isCancelled else { return }
            do {
                let firstVid = try await clipEpisode(of: item.seriesId)
                // The player page or another tab may have covered the feed while this was loading.
                guard !Task.isCancelled, isVisible, let firstVid else { return }
                if app.backend.isOffline {
                    engine.loadOffline(vid: firstVid)
                } else {
                    FeedLog.swipe("load card=\(item.seriesId) warm=\(warm)")
                    // Back on the clip the feed left: on from where it was, not from 0.
                    let startAt = resume.flatMap { $0.vid == firstVid ? $0.time : nil } ?? 0
                    returnPosition = nil
                    if startAt > 0 { PlaybackLog.note("feed return vid=\(firstVid.suffix(6)) at=\(Int(startAt))") }
                    engine.load(vid: firstVid, seriesId: item.seriesId, startAt: startAt,
                                preferredShortSide: app.library.settings.preferredQuality)
                }
                loadDanmakuIfWanted()
                if synopses[item.seriesId] == nil {
                    synopses[item.seriesId] = item.description.isEmpty
                        ? ((try? await app.backend.synopsis(seriesId: item.seriesId)) ?? "")
                        : item.description
                }
            } catch is CancellationError {
            } catch {
                failed[item.seriesId] = describeError(error)
            }
        }
    }

    /// Keep just the last playable card attached to its decoder. Its clock stays paused
    /// while the foreground player loads the next card.
    private func switchFeedPlayer(to vid: String?) -> Bool {
        let outgoing = engine
        let preferred = app.library.settings.preferredQuality
        let resume = vid != nil && previousPlayer?.currentVid == vid &&
            previousPlayer?.canResumeFeedClip(preferredQuality: preferred) == true
        let keepOutgoing = outgoing.canResumeFeedClip(preferredQuality: preferred)
        guard !outgoing.isPictureInPictureActive,
              !outgoing.isExternalPlaybackActive, !outgoing.isCastStreamActive,
              resume || keepOutgoing else {
            outgoing.stop()
            return false
        }

        // A new engine gets the same hooks as the one it takes over from.
        let incoming = previousPlayer ?? PlayerEngine(hooks: outgoing.hooks)
        if !resume { incoming.stop() }
        if keepOutgoing {
            outgoing.parkFeedClip()
            previousPlayer = outgoing
        } else {
            outgoing.stop()
            previousPlayer = nil
        }
        incoming.takeFeedSettingsAndWarmItems(from: outgoing)
        app.player = incoming
        takeEngine()
        return resume
    }

    /// Loads the playing clip's danmaku when the switch is on. Called when a clip starts and
    /// when the switch is turned on.
    public func loadDanmakuIfWanted() {
        guard app.library.settings.danmaku.enabled, let seriesId = currentID, let vid = engine.currentVid else { return }
        let key = "\(seriesId):\(vid)"
        guard key != danmakuKey else { return }
        danmakuKey = key
        danmaku = []
        Task {
            let items = await app.backend.danmaku(seriesId: seriesId, vid: vid)
            if danmakuKey == key { danmaku = items }
        }
    }

    private func clipEpisode(of seriesId: String) async throws -> String? {
        if let vid = cardEpisodes[seriesId]?.vid { return vid }
        return try await firstEpisode(of: seriesId)
    }

    /// Episode 1's id: from the feed row when it carried one, else from the episode list.
    private func firstEpisode(of seriesId: String) async throws -> String? {
        if let vid = firstVids[seriesId] { return vid }
        return try await resolve(seriesId).episodes.first?.vid
    }

    private func resolve(_ seriesId: String) async throws -> DramaSeries {
        if let hit = resolved[seriesId] { return hit }
        let series = try await app.backend.series(seriesId: seriesId)
        resolved[seriesId] = series
        return series
    }

    /// Start the next card's lookup and pre-render immediately without blocking behind the wider
    /// 6-item batch prefetch (Codex #11). If the user swipes during lookup, the foreground load
    /// joins the resolver's waiter-counted in-flight task.
    private func schedulePrefetch(after index: Int) {
        guard !app.backend.isOffline, Self.prefetchDepth > 0 else { return }
        let upcoming = (1...Self.prefetchDepth).compactMap { items[safe: index + $0] }
        let tailBatchVids = (2...6).compactMap { offset -> String? in
            guard let item = items[safe: index + offset] else { return nil }
            return cardEpisodes[item.seriesId]?.vid ?? firstVids[item.seriesId]
        }
        let preferred = app.library.settings.preferredQuality
        // The card on screen and the next one; a ByteVC2 conversion started ahead for any other
        // card (one the viewer swiped past) gives way.
        let keeping = Set([items[safe: index], items[safe: index + 1]].compactMap { $0.flatMap { knownClipVid(of: $0.seriesId) } }
                          + [engine.currentVid].compactMap { $0 })
        batchPrefetch?.cancel()
        batchPrefetch = nil
        prefetch = Task {
            // Yield resolver and network sockets to the foreground clip until its first frame
            // renders (capped at 4s). Otherwise a cold foreground `engine.load` immediately cancels
            // upcoming[0]'s prefetch (`prefetch cancelled ms=3`), leaving `LandingCache` without a
            // resolved source or 5 MiB disk prefix for the next cold launch.
            let fgDeadline = Date().addingTimeInterval(4.0)
            while !engine.hasFirstFrame, Date() < fgDeadline {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            await engine.hooks.convertedStreams?.yieldAhead(keeping: keeping)
            var startedTailBatch = false
            @MainActor func launchTailBatchIfNeeded() {
                guard !startedTailBatch, !tailBatchVids.isEmpty, !Task.isCancelled else { return }
                startedTailBatch = true
                batchPrefetch?.cancel()
                batchPrefetch = Task {
                    await EpisodeResolver.shared.prefetchBatch(vids: tailBatchVids)
                }
            }
            for (offset, item) in upcoming.enumerated() {
                if offset == 1 { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled else { return }
                guard let vid = try? await clipEpisode(of: item.seriesId) else {
                    if offset == 0 { launchTailBatchIfNeeded() }
                    continue
                }
                guard !Task.isCancelled else { return }
                let prepared = try? await EpisodeResolver.shared.prepare(vid: vid, seriesId: item.seriesId,
                                                                         preferredShortSide: preferred, prefetch: true)
                guard !Task.isCancelled else { return }
                if offset == 0 {
                    // Launch the wider 2...6 batch right after upcoming[0]'s single lookup finishes
                    // so upcoming[0] never waits on the batch AND single/batch never cancel each other.
                    launchTailBatchIfNeeded()
                    await saveLanding(after: index)
                    guard !Task.isCancelled else { return }
                    if let prepared, prepared.info.isByteVC2 {
                        // Converted ahead like the next episode on the player page, so swiping to it
                        // after a moment plays the converted stream without the wait.
                        await engine.hooks.convertedStreams?.prepareAhead(prepared)
                    } else if let prepared {
                        await engine.warmUp(prepared, preferredShortSide: preferred)
                    }
                }
                guard !Task.isCancelled else { return }
                // The converter downloads a ByteVC2 episode whole; its opening is not cached here.
                // For offset == 0 (the next clip and next cold-start LandingCache entry), wait
                // briefly for foreground buffer > 2.5s so its 5 MiB disk prefix is reliably cached
                // instead of being skipped permanently when warmUp finishes early.
                if let prepared, !prepared.info.isByteVC2 {
                    if offset == 0 {
                        let bufferDeadline = Date().addingTimeInterval(3.0)
                        while Date() < bufferDeadline {
                            let readyForPrefix = engine.hasFirstFrame && engine.phase == .ready &&
                                (engine.buffered - engine.currentTime > 2.5 || (engine.duration > 0 && engine.buffered >= engine.duration - 1))
                            if readyForPrefix { break }
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                        }
                        guard !Task.isCancelled else { return }
                        let readyForPrefix = engine.hasFirstFrame && engine.phase == .ready &&
                            (engine.buffered - engine.currentTime > 2.5 || (engine.duration > 0 && engine.buffered >= engine.duration - 1))
                        if readyForPrefix {
                            await MediaPrefixCache.shared.prefetch(prepared)
                        }
                    } else if engine.phase == .ready,
                              engine.buffered - engine.currentTime > 4 || (engine.duration > 0 && engine.buffered >= engine.duration - 1) {
                        await MediaPrefixCache.shared.prefetch(prepared)
                    }
                }
            }
            launchTailBatchIfNeeded()
        }
    }

    private func clipEnded() {
        recordFeedHistory(finished: true)
        if loopsCurrentClip {
            engine.restart()
            return
        }
        switch flow.clipEnded() {
        case .showFeedItem(let index):
            withAnimation { currentID = items[safe: index]?.seriesId }
            activate(index: index, outgoingFinished: true)
        case .replay:
            engine.restart()
        default:
            break
        }
    }

    /// ByteVC2 only: show 此剧集暂不支持 briefly, then move on. Leaving the card cancels the
    /// skip (see `activate`), and it re-checks that the viewer is still on that card and that
    /// it is still unplayable, so it can never skip the card they swiped to.
    private func currentUnsupported() {
        guard let id = currentID, let cardIndex = items.firstIndex(where: { $0.seriesId == id }) else { return }
        unsupported.insert(id)
        let vid = engine.currentVid
        unsupportedSkip?.cancel()
        unsupportedSkip = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, isVisible, currentID == id, engine.currentVid == vid, engine.phase == .unsupported,
                  case .showFeedItem(let index) = flow.skipUnplayable(fromFeedItem: cardIndex) else { return }
            withAnimation { currentID = items[safe: index]?.seriesId }
            activate(index: index)
        }
    }

    // MARK: Visibility

    /// The feed is on screen and nothing covers it.
    public func setVisible(_ visible: Bool, pendingDislike: String? = nil) {
        guard visible != isVisible else {
            if visible, let pendingDislike { dislike(seriesId: pendingDislike, alreadyReported: true) }
            return
        }
        isVisible = visible
        if visible {
            let returningFromHandoff = handedOff
            handedOff = false
            // Back from the player page on a later episode of this card's series: the card is
            // on that episode now.
            if let handoff = app.playerHandoff {
                cardEpisodes[handoff.seriesId] = handoff.episode > 1 ? handoff : nil
                app.playerHandoff = nil
            }
            if returningFromHandoff {
                wasPlayingBeforeHide = engine.wantsPlayback
            }
            takeEngine()
            if let pendingDislike {
                dislike(seriesId: pendingDislike, alreadyReported: true)
                return
            }
            // Same clip still loaded: carry on. Anything else (the player page moved to another
            // episode, or another screen used the player): load this clip.
            activate(index: flow.feedIndex)
        } else {
            activation?.cancel()
            prefetch?.cancel()
            batchPrefetch?.cancel()
            unsupportedSkip?.cancel()
            previousPlayer?.stop()
            previousPlayer = nil
            // When the player page continues this clip, the player keeps running untouched.
            guard !handedOff else { return }
            if let vid = engine.currentVid, let item = items[safe: flow.feedIndex], knownClipVid(of: item.seriesId) == vid {
                returnPosition = (vid, max(0, engine.currentTime))
                PlaybackLog.note("feed left vid=\(vid.suffix(6)) at=\(Int(max(0, engine.currentTime)))")
            }
            wasPlayingBeforeHide = engine.wantsPlayback
            recordFeedHistory(finished: false)
            // Otherwise drop a clip that is still being resolved, so it cannot start under
            // whatever covers the feed.
            if engine.phase == .loading { engine.stop() } else { engine.pause() }
        }
    }

    /// 观看完整剧集: the player page takes over the clip that is playing, without loading it again,
    /// unless watch history is already ahead on a later episode (official rule).
    public func watchFullSeries(_ item: SeriesSummary) {
        let clip = knownClipVid(of: item.seriesId)
        let isPlayingIt = clip != nil && engine.currentVid == clip
        handedOff = isPlayingIt
        if isPlayingIt, let clip { returnPosition = (clip, max(0, engine.currentTime)) }
        // Which card the button belonged to against the card the feed thinks is on screen and
        // the clip the player holds: a mismatch here is the page and the feed disagreeing.
        let cardIndex = items.firstIndex { $0.seriesId == item.seriesId } ?? -1
        PlaybackLog.note("watch full card=\(cardIndex) feedIndex=\(flow.feedIndex) clip=\(clip.map { String($0.suffix(6)) } ?? "-") engine=\(engine.currentVid.map { String($0.suffix(6)) } ?? "-") at=\(Int(max(0, engine.currentTime)))")
        app.openPlayer(item, startEpisode: episodeNumber(of: item.seriesId), startAt: isPlayingIt ? engine.currentTime : 0,
                       continuesCurrentClip: isPlayingIt, resumeIfAheadOfCurrentClip: true)
    }

    /// Episode 1 of the clip, for its public comments (read-only).
    public func firstVid(for item: SeriesSummary) async throws -> String? {
        try await firstEpisode(of: item.seriesId)
    }

    /// Saves and syncs watch history for the feed clip that was just watched for at least 3s.
    private func recordFeedHistory(finished: Bool) {
        guard let vid = engine.currentVid, !vid.isEmpty,
              engine.phase == .ready || engine.phase == .offline,
              finished || engine.currentTime >= 3,
              let item = items.first(where: { knownClipVid(of: $0.seriesId) == vid }) else { return }
        let ep = episodeNumber(of: item.seriesId)
        let pos = finished ? 0 : engine.currentTime
        let total = max(item.episodeCount, resolved[item.seriesId]?.total ?? 0)
        app.library.store.savePosition(seriesId: item.seriesId, title: item.title, cover: item.cover, total: total,
                               episodeIndex: ep, vid: vid,
                               position: pos, duration: engine.duration, finished: finished,
                               accountId: app.account.profile?.id)
        app.library.libraryChanged()
        app.library.syncWatchHistory(seriesId: item.seriesId, title: item.title, cover: item.cover, total: total,
                             vid: vid, episodeIndex: ep, position: pos, duration: engine.duration,
                             finished: finished, force: true)
    }
}

/// One line per feed page in Documents/feed-log.txt, next to the playback timings, so a test
/// run can tell from outside whether paging happened.
public enum FeedLog {
    private static let timesSwipes = ProcessInfo.processInfo.arguments.contains("-FeedSwipeTiming")

    public static func swipe(_ event: @autoclosure () -> String) {
        guard timesSwipes else { return }
        note("swipe \(DispatchTime.now().uptimeNanoseconds) \(event())")
    }

    public static func note(_ text: String) {
        guard let directory = PlaybackLog.directory else { return }
        let file = directory.appendingPathComponent("feed-log.txt")
        let line = Data("\(Date().formatted(.iso8601)) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }
}
#endif

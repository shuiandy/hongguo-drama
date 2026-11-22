import Foundation
import HongguoCore
import Observation

/// An actor's page: the home page's works tab, its sub tabs (全部 / 剧作 / 预约 / 合集) and one
/// paged list per sub tab, each read once. Moved unchanged from the iOS CelebrityView. Offline
/// there is no home page. The loaders take the backend, so the page can make the model first.
@MainActor
@Observable
public final class CelebrityModel {
    public let member: EpisodeSocial.CastMember
    public private(set) var home: ActorHome?
    public var selectedSub: Int?
    public private(set) var pages: [Int: ActorWorksPage] = [:]
    public private(set) var loading: Set<Int> = []
    public private(set) var loadingMore: Set<Int> = []
    public private(set) var errors: [Int: String] = [:]
    public private(set) var homeError: String?
    public private(set) var homeLoading = false

    public init(member: EpisodeSocial.CastMember) {
        self.member = member
    }

    public var worksTab: ActorHome.Tab? { home?.worksTab }

    /// The works tab's sub tabs without 剧评 (posts, not series): 全部 / 剧作 / 预约 / 合集 under 7.4.5.32.
    public var subTabs: [ActorHome.Tab] { home?.worksSubTabs ?? [] }

    /// The list being shown: the chosen sub tab, or the works tab itself when it has none.
    public var listKey: Int? { selectedSub ?? (subTabs.isEmpty ? worksTab?.type : nil) }

    public func loadHome(using backend: any DramaBackend, retry: Bool = false) async {
        guard !backend.isOffline else { return }
        let userId = member.profileUserId
        guard !userId.isEmpty, home == nil || retry, !homeLoading else { return }
        homeLoading = true
        homeError = nil
        defer { homeLoading = false }
        do {
            let loaded = try await ActorHomeService.home(userId: userId)
            guard !Task.isCancelled else { return }
            home = loaded
            selectedSub = (loaded.defaultSubTab ?? loaded.worksSubTabs.first)?.type
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            homeError = (error as? HongguoError)?.message ?? "演员主页暂时取不到，请稍后重试"
        }
    }

    /// Reads one list once; a list already read is shown again without a request.
    public func loadList(_ key: Int, using backend: any DramaBackend, retry: Bool = false) async {
        guard !backend.isOffline, let tab = worksTab, pages[key] == nil || retry, !loading.contains(key) else { return }
        loading.insert(key)
        errors[key] = nil
        defer { loading.remove(key) }
        do {
            let page = try await ActorHomeService.works(userId: member.profileUserId, tab: tab.type,
                                                        subTab: key == tab.type ? nil : key)
            guard !Task.isCancelled else { return }
            pages[key] = page
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errors[key] = (error as? HongguoError)?.message ?? "作品暂时取不到，请稍后重试"
        }
    }

    public func loadMore(_ key: Int, using backend: any DramaBackend) async {
        guard !backend.isOffline, let tab = worksTab, let current = pages[key],
              current.hasMore, !current.cursor.isEmpty, !loadingMore.contains(key) else { return }
        let requestedCursor = current.cursor
        loadingMore.insert(key)
        defer { loadingMore.remove(key) }
        do {
            let next = try await ActorHomeService.works(userId: member.profileUserId, tab: tab.type,
                                                        subTab: key == tab.type ? nil : key,
                                                        cursor: requestedCursor)
            guard !Task.isCancelled, var latest = pages[key] else { return }
            latest.append(next, requestedCursor: requestedCursor)
            pages[key] = latest
        } catch {
        }
    }
}

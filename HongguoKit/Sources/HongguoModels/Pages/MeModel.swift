import AppLogic
import Foundation
import HongguoCore
import Observation

/// A content category for 我的's lists.
public enum MeContentCategory: CaseIterable, Sendable {
    case all, real, comic, ai, highlight

    public var label: String {
        switch self {
        case .all: return "全部"
        case .real: return "真人剧"
        case .comic: return "漫剧"
        case .ai: return "AI剧"
        case .highlight: return "高光"
        }
    }

    public func matches(_ category: String) -> Bool {
        switch self {
        case .all: return true
        default: return category == label
        }
    }
}

public enum ReservationTab: CaseIterable, Sendable {
    case online, upcoming

    public var label: String { self == .online ? "已上线" : "待上线" }
}

public enum MeTab: CaseIterable, Sendable {
    case history, favorites, likes, reservations

    public var label: String {
        switch self {
        case .history: return "历史"
        case .favorites: return "收藏"
        case .likes: return "点赞"
        case .reservations: return "预约"
        }
    }
}

/// 我的: the four lists (历史, 收藏, 点赞, 预约) and their filters. Moved unchanged from the iOS
/// MeView's committed code (the iOS view does not use this yet: another thread is changing it).
/// Signed out, the device's own lists show and the category filters do not apply; signed in,
/// the account's lists show, and the account's history joins this device's (the later row per
/// series wins).
@MainActor
@Observable
public final class MeModel {
    public var filter: HistoryProgress.Filter = .all
    public var historyCategory: MeContentCategory = .all
    public var favoriteCategory: MeContentCategory = .all
    public var likeCategory: MeContentCategory = .all
    public var reservationTab: ReservationTab = .online
    public var tab: MeTab = .history
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let account: AccountModel

    public init(library: LibraryModel, account: AccountModel) {
        self.library = library
        self.account = account
    }

    private var signedIn: Bool { account.isSignedIn }

    /// The device's history rows by series, for putting a row back when an account delete fails.
    public var localRecords: [WatchRecord] { library.history() }

    /// 历史: merged, then filtered by progress and (signed in) category.
    public var history: [HistoryEntry] {
        let local = localRecords.map {
            HistoryEntry(seriesId: $0.seriesId, title: $0.title, cover: $0.cover, episodeIndex: $0.episodeIndex, total: $0.total,
                         completedEpisode: $0.completedEpisode, position: $0.position, updatedAt: $0.updatedAt, fromAccount: false)
        }
        let activeHistoryCategory: MeContentCategory = signedIn ? historyCategory : .all
        let accountHistory = signedIn ? account.history : []
        return HistoryMerge.merge(local: local, account: accountHistory).filter {
            HistoryProgress.matches(filter, completedEpisode: $0.completedEpisode, total: $0.total)
                && activeHistoryCategory.matches($0.category)
        }
    }

    /// 收藏 on this device (signed out only).
    public var localFavorites: [LibrarySeries] { signedIn ? [] : library.favorites() }

    /// 收藏 on the account, filtered by category.
    public var accountShelf: [AccountModel.ShelfSeries] {
        let activeFavoriteCategory: MeContentCategory = signedIn ? favoriteCategory : .all
        return (signedIn ? account.shelf : []).filter { activeFavoriteCategory.matches($0.category) }
    }

    /// 点赞: this device's (signed out) or the account's (signed in, by category).
    public var likes: LikeMerge.Merged<LibrarySeries, AccountModel.LikedSeries> {
        let activeLikeCategory: MeContentCategory = signedIn ? likeCategory : .all
        let merged: LikeMerge.Merged<LibrarySeries, AccountModel.LikedSeries> = LikeMerge.merge(
            local: signedIn ? [] : library.likedSeries(), account: signedIn ? account.likes : [],
            localSeries: \.seriesId,
            accountSeries: \.seriesId, accountVid: \.vid, accountEpisode: \.episodeIndex, accountCategory: \.category,
            categories: [:], selected: activeLikeCategory == .all ? nil : activeLikeCategory.label)
        return merged
    }

    /// 预约 on this device (signed out only).
    public var localReservations: [LibraryModel.LocalReservation] { signedIn ? [] : library.reservations() }
    /// The account's reservations already out.
    public var onlineReservations: [AccountModel.ReservedSeries] { (signedIn ? account.reservations : []).filter(\.isOnline) }
    /// The account's reservations not out yet.
    public var upcomingReservations: [AccountModel.ReservedSeries] { (signedIn ? account.reservations : []).filter { !$0.isOnline } }
    public var upcomingCount: Int { localReservations.count + upcomingReservations.count }

    /// 删除记录 (moved from the iOS MeView's committed code): the device's row goes at once;
    /// signed in, the account delete is queued for the series like every other account write,
    /// and if it fails the device's row comes back.
    public func deleteHistory(_ record: HistoryEntry) {
        let removedLocal = localRecords.first { $0.seriesId == record.seriesId }
        if removedLocal != nil {
            library.store.removeHistory(record.seriesId)
            library.libraryChanged()
        }
        if account.isSignedIn {
            let library = library
            account.enqueue(.history(record.seriesId)) { account in
                let ok = await account.deleteHistory(seriesId: record.seriesId,
                                                     vid: removedLocal?.vid ?? "",
                                                     episodeIndex: record.episodeIndex)
                if !ok, let prev = removedLocal {
                    library.store.savePosition(seriesId: prev.seriesId, title: prev.title, cover: prev.cover,
                                               total: prev.total, episodeIndex: prev.episodeIndex, vid: prev.vid,
                                               position: prev.position, duration: prev.duration,
                                               finished: prev.completedEpisode >= prev.episodeIndex && prev.position <= 0,
                                               accountId: prev.cloudAccountId)
                    library.libraryChanged()
                }
            }
        }
    }
}

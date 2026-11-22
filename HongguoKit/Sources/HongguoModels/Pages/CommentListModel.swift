import AppLogic
import Foundation
import HongguoCore
import HongguoPlayback
import Observation

/// One episode's public comments, read only: the first batch with the total, further pages by
/// cursor (no duplicates; a failed page offers a retry), and each comment's replies expanded and
/// paged (CommentReplyThread). Moved unchanged from the iOS CommentList. Another episode drops
/// what was shown, and replies from a previous episode never land.
@MainActor
@Observable
public final class CommentListModel {
    public private(set) var comments: [EpisodeSocial.Comment] = []
    public private(set) var total: Int?
    public private(set) var nextCursor = ""
    public private(set) var hasMore = false
    public private(set) var pages = PageRequests<String>()
    public private(set) var loadTicket = 0
    public private(set) var retryPage = false
    public private(set) var phase: LoadPhase = .loading
    public private(set) var replyThreads: [String: CommentReplyThread<EpisodeSocial.Reply>] = [:]
    @ObservationIgnored private var seriesId = ""
    @ObservationIgnored private var vid = ""
    @ObservationIgnored private var backend: (any DramaBackend)?

    public init() {}

    public func collapseReplies(of commentId: String) { replyThreads[commentId]?.collapse() }

    /// Loads the episode's first comments (and its total), dropping what another episode showed.
    @discardableResult
    public func load(seriesId: String, vid: String, using backend: any DramaBackend) async -> Int? {
        self.seriesId = seriesId
        self.vid = vid
        self.backend = backend

        let ticket = pages.reload(vid)
        loadTicket = ticket
        replyThreads = [:]
        retryPage = false
        phase = .loading
        nextCursor = ""
        hasMore = false
        do {
            let social = try await backend.social(seriesId: seriesId, vid: vid)
            guard !Task.isCancelled, pages.accepts(ticket, showing: vid) else { return nil }
            comments = social.comments
            total = social.commentTotal
            nextCursor = social.nextCursor
            hasMore = social.hasMoreComments && !backend.isOffline
            phase = .loaded
            return social.commentTotal ?? social.comments.count
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, pages.accepts(ticket, showing: vid) else { return nil }
            phase = .failed(describeError(error))
        }
        return nil
    }

    public func loadReplies(for comment: EpisodeSocial.Comment) async {
        var thread = replyThreads[comment.id] ?? CommentReplyThread(reportedCount: comment.replyCount)
        guard let cursor = thread.beginExpandOrLoadMore() else {
            replyThreads[comment.id] = thread
            return
        }
        let pageSize = thread.replies.isEmpty ? 5 : 10
        replyThreads[comment.id] = thread
        let ticket = loadTicket
        let requestedVid = vid
        guard let backend else { return }
        do {
            let page = try await backend.commentReplies(
                seriesId: seriesId,
                vid: requestedVid,
                commentId: comment.id,
                cursor: cursor,
                count: pageSize
            )
            guard !Task.isCancelled, pages.accepts(ticket, showing: requestedVid) else { return }
            var current = replyThreads[comment.id] ?? thread
            current.applyPage(
                page.replies,
                total: page.total,
                nextCursor: page.cursor,
                hasMore: page.hasMore,
                requestedCursor: cursor
            )
            replyThreads[comment.id] = current
        } catch is CancellationError {
            if pages.accepts(ticket, showing: requestedVid) {
                replyThreads[comment.id]?.fail()
            }
        } catch {
            if pages.accepts(ticket, showing: requestedVid) {
                replyThreads[comment.id]?.fail()
            }
        }
    }

    public func loadMore() async {
        guard hasMore, !nextCursor.isEmpty, let ticket = pages.beginMore(showing: vid) else { return }
        defer { pages.finishMore(ticket) }
        guard let backend else { return }
        let cursor = nextCursor
        do {
            let page = try await backend.commentsPage(seriesId: seriesId, vid: vid, cursor: cursor)
            guard !Task.isCancelled, pages.accepts(ticket, showing: vid), nextCursor == cursor else { return }
            var existing = Set(comments.map(\.id))
            comments += page.comments.filter { existing.insert($0.id).inserted }
            if let t = page.total { total = t }
            nextCursor = page.cursor
            hasMore = page.hasMore && !page.cursor.isEmpty && page.cursor != cursor
            retryPage = false
        } catch {
            if !Task.isCancelled, pages.accepts(ticket, showing: vid) { retryPage = true }
        }
    }
}

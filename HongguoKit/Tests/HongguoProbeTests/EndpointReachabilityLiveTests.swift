// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore
@testable import HongguoPlayback

/// `HONGGUO_LIVE=1 swift test --filter EndpointReachabilityLiveTests`: every Hongguo endpoint the
/// kit reads without a login, once, through the same code the apps use, and whether the answer is
/// usable (code 0 and something in it). Read-only except one QR login ticket, which expires unused.
/// Account endpoints need the app's saved login and are checked in the app.
final class EndpointReachabilityLiveTests: XCTestCase {
    private struct NoStore: AccountCredentialStore {
        func load() throws -> AccountCredentials? { nil }
        func save(_ value: AccountCredentials) throws {}
        func clear() throws {}
    }

    func testEveryAnonymousEndpoint() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var lines: [String] = [], failures: [String] = []
        func check(_ name: String, _ body: () async throws -> String) async {
            do { lines.append("OK   \(name): \(try await body())") }
            catch { lines.append("FAIL \(name): \(error)"); failures.append(name) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        func need(_ ok: Bool, _ what: String) throws { if !ok { throw HongguoError(.upstream, "empty: \(what)") } }
        let transport = AppTransport(http: .shared)

        await check("device_register + app_alert_check (renew)") {
            let r = try await PersistentAppDevice.shared.refreshForRecovery(transport: transport)
            let token = await PersistentAppDevice.shared.dTokenValue()
            try need(r.refreshed && !token.isEmpty, "token")
            return "renewed, token issued"
        }
        var sid = "", vid = ""
        await check("search/tab/v (search)") {
            let p = try await AppSearchService().search("家里家外"); sid = p.results.first?.seriesId ?? ""
            try need(!p.results.isEmpty, "results"); return "\(p.results.count) results"
        }
        await check("search/suggest/v (suggestions)") {
            let s = await DiscoveryAccess.searchSuggestions(query: "家里")
            try need(!s.isEmpty, "suggestions")
            return "\(s.count): \(s.prefix(3).joined(separator: "、"))"
        }
        await check("search/cue/v1 (search cues)") {
            let cues = try await DiscoveryAccess.searchCues()
            try need(!cues.isEmpty, "cues")
            return "\(cues.count): \(cues.prefix(3).joined(separator: "、"))"
        }
        await check("plan/v (search_input_page: 猜你想搜 & 热点话题榜)") {
            let landing = try await DiscoveryAccess.searchLanding()
            try need(!landing.hotTopics.isEmpty, "hotTopics")
            return "\(landing.hotTopics.count) topics, \(landing.guessItems.count) guesses"
        }
        await check("video_tab/multi_video_detail (detail)") {
            let d = try await OfficialSeriesDetail.load(sid, force: true); vid = d.episodes.first?.vid ?? ""
            try need(!d.episodes.isEmpty, "episodes"); return "\(d.episodes.count) eps"
        }
        // The V2 scene path (`/multi_video_model/player/v1/`) answers empty on both hosts and is not used.
        for (name, base) in [("multi_video_model/v1 (play)", AppSource.playerAPI)] {
            await check(name) {
                let identity = try await PersistentAppDevice.shared.get(transport: transport)
                let dToken = await PersistentAppDevice.shared.dTokenHeaders()
                let req = try AppSource.modelRequest(base: base, payload: try AppSource.modelPayload(vids: [vid]), identity: identity)
                let json = try await transport.requestJSON(req.url, method: "POST", headers: req.headers + dToken, body: req.body,
                                                           deadline: Date().addingTimeInterval(10))
                let data = json["data"]["1004"].isNull ? json["data"] : json["data"]["1004"]
                try need(Int(json["code"].number ?? -1) == 0 && data[vid]["video_model"].string != nil, "video_model code=\(json["code"].number ?? -1)")
                return "video_model present"
            }
        }
        await check("album_detail (collection)") {
            let d = try await OfficialAlbumDetail.load("7695396523919559704"); try need((d?.episodes.count ?? 0) > 1, "album"); return "\(d!.episodes.count) eps"
        }
        var rankCursor: DiscoveryAccess.RankCursor?
        await check("plan/v (ranking)") {
            let r = try await DiscoveryAccess.ranking(); rankCursor = r.cursor
            try need(!r.items.isEmpty, "items"); return "\(r.items.count) items, more=\(r.hasMore)"
        }
        await check("bookmall/cell/change/v (ranking page 2)") {
            guard let c = rankCursor else { throw HongguoError(.upstream, "no cursor from page 1") }
            let r = try await DiscoveryAccess.rankingMore(cursor: c, selectedItem: "all", subSelectedItem: "ranklist_hot_sc")
            try need(!r.items.isEmpty, "items"); return "\(r.items.count) items"
        }
        await check("plan/v (same IP)") {
            let r = try await DiscoveryAccess.sameIPSeries(seriesId: sid); return "\(r.items.count) items (0 is fine for a series without seasons)"
        }
        await check("plan/v (series recommend)") {
            let r = try await DiscoveryAccess.seriesRecommend(seriesId: sid)
            try need(!r.items.isEmpty, "recommend items")
            return "\(r.cellTitle): \(r.items.count) items"
        }
        await check("subscribe/list (calendar)") {
            let days = DiscoveryAccess.calendarDays()
            let r = try await DiscoveryAccess.calendar(targetDate: days.first { $0.isToday }?.targetDate ?? "")
            try need(!r.items.isEmpty, "items"); return "\(r.items.count) items"
        }
        await check("category/landpage (new dramas)") {
            let r = try await DiscoveryAccess.newDramaRecommendations(); try need(!r.items.isEmpty, "items"); return "\(r.items.count) items"
        }
        for kind in CatalogKind.allCases {
            await check("category/landpage (catalogue \(kind.rawValue))") {
                let r = try await DiscoveryAccess.catalog(kind: kind, forceRefresh: true); try need(!r.items.isEmpty, "items"); return "\(r.items.count) items"
            }
        }
        for channel in BookMallFeedChannel.allCases {
            await check("bookmall/tab/v + cell/change/v (feed \(channel.rawValue))") {
                let first = try await BookMallFeed.page(channel: channel)
                // Signed out, 推荐's first cell is three cards that are often all creator posts
                // (content_type 1001/1002), which the feed leaves out.
                if channel != .recommend { try need(!first.entries.isEmpty, "page 1") }
                guard let next = first.next else { return "\(first.entries.count) entries, no page 2" }
                let second = try await BookMallFeed.page(channel: channel, cursor: next)
                try need(!second.entries.isEmpty, "page 2")
                return "\(first.entries.count) + \(second.entries.count) entries"
            }
        }
        var commentId = ""
        await check("commentapi/comment/list/<vid> (comments)") {
            let p = try await EpisodeSocialService.commentsPage(seriesId: sid, vid: vid)
            commentId = p.comments.first { $0.replyCount > 0 }?.id ?? ""
            try need(!p.comments.isEmpty, "comments"); return "\(p.comments.count)"
        }
        await check("commentapi/reply/list (replies)") {
            let p = try await EpisodeSocialService.repliesPage(seriesId: sid, vid: vid, commentId: commentId)
            try need(!p.replies.isEmpty, "replies"); return "\(p.replies.count)"
        }
        await check("commentapi/comment/list/<series> (reviews)") {
            let r = try await EpisodeSocialService.reviews(seriesId: sid); try need(!r.reviews.isEmpty, "reviews"); return "\(r.reviews.count), rating \(r.rating ?? -1)"
        }
        await check("book_pack_fields (first shown, likes)") {
            let s = try await EpisodeSocialService.load(seriesId: sid, vid: vid); try need(s.firstShown != nil, "firstShown"); return "ok"
        }
        await check("commentapi/user/profile (actor home + works)") {
            let d = try await OfficialSeriesDetail.load(sid)
            guard let actor = d.cast.first(where: { !$0.profileUserId.isEmpty })?.profileUserId else { throw HongguoError(.upstream, "no actor") }
            let h = try await ActorHomeService.home(userId: actor)
            guard let tab = h.worksTab, let sub = tab.subTabs.first else { throw HongguoError(.upstream, "no works tab") }
            let w = try await ActorHomeService.works(userId: actor, tab: tab.type, subTab: sub.type)
            try need(!w.items.isEmpty, "works"); return "\(tab.name)›\(sub.name) \(w.items.count)"
        }
        await check("danmaku") {
            let r = await DanmakuService.shared.fetch(seriesId: sid, vid: vid, fresh: true)
            try need(r.success && !r.items.isEmpty, "items"); return "\(r.items.count)"
        }
        await check("passport/web/get_qrcode (QR login)") {
            let qr = try await AccountService(store: NoStore()).startLogin()
            try need(!qr.image.isEmpty, "image"); return "QR \(qr.image.count) bytes, expires in \(qr.expiresIn)s"
        }
        print("REACH\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(failures, [])
    }
}

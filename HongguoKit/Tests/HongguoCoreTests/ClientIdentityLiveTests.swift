// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `HONGGUO_LIVE=1 swift test --filter ClientIdentityLiveTests`: one read through every signed
/// family (search, catalogue, ranking, detail, play, comments, replies, reviews, stats, actor home,
/// danmaku), so a change of client version or profile is checked against all of them at once.
/// Read-only, signed out. Prints one line per family.
final class ClientIdentityLiveTests: XCTestCase {
    func testEveryFamily() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var lines: [String] = []
        var failures: [String] = []
        func step(_ name: String, _ body: () async throws -> String) async {
            do { lines.append("OK   \(name): \(try await body())") }
            catch { lines.append("FAIL \(name): \(error)"); failures.append(name) }
            try? await Task.sleep(for: .milliseconds(600))
        }
        var sid = "", vid = "", actor = ""
        await step("search") {
            let page = try await AppSearchService().search("家里家外")
            sid = page.results.first?.seriesId ?? ""
            return "\(page.results.count) results, first \(page.results.first?.title ?? "-")"
        }
        await step("detail") {
            let d = try await OfficialSeriesDetail.load(sid, force: true)
            vid = d.episodes.first?.vid ?? ""
            actor = d.cast.first { !$0.profileUserId.isEmpty }?.profileUserId ?? ""
            return "\(d.title) eps=\(d.episodes.count) cast=\(d.cast.count)"
        }
        await step("play") {
            let info = try await SeriesService().playInfo(vid: vid, seriesId: sid, force: true)
            return "codec=\(info.codec)"
        }
        await step("catalogue real-drama") {
            let r = try await DiscoveryAccess.catalog(kind: .realDrama, forceRefresh: true)
            return "\(r.items.count) items"
        }
        await step("ranking") {
            let r = try await DiscoveryAccess.ranking()
            return "\(r.items.count) items"
        }
        await step("same IP") {
            let r = try await DiscoveryAccess.sameIPSeries(seriesId: sid)
            return "\(r.items.count) items"
        }
        var commentId = ""
        await step("comments") {
            let p = try await EpisodeSocialService.commentsPage(seriesId: sid, vid: vid)
            commentId = p.comments.first { $0.replyCount > 0 }?.id ?? p.comments.first?.id ?? ""
            return "\(p.comments.count) comments total=\(p.total.map(String.init) ?? "-")"
        }
        await step("replies") {
            guard !commentId.isEmpty else { return "skipped (no comment)" }
            let p = try await EpisodeSocialService.repliesPage(seriesId: sid, vid: vid, commentId: commentId)
            return "\(p.replies.count) replies"
        }
        await step("reviews") {
            let r = try await EpisodeSocialService.reviews(seriesId: sid)
            return "rating=\(r.rating.map { String($0) } ?? "-") \(r.reviews.count) reviews"
        }
        await step("social (stats)") {
            let s = try await EpisodeSocialService.load(seriesId: sid, vid: vid)
            return "firstShown=\(s.firstShown.map { "\($0)" } ?? "-") likes=\(s.episodeLikes.map(String.init) ?? "-")"
        }
        await step("actor home") {
            guard !actor.isEmpty else { return "skipped (no actor account)" }
            let h = try await ActorHomeService.home(userId: actor)
            return "\(h.tabs.count) tabs " + h.tabs.map { "\($0.name)(\($0.total.map(String.init) ?? "-"))" }.joined(separator: ",") + " actor=\(actor)"
        }
        var lone = ""
        await step("actor works") {
            guard !actor.isEmpty else { return "skipped (no actor account)" }
            let h = try await ActorHomeService.home(userId: actor)
            guard let tab = h.worksTab, let sub = tab.subTabs.first else { throw HongguoError(.upstream, "no works tab") }
            let page = try await ActorHomeService.works(userId: actor, tab: tab.type, subTab: sub.type)
            lone = page.items.first { $0.episodeCount == 0 && !page.upcomingIds.contains($0.seriesId) }?.seriesId ?? ""
            return "\(tab.name)›\(sub.name) \(page.items.count) items"
        }
        await step("lone creator video") {
            guard !lone.isEmpty else { return "skipped (none listed)" }
            let list = try await SeriesService().episodes(seriesId: lone, force: true)
            let info = try await SeriesService().playInfo(vid: list.episodes[0].vid, seriesId: lone, force: true)
            var request = URLRequest(url: info.url)
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            request.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let box = data.count >= 8 ? String(decoding: data[4..<8], as: UTF8.self) : ""
            guard box == "ftyp" else { throw HongguoError(.upstream, "media not mp4") }
            return "\(list.title.prefix(12)) eps=\(list.episodes.count) status=\((response as? HTTPURLResponse)?.statusCode ?? -1)"
        }
        await step("danmaku") {
            let r = await DanmakuService.shared.fetch(seriesId: sid, vid: vid, fresh: true)
            guard r.success else { throw HongguoError(.upstream, "danmaku failed") }
            return "\(r.items.count) items"
        }
        print("IDENTITY\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(failures, [])
    }
}

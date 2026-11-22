import XCTest
@testable import AppLogic

/// Plays the feed's channel switching against `ChannelLoads` the way `FeedModel` uses it: a
/// cache per channel, one visible list.
final class ChannelLoadsTests: XCTestCase {
    enum Channel { case recommend, comic, real }

    private struct Screen {
        var loads = ChannelLoads<Channel>()
        var shown: Channel = .recommend
        var cache: [Channel: [String]] = [:]
        var visible: [String] = []
        var error: String?

        /// `FeedModel.load()`: a cached channel shows at once, otherwise a request goes out.
        mutating func select(_ channel: Channel) -> ChannelLoads<Channel>.Ticket? {
            shown = channel
            if let cached = cache[channel] { visible = cached; error = nil; return nil }
            return loads.begin(channel)
        }

        mutating func reply(_ ticket: ChannelLoads<Channel>.Ticket, _ list: [String]) {
            let outcome = loads.succeeded(ticket, shown: shown)
            if outcome.cache { cache[ticket.channel] = list }
            if outcome.show { visible = list; error = nil }
        }

        mutating func fail(_ ticket: ChannelLoads<Channel>.Ticket) {
            if loads.failed(ticket, shown: shown) { visible = []; error = "failed" }
        }
    }

    func testLateRecommendReplyAfterComicKeepsBothListsApart() {
        var screen = Screen()
        let recommend = screen.select(.recommend)!
        let comic = screen.select(.comic)!
        screen.reply(comic, ["c1", "c2"])
        XCTAssertEqual(screen.visible, ["c1", "c2"])
        // 推荐 answers after 漫剧 is on screen: cached under 推荐, the 漫剧 list stays.
        screen.reply(recommend, ["r1", "r2"])
        XCTAssertEqual(screen.visible, ["c1", "c2"])
        XCTAssertEqual(screen.cache[.recommend], ["r1", "r2"])
        XCTAssertEqual(screen.cache[.comic], ["c1", "c2"])
        // Back to 推荐: its own list, from the cache.
        XCTAssertNil(screen.select(.recommend))
        XCTAssertEqual(screen.visible, ["r1", "r2"])
    }

    func testLateFailureDoesNotClearAnotherChannel() {
        var screen = Screen()
        let recommend = screen.select(.recommend)!
        let comic = screen.select(.comic)!
        screen.reply(comic, ["c1"])
        screen.fail(recommend)
        XCTAssertEqual(screen.visible, ["c1"])
        XCTAssertNil(screen.error)
    }

    func testOlderRequestForSameChannelIsDropped() {
        // 推荐 → 漫剧 → 推荐 before either first 推荐 reply: only the newest 推荐 reply counts.
        var loads = ChannelLoads<Channel>()
        let first = loads.begin(.recommend)
        let second = loads.begin(.recommend)
        XCTAssertEqual(loads.succeeded(first, shown: .recommend), .init(cache: false, show: false))
        XCTAssertFalse(loads.failed(first, shown: .recommend))
        XCTAssertEqual(loads.succeeded(second, shown: .recommend), .init(cache: true, show: true))
    }

    func testCurrentFailureIsShown() {
        var loads = ChannelLoads<Channel>()
        let ticket = loads.begin(.real)
        XCTAssertTrue(loads.failed(ticket, shown: .real))
    }
}

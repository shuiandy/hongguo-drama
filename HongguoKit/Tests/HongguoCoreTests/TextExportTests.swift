import XCTest
@testable import HongguoCore

final class TextExportTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("te-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func fetchers(_ calls: Calls, danmakuFails: Bool = false, partialDanmaku: Bool = false, locked: Set<String> = []) -> TextExport.Fetchers {
        TextExport.Fetchers(danmaku: { sid, vid, fresh in
            calls.add("danmaku:\(vid):\(fresh)")
            if danmakuFails { return .finalize(seriesId: sid, vid: vid, items: [], truncated: false, error: "网络错误") }
            let items = [DanmakuItem(time: 1.5, text: "好看"), DanmakuItem(time: 3, text: "来了", color: "#FF0000", mode: .top)]
            return .finalize(seriesId: sid, vid: vid, items: items, truncated: partialDanmaku, error: "")
        }, comments: { sid, vid in
            calls.add("comments:\(vid)")
            if locked.contains(vid) { throw HongguoError(.unavailable, "该集在官网需要解锁，暂无公开评论") }
            return EpisodeComments(seriesId: sid, vid: vid, items: [.init(id: "a", content: "不错")], total: 9, likeCount: 1,
                                   notice: EpisodeComments.limitedNotice)
        }, details: { sid in
            calls.add("details")
            return PublicDetails(seriesId: sid, description: "", cover: "", episodeLabel: "", completionStatus: .completed,
                                 rating: 9.1, ratingCount: 10, likeCount: 2, favoriteCount: 3, reviewTotal: 1,
                                 reviews: [Review(author: "甲", avatar: "", content: "推荐", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                  likes: 4, rating: 5)])
        })
    }

    func targets(_ n: Int) throws -> [TextExport.Target] {
        try (1...n).map { index in
            let file = dir.appendingPathComponent("第\(index)集.mp4")
            try Data("v".utf8).write(to: file)
            return TextExport.Target(vid: "730000000000000000\(index)", episodeIndex: index, videoFile: file)
        }
    }

    func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testWritesSidecarsAndReviews() async throws {
        let calls = Calls()
        let reviews = dir.appendingPathComponent("评论.json")
        let summary = await TextExport.export(seriesId: "7200000000000000001", seriesTitle: "霸总归来", targets: try targets(2),
                                              kinds: [.danmaku, .comments, .reviews], reviewsFile: reviews, fetchers: fetchers(calls, locked: ["7300000000000000002"]),
                                              now: { Date(timeIntervalSince1970: 1_800_000_000) })
        XCTAssertEqual(summary.danmaku.ok, 2)
        XCTAssertEqual(summary.danmaku.items, 4)
        XCTAssertEqual(summary.comments.ok, 1)
        XCTAssertEqual(summary.comments.unavailable, 1)
        XCTAssertEqual(summary.reviews.ok, 1)
        XCTAssertEqual(summary.files.count, 4)
        let danmaku = try json(dir.appendingPathComponent("第1集.danmaku.json"))
        XCTAssertEqual(danmaku["kind"] as? String, "danmaku")
        XCTAssertEqual(danmaku["episode_index"] as? Int, 1)
        XCTAssertEqual(danmaku["partial"] as? Bool, false)
        XCTAssertEqual(danmaku["fetched_at"] as? Int64, 1_800_000_000_000)
        XCTAssertEqual((danmaku["items"] as? [[String: Any]])?.last?["mode"] as? String, "top")
        let comments = try json(dir.appendingPathComponent("第1集.comments.json"))
        XCTAssertEqual(comments["partial"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("第2集.comments.json").path))
        let review = try json(reviews)
        XCTAssertEqual((review["items"] as? [[String: Any]])?.first?["created_at"] as? Int64, 1_700_000_000_000)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testCompleteFilesAreKeptAndPartialOnesRetried() async throws {
        let list = try targets(1)
        let first = Calls()
        _ = await TextExport.export(seriesId: "7200000000000000001", seriesTitle: "剧", targets: list, kinds: [.danmaku],
                                    fetchers: fetchers(first, partialDanmaku: true))
        let file = dir.appendingPathComponent("第1集.danmaku.json")
        XCTAssertEqual(try json(file)["partial"] as? Bool, true)
        // A failed retry keeps the partial file.
        let failing = Calls()
        let failed = await TextExport.export(seriesId: "7200000000000000001", seriesTitle: "剧", targets: list, kinds: [.danmaku],
                                             fetchers: fetchers(failing, danmakuFails: true))
        XCTAssertEqual(failed.danmaku.fail, 1)
        XCTAssertEqual(failing.all, ["danmaku:7300000000000000001:true"])
        XCTAssertEqual(try json(file)["partial"] as? Bool, true)
        // A successful retry completes it; after that it is skipped without a request.
        _ = await TextExport.export(seriesId: "7200000000000000001", seriesTitle: "剧", targets: list, kinds: [.danmaku], fetchers: fetchers(Calls()))
        XCTAssertEqual(try json(file)["partial"] as? Bool, false)
        let quiet = Calls()
        let skipped = await TextExport.export(seriesId: "7200000000000000001", seriesTitle: "剧", targets: list, kinds: [.danmaku], fetchers: fetchers(quiet))
        XCTAssertEqual(skipped.danmaku.skipped, 1)
        XCTAssertEqual(skipped.danmaku.items, 2)
        XCTAssertEqual(quiet.all, [])
    }

    func testRejectsNonHongguoAndForeignFiles() async throws {
        let list = try targets(1)
        let other = await TextExport.export(seriesId: "xifan:a:b", seriesTitle: "剧", targets: list, kinds: [.danmaku, .reviews], fetchers: fetchers(Calls()))
        XCTAssertEqual(other.danmaku.skipped, 1)
        XCTAssertEqual(other.reviews.skipped, 1)
        // A file that is not valid JSON is somebody else's: not overwritten.
        let file = dir.appendingPathComponent("第1集.danmaku.json")
        try Data("mine".utf8).write(to: file)
        let result = await TextExport.export(seriesId: "7200000000000000001", seriesTitle: "剧", targets: list, kinds: [.danmaku], fetchers: fetchers(Calls()))
        XCTAssertEqual(result.danmaku.fail, 1)
        XCTAssertEqual(try String(contentsOf: file), "mine")
        XCTAssertNil(TextExport.sidecar(URL(fileURLWithPath: "/tmp/a.mkv"), "danmaku"))
    }
}

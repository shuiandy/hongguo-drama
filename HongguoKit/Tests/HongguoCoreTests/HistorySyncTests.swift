// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Cloud watch history: every page is read, one series can be read fresh before "continue watching",
/// a newer position from another device wins, and opening without watching does not count.
final class HistorySyncTests: XCTestCase {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        private var value = 0
        func add(_ url: String) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
        var phase: Int {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    static let base: Int64 = 1_763_400_000_000

    static func id(_ prefix: String, _ n: Int) -> String { prefix + String(format: "%05d", n) }

    static func row(_ n: Int, at millis: Int64, index: Int = 1, position: Int = 10_000) -> String {
        #"{"book_id_str":"\#(id("72000000000000", n))","vid":"\#(id("73000000000000", n))","vid_index":\#(index),"read_timestamp_ms":\#(millis),"current_play_position":\#(position),"duration":90000}"#
    }

    static func page(_ rows: [String], hasMore: Bool, next: Int) -> JSONValue {
        try! JSONValue.parse(#"{"code":0,"message":"success","data":{"has_more":\#(hasMore),"next_offset":\#(next),"data_list":[\#(rows.joined(separator: ","))]}}"#)
    }

    static func query(_ url: String) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(string: url)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    func signedIn(_ history: @escaping @Sendable (String) -> JSONValue) -> AccountService {
        let store = MemoryCredentialStore(AccountCredentials(cookie: "sessionid=s3cret", profile: AccountProfile(id: "1234567", nickname: "小红")))
        return AccountService(store: store, webRequest: { url, _ in
            HTTPResponse(data: Data(#"{"message":"success","data":{"user_id_str":"1234567","name":"小红"}}"#.utf8), status: 200, headers: [:], url: url)
        }, accountRequest: { url, _ in history(url) }, identity: {
            PlaybackIdentity(deviceId: "1234567890123456789", iid: "2234567890123456789", cdid: "01234567-89ab-cdef-0123-456789abcdef")
        })
    }

    func testHistoryReadsEveryPageWithoutA50SeriesCap() async throws {
        let calls = Calls()
        let account = signedIn { url in
            calls.add(url)
            switch Self.query(url)["offset"] {
            case "0": return Self.page((0..<40).map { Self.row($0, at: Self.base - Int64($0) * 1000) }, hasMore: true, next: 40)
            case "40": return Self.page((40..<70).map { Self.row($0, at: Self.base - Int64($0) * 1000) }, hasMore: false, next: 70)
            default: return Self.page([], hasMore: false, next: 0)
            }
        }
        let rows = try await account.history(refresh: true)
        XCTAssertEqual(rows.count, 70)
        XCTAssertEqual(rows.first?.seriesId, Self.id("72000000000000", 0), "newest first")
        XCTAssertEqual(calls.all.count, 2)
        let first = Self.query(calls.all[0]), second = Self.query(calls.all[1])
        XCTAssertEqual(first["offset"], "0")
        XCTAssertEqual(first["is_first_load"], "true")
        XCTAssertEqual(first["last_min_read_timestamp_ms"], "0")
        XCTAssertEqual(second["offset"], "40")
        XCTAssertEqual(second["is_first_load"], "false")
        XCTAssertEqual(second["last_min_read_timestamp_ms"], String(Self.base - 39_000))
    }

    func testHistoryStopsWhenThePagesRepeat() async throws {
        let calls = Calls()
        let account = signedIn { url in
            calls.add(url)
            let offset = Int(Self.query(url)["offset"] ?? "0") ?? 0
            return Self.page([Self.row(1, at: Self.base), Self.row(2, at: Self.base - 1_000)], hasMore: true, next: offset + 2)
        }
        let rows = try await account.history(refresh: true)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(calls.all.count, 2, "a page with no new series ends the read")
    }

    func testBackgroundCheckReadsOnlyTheNewestPage() async throws {
        let calls = Calls()
        let account = signedIn { url in
            calls.add(url)
            if calls.phase == 0 {
                if Self.query(url)["offset"] == "0" {
                    return Self.page((0..<3).map { Self.row($0, at: Self.base - Int64($0) * 1000) }, hasMore: true, next: 3)
                }
                return Self.page((3..<5).map { Self.row($0, at: Self.base - Int64($0) * 1000) }, hasMore: false, next: 5)
            }
            return Self.page([Self.row(4, at: Self.base + 10_000, index: 6)], hasMore: true, next: 1)
        }
        let full = try await account.history(refresh: true)
        XCTAssertEqual(full.count, 5)
        XCTAssertEqual(calls.all.count, 2)
        calls.phase = 1
        let quick = try await account.history(refresh: true, firstPageOnly: true)
        XCTAssertEqual(calls.all.count, 3, "one request")
        XCTAssertEqual(quick.count, 5, "older series stay from the last full read")
        XCTAssertEqual(quick.first?.seriesId, Self.id("72000000000000", 4))
        XCTAssertEqual(quick.first?.episodeIndex, 6)
    }

    func testHistoryPageStopsWhenTheServerCursorDoesNotMove() throws {
        let stuck = try AccountService.parseHistoryPage(Self.page([Self.row(1, at: Self.base)], hasMore: true, next: 0))
        XCTAssertNil(stuck.next)
        let last = try AccountService.parseHistoryPage(Self.page([Self.row(1, at: Self.base)], hasMore: false, next: 1))
        XCTAssertNil(last.next)
        let more = try AccountService.parseHistoryPage(Self.page([Self.row(1, at: Self.base + 500), Self.row(2, at: Self.base)], hasMore: true, next: 2))
        XCTAssertEqual(more.next, AccountService.HistoryCursor(offset: 2, minTimestampMillis: Self.base, isFirst: false))
        XCTAssertEqual(more.items.count, 2)
    }

    func testLatestRowIsReadFreshBeforeContinuing() async throws {
        let calls = Calls()
        let account = signedIn { url in
            calls.add(url)
            if calls.phase == 0 {
                // Full refresh: series 1 at episode 1 (this Mac), series 2 further down.
                return Self.page([Self.row(1, at: Self.base, index: 1, position: 52_000), Self.row(2, at: Self.base - 5_000)], hasMore: false, next: 2)
            }
            // Later the phone watched series 1 to episode 4; series 2 is no longer on the first page.
            return Self.page([Self.row(1, at: Self.base + 60_000, index: 4, position: 10_000)], hasMore: true, next: 1)
        }
        _ = try await account.history(refresh: true)
        calls.phase = 1
        let one = Self.id("72000000000000", 1), two = Self.id("72000000000000", 2)
        let fresh = try await account.latestHistoryRow(seriesId: one)
        XCTAssertEqual(fresh?.episodeIndex, 4)
        XCTAssertEqual(fresh?.position, 10)
        let cached = await account.historyRow(seriesId: one)
        XCTAssertEqual(cached?.episodeIndex, 4, "the cached list follows the fresh row")
        let older = try await account.latestHistoryRow(seriesId: two)
        XCTAssertEqual(older?.seriesId, two, "a series past the first page falls back to the last full refresh")
        XCTAssertEqual(calls.all.count, 3, "one request per lookup, first page only")
    }

    func testLatestRowIsNilWhenSignedOut() async throws {
        let account = AccountService(store: MemoryCredentialStore(), webRequest: { url, _ in
            HTTPResponse(data: Data(), status: 404, headers: [:], url: url)
        }, accountRequest: { _, _ in XCTFail("no request when signed out"); return .null }, identity: {
            PlaybackIdentity(deviceId: "1", iid: "2", cdid: "3")
        })
        let row = try await account.latestHistoryRow(seriesId: "7200000000000000001")
        XCTAssertNil(row)
    }

    func testNewerCloudPositionMovesTheResumePoint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        store.savePosition(seriesId: "201", title: "入学第一天", cover: "", total: 60, episodeIndex: 1, vid: "v1", position: 52, duration: 90, finished: false)
        store.updateRecord("201") { var r = $0; r.updatedAt = Date(timeIntervalSince1970: 1_000); return r }
        XCTAssertEqual(store.resumePoint(for: "201", episodeCount: 60), ResumePoint(episodeIndex: 1, position: 52))
        let phone = AccountHistoryItem(seriesId: "201", seriesTitle: "入学第一天", cover: "", episodeId: "v4", episodeIndex: 4,
                                       position: 10, duration: 90, updatedAt: Date(timeIntervalSince1970: 2_000), total: 60)
        XCTAssertEqual(store.mergeCloudHistory([phone]), 1)
        XCTAssertEqual(store.resumePoint(for: "201", episodeCount: 60), ResumePoint(episodeIndex: 4, position: 10))
    }

    func testOpeningWithoutWatchingDoesNotCount() {
        var progress = WatchProgress()
        progress.sample(0, playing: true)
        progress.sample(52, playing: true)        // the resume seek lands
        progress.sample(52.25, playing: false)    // paused or buffering
        XCTAssertFalse(progress.shouldSave)
        for step in 1...8 { progress.sample(52.25 + Double(step) * 0.25, playing: true) }
        XCTAssertEqual(progress.watched, 2, accuracy: 0.001)
        XCTAssertFalse(progress.shouldSave)
        for step in 9...12 { progress.sample(52.25 + Double(step) * 0.25, playing: true) }
        XCTAssertTrue(progress.shouldSave, "3 s of real playback")
        var skipped = WatchProgress()
        skipped.userMoved()
        XCTAssertTrue(skipped.shouldSave, "a seek is a deliberate change")
    }
}

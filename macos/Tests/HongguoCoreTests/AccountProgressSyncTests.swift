// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

final class AccountProgressSyncTests: XCTestCase {
    let identity = PlaybackIdentity(deviceId: "1234567890123456789", iid: "2234567890123456789", cdid: "01234567-89ab-cdef-0123-456789abcdef")
    let watched = Date(timeIntervalSince1970: 1_763_430_000.5)

    func report(position: Double = 12.3456, episodeId: String = "7664960983332310041") -> AccountProgressReport {
        AccountProgressReport(seriesId: "7664958856774044697", episodeId: episodeId, episodeIndex: 3, position: position,
                              duration: 95.5, episodeCount: 80, title: "测试\"剧\"", cover: "https://p3-novel.byteimg.com/a.webp",
                              watchedAt: watched)
    }

    func testHistoryBodyKeepsExactIdsAndMilliseconds() throws {
        let text = String(decoding: try report().historyBody(), as: UTF8.self)
        XCTAssertEqual(text, #"{"update_datas":[{"book_id":7664958856774044697,"book_id_str":"7664958856774044697","book_type":2,"#
            + #""vid":7664960983332310041,"vid_index":3,"chapter_index":3,"read_timestamp_ms":1763430000500,"update_timestamp_ms":0,"#
            + #""current_play_position":12345,"player_accumulate_total_time":12345,"duration":95500,"episode_cnt":80,"#
            + #""is_delete":false,"use_soft_delete":false,"genre_type":2150,"book_name":"测试\"剧\"","#
            + #""thumb_url":"https:\/\/p3-novel.byteimg.com\/a.webp"}]}"#)
        // Parses back to the same ids (no float rounding).
        let parsed = try JSONValue.parse(text)
        XCTAssertEqual(parsed["update_datas"][0]["book_id"].idString, "7664958856774044697")
        XCTAssertEqual(parsed["update_datas"][0]["vid"].idString, "7664960983332310041")
    }

    func testProgressBody() throws {
        let text = String(decoding: try report().progressBody(), as: UTF8.self)
        XCTAssertEqual(text, #"{"books":[{"book_id":"7664958856774044697","item_id":"7664960983332310041","vid_index":3,"#
            + #""current_play_time":12345,"current_total_time":95500,"episode_count":80,"read_timestamp_ms":1763430000500,"#
            + #""book_type":2,"progress_rate":"0.1293","player_cumulative_total_duration":12345}],"write_mode":1}"#)
    }

    func testInvalidReportsAreRejected() {
        var bad = report(); bad.seriesId = "12a"
        XCTAssertThrowsError(try bad.historyBody())
        bad = report(); bad.episodeId = "99999999999999999999" // overflows Int64
        XCTAssertThrowsError(try bad.progressBody())
        bad = report(); bad.episodeIndex = 0
        XCTAssertThrowsError(try bad.historyBody())
        bad = report(); bad.position = .nan
        XCTAssertThrowsError(try bad.historyBody())
        bad = report(); bad.watchedAt = Date(timeIntervalSince1970: 0)
        XCTAssertThrowsError(try bad.progressBody())
    }

    func testAcknowledgement() throws {
        XCTAssertTrue(AccountProgressReport.acknowledged(try JSONValue.parse(#"{"code":0,"message":"success"}"#)))
        XCTAssertTrue(AccountProgressReport.acknowledged(try JSONValue.parse(#"{"code":"0","data":{"error_code":0}}"#)))
        XCTAssertFalse(AccountProgressReport.acknowledged(try JSONValue.parse(#"{"code":0,"data":{"error_code":1003}}"#)))
        XCTAssertFalse(AccountProgressReport.acknowledged(try JSONValue.parse(#"{"code":100004,"message":"no login"}"#)))
        XCTAssertFalse(AccountProgressReport.acknowledged(try JSONValue.parse(#"{"message":"success"}"#)))
        XCTAssertFalse(AccountProgressReport.acknowledged(.null))
    }

    final class Writes: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(url: String, headers: [(String, String)], body: [UInt8])] = []
        var reply = #"{"code":0,"message":"success"}"#
        func add(_ url: String, _ headers: [(String, String)], _ body: [UInt8]) -> String {
            lock.lock(); defer { lock.unlock() }
            calls.append((url, headers, body))
            return reply
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    }

    func service(_ writes: Writes, signedIn: Bool = true) -> AccountService {
        let store = MemoryCredentialStore(signedIn ? AccountCredentials(cookie: "sessionid=s3cret; sid_tt=t", profile: AccountProfile(id: "1234567", nickname: "小红")) : nil)
        return AccountService(store: store, webRequest: { url, _ in
            HTTPResponse(data: Data(#"{"message":"success","data":{"user_id_str":"1234567","name":"小红"}}"#.utf8), status: 200, headers: [:], url: url)
        }, accountRequest: { _, _ in .null }, identity: { self.identity }, accountWrite: { url, headers, body in
            try JSONValue.parse(writes.add(url, headers, body))
        }, now: { self.watched })
    }

    func testReportWritesHistoryThenProgressWithCookie() async throws {
        let writes = Writes()
        let account = service(writes)
        let result = try await account.reportProgress(report())
        XCTAssertEqual(result, .synced)
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes.calls[0].url.hasPrefix("https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/read_history/update/v1/?"))
        XCTAssertTrue(writes.calls[1].url.hasPrefix("https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/read_progress/upload/v1/?"))
        XCTAssertEqual(writes.calls[0].body, try report().historyBody())
        XCTAssertEqual(writes.calls[1].body, try report().progressBody())
        for call in writes.calls {
            XCTAssertEqual(call.headers.first { $0.0 == "Cookie" }?.1, "sessionid=s3cret; sid_tt=t")
            XCTAssertEqual(call.headers.first { $0.0 == "x-ss-stub" }?.1, AppCrypto.hex(AppCrypto.md5(call.body), uppercase: true))
        }

        // Same episode, position within the step: skipped. Moved on: sent again. Forced: sent.
        let near = try await account.reportProgress(report(position: 14))
        XCTAssertEqual(near, .skipped)
        XCTAssertEqual(writes.count, 2)
        _ = try await account.reportProgress(report(position: 40))
        XCTAssertEqual(writes.count, 4)
        _ = try await account.reportProgress(report(position: 40), force: true)
        XCTAssertEqual(writes.count, 6)
        _ = try await account.reportProgress(report(position: 40, episodeId: "7664960983332310042"))
        XCTAssertEqual(writes.count, 8)
    }

    func testRejectedWriteThrowsAndStopsBeforeProgress() async throws {
        let writes = Writes()
        writes.reply = #"{"code":100004,"message":"<b>请先登录</b>"}"#
        let account = service(writes)
        do {
            try await account.reportProgress(report())
            XCTFail("expected failure")
        } catch let error as HongguoError {
            XCTAssertEqual(error.message, "红果账号未确认进度同步：请先登录")
        }
        XCTAssertEqual(writes.count, 1, "the resume point is not written after the history write fails")
        // Not remembered as reported: the next attempt sends again.
        writes.reply = #"{"code":0}"#
        let retry = try await account.reportProgress(report())
        XCTAssertEqual(retry, .synced)
        XCTAssertEqual(writes.count, 3)
    }

    func testSignedOutSendsNothing() async throws {
        let writes = Writes()
        let result = try await service(writes, signedIn: false).reportProgress(report())
        XCTAssertEqual(result, .skipped)
        XCTAssertEqual(writes.count, 0)
    }

    func testSettingDefaultsOffAndDecodesFromOldFiles() throws {
        XCTAssertFalse(AppSettings().cloudProgressSync)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoNext":false}"#.utf8))
        XCTAssertFalse(old.cloudProgressSync)
        var on = AppSettings(); on.cloudProgressSync = true
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(round.cloudProgressSync)
    }
}

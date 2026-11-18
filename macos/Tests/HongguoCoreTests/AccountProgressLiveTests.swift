// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Opt-in live check of writing watch progress to the REAL signed-in Hongguo account (the app's
/// Keychain login). Only run with the account owner's consent:
///   `HONGGUO_LIVE_PROGRESS=rewrite swift test --filter AccountProgressLiveTests`
/// It never adds a series: it takes the newest row already in the cloud history and writes the same
/// episode and position back with the current time, then reads the history again and checks the row.
/// The history list is eventually consistent (a confirmed write showed up after more than 2 s on
/// 2026-11-18), so the read-back polls for up to 60 s.
/// Read-only look at the newest cloud rows: `HONGGUO_LIVE_PROGRESS=inspect swift test --filter AccountProgressLiveTests`.
final class AccountProgressLiveTests: XCTestCase {
    func testInspectNewestCloudRows() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE_PROGRESS"] == "inspect",
                          "set HONGGUO_LIVE_PROGRESS=inspect for a read-only look at the cloud history")
        let account = AccountService()
        let status = await account.status()
        let profile = try XCTUnwrap(status.profile, "sign in in the app first: \(status.error)")
        let rows = try await account.history(refresh: true)
        let lines = rows.prefix(5).map { row in
            "  \(row.seriesId) 《\(row.seriesTitle)》 ep \(row.episodeIndex) pos \(row.position)s updated \(row.updatedAt)"
        }
        print("PROGRESS-INSPECT account=\(profile.id.prefix(3))… now \(Date())\n" + lines.joined(separator: "\n"))
    }

    func testRewriteNewestCloudRow() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE_PROGRESS"] == "rewrite",
                          "set HONGGUO_LIVE_PROGRESS=rewrite to write to the real account")
        let account = AccountService()
        let status = await account.status()
        let profile = try XCTUnwrap(status.profile, "sign in in the app first: \(status.error)")
        let before = try await account.history(refresh: true)
        let row = try XCTUnwrap(before.first, "the cloud history is empty; nothing to rewrite")
        guard row.episodeIndex >= 1 else { throw XCTSkip("newest row has no episode index") }
        let stamp = Date()
        let report = AccountProgressReport(seriesId: row.seriesId, episodeId: row.episodeId, episodeIndex: row.episodeIndex,
                                           position: row.position, duration: row.duration, episodeCount: row.total,
                                           title: row.seriesTitle, cover: row.cover, watchedAt: stamp)
        let result = try await account.reportProgress(report, force: true)
        XCTAssertEqual(result, .synced)
        var after: [AccountHistoryItem] = []
        var updated = row
        var waited = 0
        for delay in [2, 3, 5, 10, 20, 20] {
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            waited += delay
            after = try await account.history(refresh: true)
            updated = try XCTUnwrap(after.first { $0.seriesId == row.seriesId }, "series missing after write")
            if updated.updatedAt.timeIntervalSince1970 >= stamp.timeIntervalSince1970 - 2 { break }
        }
        print("""
        PROGRESS-LIVE account=\(profile.id.prefix(3))… series=\(row.seriesId) 《\(row.seriesTitle)》
          before: ep \(row.episodeIndex) vid \(row.episodeId) pos \(row.position)s updated \(row.updatedAt)
          after:  ep \(updated.episodeIndex) vid \(updated.episodeId) pos \(updated.position)s updated \(updated.updatedAt)
          newest after write: \(after.first?.seriesId == row.seriesId), visible after \(waited)s
        """)
        XCTAssertEqual(updated.episodeId, row.episodeId)
        XCTAssertEqual(updated.position, row.position, accuracy: 1)
        XCTAssertGreaterThanOrEqual(updated.updatedAt.timeIntervalSince1970, stamp.timeIntervalSince1970 - 2,
                                    "the cloud row kept its old time: the write was acknowledged but not applied")
    }
}

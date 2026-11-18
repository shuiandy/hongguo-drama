// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Opt-in live check of writing watch progress to the REAL signed-in Hongguo account (the app's
/// Keychain login). Only run with the account owner's consent:
///   `HONGGUO_LIVE_PROGRESS=rewrite swift test --filter AccountProgressLiveTests`
/// It never adds a series: it takes the newest row already in the cloud history and writes the same
/// episode and position back with the current time, then reads the history again and checks the row.
final class AccountProgressLiveTests: XCTestCase {
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
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = try await account.history(refresh: true)
        let updated = try XCTUnwrap(after.first { $0.seriesId == row.seriesId }, "series missing after write")
        print("""
        PROGRESS-LIVE account=\(profile.id.prefix(3))… series=\(row.seriesId) 《\(row.seriesTitle)》
          before: ep \(row.episodeIndex) vid \(row.episodeId) pos \(row.position)s updated \(row.updatedAt)
          after:  ep \(updated.episodeIndex) vid \(updated.episodeId) pos \(updated.position)s updated \(updated.updatedAt)
          newest after write: \(after.first?.seriesId == row.seriesId)
        """)
        XCTAssertEqual(updated.episodeId, row.episodeId)
        XCTAssertEqual(updated.position, row.position, accuracy: 1)
        XCTAssertGreaterThanOrEqual(updated.updatedAt.timeIntervalSince1970, stamp.timeIntervalSince1970 - 2,
                                    "the cloud row kept its old time: the write was acknowledged but not applied")
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Opt-in live check of the Mac app's lookup through `SeriesService` with the default
/// `PlatformBehavior.mac` (the iOS app's source first): `HONGGUO_LIVE=1 swift test --filter MacSourceLiveTests`.
/// Read-only, about eight requests. Prints milliseconds, routes and codecs only: no device
/// identity, no episode ids and no signed addresses.
final class MacSourceLiveTests: XCTestCase {
    func testSeriesServiceAsksTheIOSSourceFirst() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        XCTAssertTrue(PlatformBehavior.current.authenticatedSourceFirst)
        let lines = LogLines()
        AccountDataAccess.onWriteLog = { lines.add($0) }
        defer { AccountDataAccess.onWriteLog = nil }

        let series = SeriesService()
        let catalog = try await CatalogService().browse(kind: .hotDrama)
        var picked: SeriesEpisodes?
        for summary in catalog.results.prefix(5) {
            if let list = try? await series.episodes(seriesId: summary.seriesId), list.episodes.count >= 12 {
                picked = list
                break
            }
        }
        let list = try XCTUnwrap(picked, "no ranked series with 12 episodes")
        var report: [String] = []
        let warmStart = Date()
        await series.warmUpPlayback()
        report.append("warm-up: \(Int(Date().timeIntervalSince(warmStart) * 1000)) ms")
        var failures = 0
        for index in [1, 6, 11] {
            let started = Date()
            do {
                let info = try await series.playInfo(vid: list.episodes[index - 1].vid, seriesId: list.seriesId)
                report.append("ep\(index): ok \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(info.source.rawValue) \(info.codec) "
                              + "\(info.quality?.shortSide ?? 0)p, \(info.variants.count + 1) qualities")
            } catch {
                failures += 1
                report.append("ep\(index): failed \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        }
        report += lines.all.map { "log: \($0)" }
        print("MAC-SOURCE-LIVE\n" + report.joined(separator: "\n"))
        XCTAssertEqual(failures, 0, report.joined(separator: "\n"))
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

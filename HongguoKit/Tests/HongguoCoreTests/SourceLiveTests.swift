// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Opt-in live check of the one play source (the official iOS client's) through `SeriesService`:
/// `HONGGUO_LIVE=1 swift test --filter SourceLiveTests`. Read-only, about eight requests (plus
/// one App search). Prints milliseconds, routes and codecs only: no device identity, no episode ids
/// and no signed addresses.
final class SourceLiveTests: XCTestCase {
    func testSeriesServicePlaysThroughTheOfficialSource() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
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
                XCTAssertEqual(info.source, .app)
                report.append("ep\(index): ok \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(info.source.rawValue) \(info.codec) "
                              + "\(info.quality?.shortSide ?? 0)p, \(info.variants.count + 1) qualities")
            } catch {
                failures += 1
                report.append("ep\(index): failed \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        }
        // App search signs with the same persistent device now.
        let searchStarted = Date()
        do {
            let page = try await AppSearchService().search(String(list.title.prefix(4)))
            report.append("search: ok \(Int(Date().timeIntervalSince(searchStarted) * 1000)) ms, \(page.results.count) results")
            if page.results.isEmpty { failures += 1 }
        } catch {
            failures += 1
            report.append("search: failed \(Int(Date().timeIntervalSince(searchStarted) * 1000)) ms, \(error.localizedDescription.prefix(40))")
        }
        report += lines.all.map { "log: \($0)" }
        print("SOURCE-LIVE\n" + report.joined(separator: "\n"))
        XCTAssertEqual(failures, 0, report.joined(separator: "\n"))
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

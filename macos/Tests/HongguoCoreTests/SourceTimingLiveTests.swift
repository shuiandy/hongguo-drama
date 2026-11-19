// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Opt-in live timing of episode source lookups, old order against the fast App source:
/// `HONGGUO_LIVE=1 swift test --filter SourceTimingLiveTests`.
/// Read-only requests, about thirty in all. Prints milliseconds and outcomes only: no device
/// identity, no episode ids and no signed addresses.
final class SourceTimingLiveTests: XCTestCase {
    private func timed<T>(_ work: () async throws -> T) async -> (Result<T, Error>, Int) {
        let started = Date()
        let result: Result<T, Error>
        do { result = .success(try await work()) } catch { result = .failure(error) }
        return (result, Int(Date().timeIntervalSince(started) * 1000))
    }

    private func outcome<T>(_ result: Result<T, Error>) -> String {
        switch result {
        case .success: return "ok"
        case .failure(let error):
            if let app = error as? AppSourceError { return "failed(\(app.code.rawValue))" }
            if let known = error as? HongguoError { return "failed(\(known.kind.rawValue))" }
            return "failed"
        }
    }

    func testOldOrderAgainstFastSource() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let series = SeriesService()
        let catalog = try await CatalogService().browse(kind: .hotDrama)
        var picked: SeriesEpisodes?
        for summary in catalog.results.prefix(8) {
            if let list = try? await series.episodes(seriesId: summary.seriesId), list.episodes.count >= 30 {
                picked = list
                break
            }
        }
        let list = try XCTUnwrap(picked, "no ranked series with 30 episodes")
        func episode(_ index: Int) -> Episode { list.episodes[index - 1] }
        var report = ["series with \(list.episodes.count) episodes, web page lists \(list.webAccessibleEpisodes.map(String.init) ?? "?")"]

        // The order the Mac app used so far: web page, then the queued App source, which
        // registers a new anonymous device for every lookup.
        var oldTotals: [Int] = []
        for index in [1, 8, 15, 22] {
            let item = episode(index)
            let (web, webMs) = await timed { try await series.playInfoFromWeb(vid: item.vid, seriesId: list.seriesId) }
            var line = "old ep\(index): web \(outcome(web)) \(webMs) ms"
            var total = webMs
            var info = try? web.get()
            if info == nil {
                let (app, appMs) = await timed { try await AppSource.shared.playInfo(vid: item.vid) }
                line += ", app \(outcome(app)) \(appMs) ms"
                total += appMs
                info = try? app.get()
            }
            if let info {
                let (_, guardMs) = await timed { try await URLGuard.check(info.url) }
                line += ", address check \(guardMs) ms"
                total += guardMs
                if info.isEncrypted, !info.isByteVC2 {
                    let (header, headerMs) = await timed { try await CencStreamLoader.open(info) }
                    line += ", header \(outcome(header)) \(headerMs) ms"
                    total += headerMs
                }
                line += ", source \(info.source) \(info.codec)"
            }
            line += ", total \(total) ms"
            oldTotals.append(total)
            report.append(line)
        }

        // The fast source: one device kept in memory. The first lookup includes the registration.
        let fast = FastAppPlaybackSource()
        var fastTotals: [Int] = []
        var fastFailures = 0
        for index in [2, 9, 16, 23] {
            let item = episode(index)
            let (result, ms) = await timed { try await fast.resolve(vid: item.vid) }
            var line = "fast ep\(index): \(outcome(result)) \(ms) ms"
            var total = ms
            if let info = try? result.get() {
                let (_, guardMs) = await timed { try await URLGuard.check(info.url) }
                line += ", address check \(guardMs) ms"
                total += guardMs
                if info.isEncrypted, !info.isByteVC2 {
                    let (header, headerMs) = await timed { try await CencStreamLoader.open(info) }
                    line += ", header \(outcome(header)) \(headerMs) ms"
                    total += headerMs
                }
                line += ", \(info.codec)"
            } else {
                fastFailures += 1
            }
            line += ", total \(total) ms"
            fastTotals.append(total)
            report.append(line)
        }

        // Six episodes in one request, then two of them as the viewer would pick them.
        let batch = (25...30).map { episode($0).vid }
        let (_, batchMs) = await timed { await fast.prefetchBatch(vids: batch) }
        report.append("batch of 6: \(batchMs) ms")
        for index in [25, 28] {
            let (result, ms) = await timed { try await fast.resolve(vid: episode(index).vid) }
            report.append("after batch ep\(index): \(outcome(result)) \(ms) ms")
            if (try? result.get()) == nil { fastFailures += 1 }
        }

        // What the app itself now does for one more episode, through SeriesService.
        let (whole, wholeMs) = await timed { try await series.playInfo(vid: episode(24).vid, seriesId: list.seriesId) }
        report.append("SeriesService ep24 (includes a registration): \(outcome(whole)) \(wholeMs) ms")

        report.append("old totals \(oldTotals) ms, fast totals \(fastTotals) ms")
        print("SOURCE-TIMING-LIVE\n" + report.joined(separator: "\n"))
        XCTAssertEqual(fastFailures, 0, report.joined(separator: "\n"))
        XCTAssertNotNil(try? whole.get(), report.joined(separator: "\n"))
    }
}

import XCTest
@testable import HongguoCore

/// Opt-in live smoke test against the real danmaku endpoint: `HONGGUO_LIVE=1 swift test --filter DanmakuLiveTests`.
/// Read-only requests; the anonymous identity is written to a temporary folder, never to the app's data.
final class DanmakuLiveTests: XCTestCase {
    func testOfficialDanmakuForARankedSeries() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let catalog = try await CatalogService().browse(kind: CatalogKind.allCases[0])
        let series = SeriesService()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("danmaku-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let danmaku = DanmakuService(identityFile: dir.appendingPathComponent("client.json"))
        var report: [String] = []
        var anyItems = false
        for summary in catalog.results.prefix(3) {
            let episodes = try await series.episodes(seriesId: summary.seriesId)
            guard let first = episodes.episodes.first else { continue }
            let result = await danmaku.fetch(seriesId: summary.seriesId, vid: first.vid)
            let sample = result.items.prefix(3).map { String(format: "%.1fs %@", $0.time, $0.text) }.joined(separator: " | ")
            report.append("《\(summary.title)》ep1 success=\(result.success) items=\(result.total) truncated=\(result.truncated) notice=\(result.notice) sample=[\(sample)]")
            anyItems = anyItems || !result.items.isEmpty
        }
        print("DANMAKU-LIVE\n" + report.joined(separator: "\n"))
        XCTAssertTrue(anyItems, report.joined(separator: "\n"))
    }
}

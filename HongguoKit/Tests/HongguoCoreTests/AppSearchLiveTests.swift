import XCTest
@testable import HongguoCore

/// Opt-in live smoke test of the signed App search and the App new-release catalogue:
/// `HONGGUO_LIVE=1 swift test --filter AppSearchLiveTests`. Read-only requests, nothing is stored.
final class AppSearchLiveTests: XCTestCase {
    func testAppSearchAndNewReleases() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var report: [String] = []
        let releases = try await NewReleaseService().list(useCache: false)
        report.append("new releases: \(releases.items.count) partial=\(releases.partial) today=\(releases.items.filter(\.releasedToday).count) "
            + "first=[\(releases.items.prefix(5).map(\.series.title).joined(separator: " | "))]")
        // Search the App for a title the catalogue just listed, so the query is known to exist.
        let keyword = releases.items.first?.series.title ?? "总裁"
        let app = try await AppSearchService().search(keyword)
        report.append("app search 《\(keyword)》: \(app.results.count) hasMore=\(app.hasMore) "
            + "first=[\(app.results.prefix(5).map(\.title).joined(separator: " | "))]")
        if app.hasMore {
            let next = try await AppSearchService().search(keyword, page: 2, cursor: app.cursor)
            report.append("app search page 2: \(next.results.count)")
        }
        print("APP-SEARCH-LIVE\n" + report.joined(separator: "\n"))
        XCTAssertFalse(releases.items.isEmpty, report.joined(separator: "\n"))
        XCTAssertFalse(app.results.isEmpty, report.joined(separator: "\n"))
    }
}

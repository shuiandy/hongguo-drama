import XCTest
@testable import HongguoCore

/// Live check of 西饭 and 河马: browse, a genre page, page 2, search, episodes and a play URL.
/// `HONGGUO_LIVE=1 swift test --filter ExternalSourcesLiveTests`. Read-only requests.
final class ExternalSourcesLiveTests: XCTestCase {
    func testXifanAndHemaLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var report: [String] = []
        let sources: [MediaSource] = [XifanSource(), HemaSource()]
        for source in sources {
            let first = try await source.browse(genre: nil, page: 1)
            report.append("\(source.label) browse p1: \(first.results.count) more=\(first.hasMore) genres=\(first.genres.count) first=\(first.results.first?.title ?? "-")")
            XCTAssertFalse(first.results.isEmpty, "\(source.label) browse")
            if first.hasMore {
                let second = try await source.browse(genre: nil, page: 2)
                report.append("\(source.label) browse p2: \(second.results.count)")
            }
            if let genre = first.genres.first {
                let filtered = try await source.browse(genre: genre.slug, page: 1)
                report.append("\(source.label) genre \(genre.label): \(filtered.results.count)")
            }
            if let keyword = first.results.first?.title {
                let found = try await source.search(String(keyword.prefix(4)), page: 1)
                report.append("\(source.label) search \(keyword.prefix(4)): \(found.results.count)")
            }
            guard let series = first.results.first else { continue }
            let list = try await source.episodes(seriesId: series.seriesId)
            let free = list.episodes.first { $0.locked != true }
            report.append("\(source.label) episodes \(list.title): \(list.episodes.count) free=\(list.episodes.filter { $0.locked != true }.count)")
            if let free {
                let info = try await source.playInfo(vid: free.vid, seriesId: series.seriesId)
                var request = URLRequest(url: info.url)
                request.httpMethod = "GET"
                request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                if let referer = info.referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                report.append("\(source.label) play ep\(free.index): host=\(info.url.host ?? "") status=\(status) type=\((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "")")
                XCTAssertTrue([200, 206].contains(status), "\(source.label) media")
            }
        }
        print(report.joined(separator: "\n"))
    }
}

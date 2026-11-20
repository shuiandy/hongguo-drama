// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `HONGGUO_LIVE=1 swift test --filter AppSocialLiveTests` (optional `HONGGUO_SIDS=<id>,<id>` or
/// `HONGGUO_PROBES=关键词,关键词`): for a live-action and a comic drama, the score, reviews, heat,
/// first-shown date, like count, cast and tags as the App reads them, next to the website's series
/// page. Per series: one App search, four App reads, one website page. Prints titles, counts, cast
/// names and tags only; no user names, ids, device identity or signed addresses.
final class AppSocialLiveTests: XCTestCase {
    func testAppSocialAgainstWebsite() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var ids = (env["HONGGUO_SIDS"] ?? "").split(separator: ",").map(String.init).filter { $0.matchesDigits(min: 6, max: 19) }
        if ids.isEmpty {
            for keyword in (env["HONGGUO_PROBES"] ?? "家里家外,入学第一天").split(separator: ",") {
                if let first = try await AppSearchService().search(String(keyword)).results.first { ids.append(first.seriesId) }
                try await Task.sleep(for: .seconds(1))
            }
        }
        var lines: [String] = []
        for (n, sid) in ids.prefix(3).enumerated() {
            lines.append("== series \(n + 1)")
            do {
                let raw = try await OfficialSeriesDetail.request(sid)
                let detail = try OfficialSeriesDetail.parse(raw, seriesId: sid)
                let data = raw["data"]["video_detail_data"][sid]["video_data"]
                lines.append("app detail: title=\(detail.title) favorites=\(detail.favoriteCount ?? -1) episodes=\(detail.episodes.count) episodeLikesSum=\(detail.episodes.compactMap(\.likes).reduce(0, +))")
                lines.append("app cast \(detail.cast.count): " + detail.cast.prefix(6).map { "\($0.name)/\($0.role)" }.joined(separator: ", "))
                lines.append("app tags: " + detail.tags.joined(separator: ","))
                let schema = data["category_schema"]
                lines.append("app category_schema: \(schema.string != nil ? "string" : schema.array != nil ? "array" : "other") \(String((schema.string ?? "").prefix(160)))")
                if let first = data["celebrities"].array?.first?.object { lines.append("app celebrity keys: " + first.keys.sorted().joined(separator: ",")) }
                lines.append("app sub titles: " + (data["series_sub_title_list"].array ?? []).map { $0.string ?? $0["text"].string ?? "?" }.joined(separator: " | "))
            } catch { lines.append("app detail: \(error)") }
            try await Task.sleep(for: .seconds(1))

            do {
                let raw = try await OfficialSeriesStats.request(sid)
                do {
                    let stats = try OfficialSeriesStats.parse(raw, seriesId: sid)
                    lines.append("app stats: heat=\(stats.heatText) score=\(stats.heatScore ?? -1) published=\(stats.publishedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-") likes=\(stats.likeCount ?? -1) favorites=\(stats.favoriteCount ?? -1)")
                } catch {
                    lines.append("app stats: \(error) code=\(Int(raw["code"].number ?? -1)) msg=\((raw["message"].string ?? "").prefix(40))")
                    Self.keys(raw["data"], name: "data", mask: sid, into: &lines)
                }
            } catch { lines.append("app stats: \(error)") }
            try await Task.sleep(for: .seconds(1))

            do {
                let raw = try await OfficialSeriesReviews.request(sid)
                let reviews = try OfficialSeriesReviews.parse(raw)
                let page = reviews.page
                lines.append("app reviews: rating=\(reviews.rating ?? -1) count=\(reviews.ratingCount ?? -1) total=\(page.total ?? -1) page=\(page.comments.count) scored=\(page.comments.filter { $0.rating != nil }.count) hasMore=\(page.hasMore)")
                if let first = raw["data"]["data_list"].array?.first {
                    lines.append("app review keys: comment=\(first["comment"].object?.keys.sorted().joined(separator: ",") ?? "-") expand=\(first["comment"]["expand"].object?.keys.sorted().joined(separator: ",") ?? "-")")
                }
                if page.hasMore {
                    try await Task.sleep(for: .seconds(1))
                    let next = try await EpisodeSocialService.moreReviews(seriesId: sid, cursor: page.cursor)
                    let overlap = Set(next.comments.map(\.id)).intersection(page.comments.map(\.id)).count
                    lines.append("app reviews page 2: \(next.comments.count) overlap=\(overlap) hasMore=\(next.hasMore)")
                }
            } catch { lines.append("app reviews: \(error)") }
            try await Task.sleep(for: .seconds(1))

            do {
                var options = HTTPClient.Options()
                options.headers = ["User-Agent": UserAgents.web, "Referer": Site.referer,
                                   "Accept": "text/html,application/xhtml+xml", "Accept-Language": "zh-CN,zh;q=0.9"]
                options.timeout = 10
                options.maxRedirects = 0
                let response = try await HTTPClient.shared.get(Site.detailURL(sid), options: options)
                let router = try HTMLData.routerData(response.text)
                let page = (router["loaderData"].object ?? [:]).values.first { !$0["seriesDetail"].isNull } ?? .null
                let social = page["seriesSocialInfo"]
                let detail = page["seriesDetail"]
                lines.append("web: rating=\(Self.v(social["rating"])) count=\(Self.v(social["rating_count"])) total=\(Self.v(social["reviews"]["total_count"])) heat=\(Self.v(social["hot_score_data"]["text"])) first=\(Self.v(detail["first_visible_time"])) likes=\(Self.v(social["series_like_count"])) favorites=\(Self.v(social["series_favorite_count"]))")
                let cast = detail["celebrities"].array ?? []
                lines.append("web cast \(cast.count): " + cast.prefix(6).map { "\($0["nickname"].string ?? "?")/\($0["sub_title"].string ?? "")" }.joined(separator: ", "))
                lines.append("web tags: " + (detail["tags"].array ?? []).map { $0.string ?? $0["name"].string ?? "?" }.joined(separator: ","))
            } catch { lines.append("web: \(error)") }
            try await Task.sleep(for: .seconds(1))
        }
        print("SOCIAL\n" + lines.joined(separator: "\n"))
    }

    private static func v(_ value: JSONValue) -> String {
        if let number = value.number { return String(number) }
        if let text = value.string { return text }
        return "-"
    }

    /// Key names and types to depth 4, the series id masked.
    private static func keys(_ value: JSONValue, name: String, depth: Int = 0, mask: String, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        let label = name.replacingOccurrences(of: mask, with: "<sid>")
        if let object = value.object {
            lines.append("\(pad)\(label) {\(object.count)}")
            guard depth < 4 else { return }
            for key in object.keys.sorted().prefix(30) { keys(object[key]!, name: key, depth: depth + 1, mask: mask, into: &lines) }
        } else if let array = value.array {
            lines.append("\(pad)\(label) [\(array.count)]")
        } else {
            lines.append("\(pad)\(label) = \(value.number != nil ? "number" : value.string != nil ? "string" : value.bool != nil ? "bool" : "null")")
        }
    }
}

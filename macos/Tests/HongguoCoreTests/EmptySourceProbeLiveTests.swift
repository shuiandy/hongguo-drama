// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Opt-in probe for series whose episodes come back empty from every source:
/// `HONGGUO_LIVE=1 HONGGUO_PROBE="关键词" swift test --filter EmptySourceProbeLiveTests`.
/// Read-only. Prints outcomes, key names and short scalar values only (no signed addresses,
/// no device identity).
final class EmptySourceProbeLiveTests: XCTestCase {
    private func shape(_ value: JSONValue, depth: Int = 0) -> String {
        if let object = value.object {
            guard depth < 2 else { return "{\(object.count) keys}" }
            let parts = object.keys.sorted().prefix(25).map { key -> String in
                let lowered = key.lowercased()
                if lowered.contains("url") || lowered.contains("api") || lowered.contains("token") || lowered.contains("key") {
                    return "\(key):<\(object[key]!.string?.count ?? -1)ch>"
                }
                return "\(key):\(shape(object[key]!, depth: depth + 1))"
            }
            return "{" + parts.joined(separator: ", ") + "}"
        }
        if let text = value.string { return text.count > 40 ? "\"<\(text.count)ch>\"" : "\"\(text)\"" }
        if let number = value.number { return String(number) }
        if value.isNull { return "null" }
        return "\(value)".prefix(40).description
    }

    func testProbeSeries() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let keyword = env["HONGGUO_PROBE"] ?? "女剑仙追我到地球"
        let search = try await HongguoSearch().search(keyword)
        let series = SeriesService()
        let fast = FastAppPlaybackSource()
        var report: [String] = ["search channel \(search.channel.rawValue), \(search.results.count) results"]
        for summary in search.results.prefix(5) where summary.title.contains(keyword.prefix(4)) {
            report.append("== \(summary.title) id=\(summary.seriesId) eps=\(summary.episodeCount)")
            guard let list = try? await series.episodes(seriesId: summary.seriesId) else {
                report.append("   episodes: failed"); continue
            }
            report.append("   list \(list.episodes.count) eps, web lists \(list.webAccessibleEpisodes.map(String.init) ?? "?")")
            let picks = Array(Set([1, 2, list.episodes.count / 2, list.episodes.count - 1, list.episodes.count])).sorted().filter { $0 >= 1 && $0 <= list.episodes.count }
            for index in picks {
                let ep = list.episodes[index - 1]
                var line = "   ep\(index) vid(\(ep.vid.count)ch) webAvail=\(ep.webAvailable.map(String.init) ?? "?"): "
                do {
                    let info = try await fast.resolve(vid: ep.vid, force: true)
                    line += "fast ok \(info.source)"
                } catch let error as AppSourceError {
                    line += "fast \(error.code.rawValue) \(error.message)"
                    do {
                        let raw = try await fast.requestModels(vids: [ep.vid], deadline: Date().addingTimeInterval(10))
                        line += "\n      raw: \(shape(raw))"
                    } catch let error as AppSourceError {
                        line += "\n      raw: \(error.code.rawValue) status=\(error.status.map(String.init) ?? "-") \(error.message)"
                    }
                    do { _ = try await AppSource.shared.playInfo(vid: ep.vid); line += "\n      queue ok" }
                    catch { line += "\n      queue: \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
                } catch {
                    line += "fast other \(error)"
                }
                report.append(line)
                try await Task.sleep(for: .milliseconds(600))
            }
        }
        print("PROBE\n" + report.joined(separator: "\n"))
    }
}

final class WebFallbackParseTests: XCTestCase {
    func testParsesMainURL() throws {
        let body = #"{"main_url":"https://v3-hgweb.qznovelvod.com/abc/video.mp4?x=1","url_expire":4102444800,"base_resp":{"StatusCode":0,"StatusMessage":""}}"#
        let info = try SeriesService.parseWebFallback(Data(body.utf8), status: 200, vid: "123")
        XCTAssertEqual(info.url.host, "v3-hgweb.qznovelvod.com")
        XCTAssertEqual(info.source, .web)
        XCTAssertEqual(info.vid, "123")
    }

    func testRejectsErrorAndExpired() {
        XCTAssertThrowsError(try SeriesService.parseWebFallback(Data(#"{"error":"public_fallback_unavailable"}"#.utf8), status: 403, vid: "1"))
        let expired = #"{"main_url":"https://v3-hgweb.qznovelvod.com/a.mp4","url_expire":1000,"base_resp":{"StatusCode":0}}"#
        XCTAssertThrowsError(try SeriesService.parseWebFallback(Data(expired.utf8), status: 200, vid: "1"))
        XCTAssertThrowsError(try SeriesService.parseWebFallback(Data(), status: 200, vid: "1"))
    }
}

import AVFoundation

/// `HONGGUO_LIVE=1 swift test --filter WebFallbackLiveTests`: website fallback channel for a few
/// episodes of a searched series, then AVFoundation loads each address (Referer set) and reports
/// whether it is playable and how long it is. Read-only; prints no addresses.
final class WebFallbackLiveTests: XCTestCase {
    func testFallbackPlays() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let keyword = env["HONGGUO_PROBE"] ?? "女剑仙追我到地球了第三季"
        let series = SeriesService()
        let found = try await HongguoSearch().search(keyword)
        let summary = try XCTUnwrap(found.results.first)
        let list = try await series.episodes(seriesId: summary.seriesId)
        var report = ["\(summary.title): \(list.episodes.count) eps"]
        for index in Array(Set([1, list.episodes.count / 2, list.episodes.count])).sorted() where index >= 1 {
            let ep = list.episodes[index - 1]
            do {
                let info = try await series.playInfoFromWebFallback(vid: ep.vid)
                let asset = AVURLAsset(url: info.url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Referer": Site.referer, "User-Agent": info.userAgent]])
                let (playable, duration) = try await asset.load(.isPlayable, .duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let size = try await tracks.first?.load(.naturalSize)
                report.append("ep\(index): playable=\(playable) \(Int(duration.seconds))s \(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")
            } catch {
                report.append("ep\(index): failed \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
        print("FALLBACK\n" + report.joined(separator: "\n"))
    }
}

/// `HONGGUO_LIVE=1 swift test --filter PlayShapeLiveTests`: a handful of read-only play-model
/// requests that differ only in request shape (trailing slash, official iOS biz_param fields),
/// one registered device. Prints outcome only.
final class PlayShapeLiveTests: XCTestCase {
    func testShapes() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let vid = env["HONGGUO_VID"] ?? "7694243705045126169"
        let transport = AppTransport(http: .shared)
        let identity = try await AppSearchIdentity.shared.get(transport: transport)
        let base: [String: Any] = ["detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
                                   "disable_video_relate_book": false, "need_all_video_definition": true, "need_mp4_align": false,
                                   "use_os_player": false, "use_server_dns": false, "video_platform": 1024]
        var ios = base
        ios["video_id_type"] = 0
        ios["screen_width_px"] = 1290
        ios["device_level"] = 4
        let variants: [(String, [String: Any], Bool)] = [
            ("current", base, false), ("trailing slash", base, true), ("iOS biz fields + slash", ios, true),
        ]
        var report: [String] = []
        for (name, biz, slash) in variants {
            let object: [String: Any] = ["biz_param": biz, "mixed_video_id_map": ["1004": [vid]], "dr_scene": "player"]
            let payload = Array(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            var signed = try await AppSource.shared.playbackRequest(payload: payload, identity: identity, modern: true)
            if slash { signed.url = signed.url.replacingOccurrences(of: "/player/v1?", with: "/player/v1/?") }
            do {
                let json = try await transport.requestJSON(signed.url, method: "POST", headers: signed.headers, body: signed.body,
                                                           deadline: Date().addingTimeInterval(10))
                report.append("\(name): code=\(json["code"].number.map { String($0) } ?? "-") data keys=\(json["data"].object?.keys.sorted().prefix(4).joined(separator: ",") ?? "-")")
            } catch let error as AppSourceError {
                report.append("\(name): \(error.code.rawValue)")
            }
            try await Task.sleep(for: .seconds(2))
        }
        print("SHAPES\n" + report.joined(separator: "\n"))
    }
}

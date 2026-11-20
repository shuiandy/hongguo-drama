// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// `HONGGUO_LIVE=1 swift test --filter DetailShapeLiveTests` (optional `HONGGUO_SID=<series id>`
/// or `HONGGUO_PROBE=关键词`): about ten read-only series detail requests (the episode list) that
/// differ only in host, path and body, with the persistent device, its token and the iOS 7.4.3
/// profile. Prints outcome, keys and counts only (no signed addresses, no device identity). Run it
/// when the episode list comes back empty, before blaming signatures or the device.
final class DetailShapeLiveTests: XCTestCase {
    private struct Variant {
        var name: String
        var host: String
        var path: String
        var body: [String: Any]
        var query: [(String, String)] = []
    }

    func testDetailShapes() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var report: [String] = []
        let seriesId: String
        if let sid = env["HONGGUO_SID"], !sid.isEmpty {
            seriesId = sid
        } else {
            let keyword = env["HONGGUO_PROBE"] ?? "入学第一天"
            let page = try await AppSearchService().search(keyword)
            guard let first = page.results.first else { throw XCTSkip("App search found nothing for the probe keyword") }
            seriesId = first.seriesId
            report.append("series from search: \(first.title) eps=\(first.episodeCount)")
        }

        let transport = AppTransport(http: .shared)
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()

        // The body the core sends today, and one shaped like the working play-model body.
        let current: [String: Any] = [
            "biz_param": ["detail_page_version": 0, "disable_digg_stat": false, "need_all_video_definition": false,
                          "need_mp4_align": false, "source": 7, "use_os_player": false, "use_server_dns": false],
            "dr_scene": "player", "series_id": seriesId,
        ]
        let ios: [String: Any] = [
            "biz_param": ["detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
                          "disable_video_relate_book": false, "need_all_video_definition": false, "need_mp4_align": false,
                          "use_os_player": false, "use_server_dns": false, "video_platform": 1024],
            "dr_scene": "player", "series_id": seriesId,
        ]
        let b = "api5-normal-sinfonlineb.fqnovel.com", a = "api5-normal-sinfonlinea.fqnovel.com", r = "reading.snssdk.com"
        let plain = "/novel/player/multi_video_detail/v1/", scene = "/novel/player/multi_video_detail/player/v1/"
        let single = "/novel/player/video_detail/v1/"
        let variants: [Variant] = [
            Variant(name: "b plain current", host: b, path: plain, body: current),
            Variant(name: "b plain ios", host: b, path: plain, body: ios),
            Variant(name: "b scene current", host: b, path: scene, body: current),
            Variant(name: "b scene ios", host: b, path: scene, body: ios),
            Variant(name: "b single ios", host: b, path: single, body: ios),
            Variant(name: "a plain current", host: a, path: plain, body: current),
            Variant(name: "a scene ios", host: a, path: scene, body: ios),
            Variant(name: "r plain current", host: r, path: plain, body: current),
            Variant(name: "b plain ios +query sid", host: b, path: plain, body: ios, query: [("series_id", seriesId)]),
        ]
        for variant in variants {
            do {
                let payload = try AppCrypto.gzip(Array(try JSONSerialization.data(withJSONObject: variant.body, options: [.sortedKeys])))
                let signed = try PlaybackSignerV5.shared.sign(
                    base: "https://\(variant.host)\(variant.path)",
                    values: AppSource.iosProfile + [("iid", identity.iid), ("cdid", identity.cdid), ("device_id", identity.deviceId)] + variant.query,
                    body: payload,
                    nowMillis: Int64(Date().timeIntervalSince1970 * 1000)
                )
                let headers = signed.headers + [
                    ("User-Agent", AppSource.iosPlayerUA), ("Accept", "application/json"),
                    ("Content-Type", "application/json; charset=utf-8"), ("Content-Encoding", "gzip"),
                    ("x-ss-dp", "8662"), ("sdk-version", "2"),
                ] + dToken
                let json = try await transport.requestJSON(signed.url, method: "POST", headers: headers, body: payload,
                                                           deadline: Date().addingTimeInterval(10))
                let vd = json["data"][seriesId]["video_data"]
                let code = json["code"].number.map { String(Int($0)) } ?? "-"
                let message = (json["message"].string ?? json["msg"].string ?? "").prefix(30)
                let keys = json["data"].object?.keys.sorted().prefix(4).map { $0 == seriesId ? "<sid>" : $0 }.joined(separator: ",") ?? "-"
                report.append("\(variant.name): code=\(code) msg=\(message) data=\(keys) list=\(vd["video_list"].array?.count ?? -1) cnt=\(EpisodeSocialService.integer(vd["episode_cnt"]) ?? -1)")
            } catch let error as AppSourceError {
                report.append("\(variant.name): \(error.code.rawValue) status=\(error.status.map(String.init) ?? "-")")
            } catch {
                report.append("\(variant.name): \(error)")
            }
            try await Task.sleep(for: .seconds(1))
        }
        print("DETAIL\n" + report.joined(separator: "\n"))
    }
}

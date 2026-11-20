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

    /// `--filter DetailShapeLiveTests/testPlayReplyShape` (optional `HONGGUO_VID`): what the working
    /// play-model reply carries besides the model (in case it holds series facts or the episode
    /// list), plus the detail path asked with GET. Three requests.
    func testPlayReplyShape() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let vid = env["HONGGUO_VID"] ?? "7694243705045126169"
        let transport = AppTransport(http: .shared)
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
        var report: [String] = []

        let request = try AppSource.modelRequest(base: AppSource.playerAPI, payload: try AppSource.modelPayload(vids: [vid]), identity: identity)
        var seriesId = env["HONGGUO_SID"] ?? ""
        do {
            let json = try await transport.requestJSON(request.url, method: "POST", headers: request.headers + dToken,
                                                       body: request.body, deadline: Date().addingTimeInterval(10))
            report.append("top: \(EmptySourceProbeLiveTests.shape(json, depth: 1))")
            let data = json["data"]
            report.append("data: \(EmptySourceProbeLiveTests.shape(data, depth: 1))")
            let group = data["1004"].isNull ? data : data["1004"]
            if let entry = group[vid].object {
                for key in entry.keys.sorted() where key != "video_model" {
                    report.append("entry.\(key): \(EmptySourceProbeLiveTests.shape(entry[key]!, depth: 1))")
                }
                if seriesId.isEmpty { seriesId = entry["series_id"]?.idString ?? entry["video_detail"]?["series_id"].idString ?? "" }
            } else {
                report.append("entry for vid missing; group keys=\(group.object?.keys.count ?? -1)")
            }
        } catch let error as AppSourceError {
            report.append("play model: \(error.code.rawValue) status=\(error.status.map(String.init) ?? "-")")
        }

        if !seriesId.isEmpty {
            for host in ["api5-normal-sinfonlineb.fqnovel.com", "reading.snssdk.com"] {
                try await Task.sleep(for: .seconds(1))
                let name = "GET \(host.prefix(20)) detail"
                do {
                    let signed = try PlaybackSignerV5.shared.sign(
                        base: "https://\(host)/novel/player/multi_video_detail/v1/",
                        values: AppSource.iosProfile + [("iid", identity.iid), ("cdid", identity.cdid), ("device_id", identity.deviceId),
                                                        ("series_id", seriesId), ("dr_scene", "player")],
                        body: [], nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
                    let json = try await transport.requestJSON(signed.url, method: "GET",
                                                               headers: signed.headers + [("User-Agent", AppSource.iosPlayerUA), ("Accept", "application/json"),
                                                                                          ("x-ss-dp", "8662"), ("sdk-version", "2")] + dToken,
                                                               deadline: Date().addingTimeInterval(10))
                    let vd = json["data"][seriesId]["video_data"]
                    report.append("\(name): code=\(json["code"].number.map { String(Int($0)) } ?? "-") list=\(vd["video_list"].array?.count ?? -1) top=\(EmptySourceProbeLiveTests.shape(json, depth: 1))")
                } catch let error as AppSourceError {
                    report.append("\(name): \(error.code.rawValue) status=\(error.status.map(String.init) ?? "-")")
                } catch {
                    report.append("\(name): \(error)")
                }
            }
        } else {
            report.append("no series id from the play reply; set HONGGUO_SID to try GET")
        }
        print("PLAYREPLY\n" + report.joined(separator: "\n"))
    }

    /// `--filter DetailShapeLiveTests/testOfficialDetailRoutes` (optional `HONGGUO_SID` or
    /// `HONGGUO_PROBE`, and `HONGGUO_GET_KEYS=series_id,series_ids`): the other detail routes in the official 7.4.3
    /// binary's RPC table: GET `/reading/bookapi/video_tab/{multi_video_detail,video_detail}/v1/`
    /// (legacy query signature, as the bookapi reads use) and POST
    /// `/novel/player/multi_video_detail/dynamic_data/v1/` and `/novel/player/album_detail/v1/`.
    func testOfficialDetailRoutes() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var seriesId = env["HONGGUO_SID"] ?? ""
        if !seriesId.matchesDigits(min: 6, max: 30) {
            guard let first = try await AppSearchService().search(env["HONGGUO_PROBE"] ?? "入学第一天").results.first else {
                throw XCTSkip("set HONGGUO_SID")
            }
            seriesId = first.seriesId
        }
        let keys = (env["HONGGUO_GET_KEYS"] ?? "series_id,series_ids,video_series_ids").split(separator: ",").map(String.init)
        let transport = AppTransport(http: .shared)
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
        let dTokenValue = dToken.first { $0.0.lowercased() == "x-tt-dt" }?.1 ?? ""
        var report: [String] = []

        func describe(_ json: JSONValue) -> String {
            let code = (json["code"].number ?? json["Code"].number).map { String(Int($0)) } ?? "-"
            let message = (json["message"].string ?? json["msg"].string ?? "").prefix(30)
            let data = json["data"]
            let vd = data[seriesId]["video_data"].isNull ? data["video_data"] : data[seriesId]["video_data"]
            let list = vd["video_list"].array?.count ?? data["video_list"].array?.count ?? -1
            return "code=\(code) msg=\(message) list=\(list) data=\(EmptySourceProbeLiveTests.shape(data, depth: 1).replacingOccurrences(of: seriesId, with: "<sid>").prefix(300))"
        }

        func legacyGET(host: String, path: String, values: [(String, String)]) throws -> (url: String, headers: [(String, String)]) {
            let signer = AppLegacySigner.shared
            let device = AppLegacySigner.merged(AppLegacySigner.versioned("72232", "7.2.2.32"),
                                                [("iid", identity.iid), ("device_id", identity.deviceId), ("cdid", identity.cdid)])
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let ts = UInt32(now / 1000)
            let fields = AppLegacySigner.merged(values, device)
            for n in 0..<128 {
                let ticket = String(now + Int64(n))
                let query = AppCrypto.encodeQuery(fields + [("ts", String(ts)), ("_rticket", ticket)])
                let url = "https://\(host)\(path)?\(query)"
                guard AppLegacySigner.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: [UInt8](repeating: 0, count: 16), ts: ts) == 0 else { continue }
                return (url, [
                    ("User-Agent", AppLegacySigner.searchUA), ("Accept", "application/json; charset=utf-8,application/x-protobuf"),
                    ("x-ss-req-ticket", ticket), ("x-tt-request-tag", "t=0;n=0"), ("sdk-version", "2"),
                    ("passport-sdk-version", "50561"), ("x-xs-from-web", "0"), ("x-khronos", String(ts)),
                    ("x-ladon", AppCrypto.base64(AppCrypto.be32Bytes(ts))), ("x-argus", AppCrypto.base64(AppCrypto.le32(ts))),
                    ("x-gorgon", AppLegacySigner.xGorgon(query: query, body: nil, ts: ts, random: signer.random32() >> 16)),
                    ("x-helios", signer.helios(ts: ts)),
                    ("x-medusa", try signer.medusa(url: url, body: nil, ts: ts, deviceId: identity.deviceId, versionName: "7.2.2.32", nowMillis: now)),
                    ("x-tt-dt", dTokenValue),
                ])
            }
            throw HongguoError(.format, "no legacy signature branch")
        }

        let b = "api5-normal-sinfonlineb.fqnovel.com"
        var gets: [(String, String, [(String, String)])] = keys.map { ("/reading/bookapi/video_tab/multi_video_detail/v1/", $0, [($0, seriesId)]) }
        gets.append(("/reading/bookapi/video_tab/video_detail/v1/", keys[0], [(keys[0], seriesId)]))
        for (path, key, values) in gets {
            let name = "GET \(path.replacingOccurrences(of: "/reading/bookapi/video_tab/", with: "video_tab/")) ?\(key)"
            do {
                let request = try legacyGET(host: b, path: path, values: values)
                let json = try await transport.requestJSON(request.url, headers: request.headers, deadline: Date().addingTimeInterval(10))
                report.append("\(name): \(describe(json))")
            } catch let error as AppSourceError {
                report.append("\(name): \(error.code.rawValue) status=\(error.status.map(String.init) ?? "-")")
            } catch {
                report.append("\(name): \(error)")
            }
            try await Task.sleep(for: .seconds(1))
        }

        let body: [String: Any] = [
            "biz_param": ["detail_page_version": 0, "disable_digg_stat": false, "need_all_video_definition": false,
                          "need_mp4_align": false, "source": 7, "use_os_player": false, "use_server_dns": false],
            "dr_scene": "player", "series_id": seriesId,
        ]
        for path in ["/novel/player/multi_video_detail/dynamic_data/v1/", "/novel/player/album_detail/v1/"] {
            let name = "POST \(path.replacingOccurrences(of: "/novel/player/", with: ""))"
            do {
                let payload = try AppCrypto.gzip(Array(try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])))
                let signed = try PlaybackSignerV5.shared.sign(
                    base: "https://\(b)\(path)",
                    values: AppSource.iosProfile + [("iid", identity.iid), ("cdid", identity.cdid), ("device_id", identity.deviceId)],
                    body: payload, nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
                let json = try await transport.requestJSON(signed.url, method: "POST", headers: signed.headers + [
                    ("User-Agent", AppSource.iosPlayerUA), ("Accept", "application/json"),
                    ("Content-Type", "application/json; charset=utf-8"), ("Content-Encoding", "gzip"),
                    ("x-ss-dp", "8662"), ("sdk-version", "2"),
                ] + dToken, body: payload, deadline: Date().addingTimeInterval(10))
                report.append("\(name): \(describe(json))")
            } catch let error as AppSourceError {
                report.append("\(name): \(error.code.rawValue) status=\(error.status.map(String.init) ?? "-")")
            } catch {
                report.append("\(name): \(error)")
            }
            try await Task.sleep(for: .seconds(1))
        }
        print("ROUTES\n" + report.joined(separator: "\n"))
    }

    /// `--filter DetailShapeLiveTests/testOfficialFieldNames` (optional `HONGGUO_SID` or `HONGGUO_PROBE`):
    /// the series detail, album and video data routes asked with the field names the official 7.4.3
    /// binary's request classes declare (`SSVideoDetailRequest.video_series_id/vs_id_type/source`,
    /// `FQVMGetVideoDetailV2Request.video_content_type`, `GetVideoAlbumDetailRequest.series_ids`,
    /// `SSMGetVideoDataRequest.vid_series_id`). Seven App requests plus one website page for a vid.
    /// Prints codes and reply shapes only.
    func testOfficialFieldNames() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        var seriesId = env["HONGGUO_SID"] ?? ""
        if !seriesId.matchesDigits(min: 6, max: 30) {
            guard let first = try await AppSearchService().search(env["HONGGUO_PROBE"] ?? "入学第一天").results.first else {
                throw XCTSkip("set HONGGUO_SID")
            }
            seriesId = first.seriesId
        }
        let page = try await SitePages.seriesPage(seriesId)
        let vids = page["seriesDetail"]["vid_list"].array?.compactMap(\.idString) ?? []
        let vid = env["HONGGUO_VID"] ?? vids.first ?? ""
        let transport = AppTransport(http: .shared)
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
        let dTokenValue = dToken.first { $0.0.lowercased() == "x-tt-dt" }?.1 ?? ""
        var report = ["web vid_list=\(vids.count)"]

        func describe(_ json: JSONValue) -> String {
            let code = (json["code"].number ?? json["Code"].number).map { String(Int($0)) } ?? "-"
            let message = (json["message"].string ?? json["msg"].string ?? "").prefix(30)
            let data = json["data"]
            let vd = data[seriesId]["video_data"].isNull ? data["video_data"] : data[seriesId]["video_data"]
            let list = vd["video_list"].array?.count ?? data["video_list"].array?.count ?? -1
            var text = "code=\(code) msg=\(message) list=\(list) data=\(EmptySourceProbeLiveTests.shape(data, depth: 0))"
            if let entry = (data[seriesId].object != nil ? data[seriesId] : data[vid].object != nil ? data[vid] : vd).object {
                text += " entry=\(EmptySourceProbeLiveTests.shape(.object(entry), depth: 1))"
            }
            if let first = vd["video_list"].array?.first ?? data["video_list"].array?.first {
                text += " item=\(EmptySourceProbeLiveTests.shape(first, depth: 1))"
            }
            return text.replacingOccurrences(of: seriesId, with: "<sid>").replacingOccurrences(of: vid.isEmpty ? "\u{0}" : vid, with: "<vid>").prefix(900).description
        }

        func legacyGET(_ path: String, _ values: [(String, String)]) throws -> (url: String, headers: [(String, String)]) {
            let signer = AppLegacySigner.shared
            let device = AppLegacySigner.merged(AppLegacySigner.versioned("72232", "7.2.2.32"),
                                                [("iid", identity.iid), ("device_id", identity.deviceId), ("cdid", identity.cdid)])
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let ts = UInt32(now / 1000)
            let fields = AppLegacySigner.merged(values, device)
            for n in 0..<128 {
                let ticket = String(now + Int64(n))
                let query = AppCrypto.encodeQuery(fields + [("ts", String(ts)), ("_rticket", ticket)])
                let url = "https://api5-normal-sinfonlineb.fqnovel.com\(path)?\(query)"
                guard AppLegacySigner.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: [UInt8](repeating: 0, count: 16), ts: ts) == 0 else { continue }
                return (url, [
                    ("User-Agent", AppLegacySigner.searchUA), ("Accept", "application/json; charset=utf-8,application/x-protobuf"),
                    ("x-ss-req-ticket", ticket), ("x-tt-request-tag", "t=0;n=0"), ("sdk-version", "2"),
                    ("passport-sdk-version", "50561"), ("x-xs-from-web", "0"), ("x-khronos", String(ts)),
                    ("x-ladon", AppCrypto.base64(AppCrypto.be32Bytes(ts))), ("x-argus", AppCrypto.base64(AppCrypto.le32(ts))),
                    ("x-gorgon", AppLegacySigner.xGorgon(query: query, body: nil, ts: ts, random: signer.random32() >> 16)),
                    ("x-helios", signer.helios(ts: ts)),
                    ("x-medusa", try signer.medusa(url: url, body: nil, ts: ts, deviceId: identity.deviceId, versionName: "7.2.2.32", nowMillis: now)),
                    ("x-tt-dt", dTokenValue),
                ])
            }
            throw HongguoError(.format, "no legacy signature branch")
        }

        func post(_ path: String, _ body: [String: Any]) async throws -> JSONValue {
            let payload = try AppCrypto.gzip(Array(try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])))
            let signed = try PlaybackSignerV5.shared.sign(
                base: "https://api5-normal-sinfonlineb.fqnovel.com\(path)",
                values: AppSource.iosProfile + [("iid", identity.iid), ("cdid", identity.cdid), ("device_id", identity.deviceId)],
                body: payload, nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
            return try await transport.requestJSON(signed.url, method: "POST", headers: signed.headers + [
                ("User-Agent", AppSource.iosPlayerUA), ("Accept", "application/json"),
                ("Content-Type", "application/json; charset=utf-8"), ("Content-Encoding", "gzip"),
                ("x-ss-dp", "8662"), ("sdk-version", "2"),
            ] + dToken, body: payload, deadline: Date().addingTimeInterval(10))
        }

        func run(_ name: String, _ work: () async throws -> JSONValue) async {
            do { report.append("\(name): \(describe(try await work()))") }
            catch let error as AppSourceError { report.append("\(name): \(error.code.rawValue) status=\(error.status.map(String.init) ?? "-")") }
            catch { report.append("\(name): \(error)") }
            try? await Task.sleep(for: .seconds(1))
        }

        let tab = "/reading/bookapi/video_tab/"
        for (path, idType) in [("multi_video_detail", "0"), ("multi_video_detail", "1"), ("video_detail", "0")] {
            await run("GET \(path) vs_id_type=\(idType)") {
                let request = try legacyGET(tab + path + "/v1/", [("video_series_id", seriesId), ("vs_id_type", idType), ("source", "0")])
                return try await transport.requestJSON(request.url, headers: request.headers, deadline: Date().addingTimeInterval(10))
            }
        }
        let biz: [String: Any] = ["detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
                                  "disable_video_relate_book": false, "need_all_video_definition": false, "need_mp4_align": false,
                                  "source": 7, "use_os_player": false, "use_server_dns": false, "video_id_type": 0, "video_platform": 1024]
        for contentType in [1, 1004] {
            await run("POST multi_video_detail video_content_type=\(contentType)") {
                try await post("/novel/player/multi_video_detail/v1/",
                               ["biz_param": biz, "dr_scene": "player", "series_id": seriesId, "video_content_type": contentType])
            }
        }
        await run("POST album_detail series_ids") {
            try await post("/novel/player/album_detail/v1/", ["series_ids": [seriesId], "need_video_detail_info": true])
        }
        if !vid.isEmpty {
            await run("POST multi_video_data/get vid_series_id") {
                try await post("/reading/bookapi/multi_video_data/get/v1/", ["vid_series_id": [vid: seriesId]])
            }
        }
        print("FIELDS\n" + report.joined(separator: "\n"))
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Opt-in probe for series whose episodes come back empty from the play source (the official iOS
/// client's, the only one): `HONGGUO_LIVE=1 HONGGUO_PROBE="关键词" swift test --filter EmptySourceProbeLiveTests`.
/// Read-only, with the persistent device and no disk cache. Prints outcomes, key names and short
/// scalar values only (no signed addresses, no device identity).
final class EmptySourceProbeLiveTests: XCTestCase {
    static func shape(_ value: JSONValue, depth: Int = 0) -> String {
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
        let source = AuthenticatedPlaybackSource(diskCache: VideoModelDiskCache(fileURL: nil))
        let transport = AppTransport(http: .shared)
        var report: [String] = ["search channel \(search.channel.rawValue), \(search.results.count) results"]
        for summary in search.results.prefix(5) where summary.title.contains(keyword.prefix(4)) {
            report.append("== \(summary.title) id=\(summary.seriesId) eps=\(summary.episodeCount)")
            let list: SeriesEpisodes
            do {
                list = try await series.episodes(seriesId: summary.seriesId)
            } catch {
                report.append("   episodes: failed \((error as? LocalizedError)?.errorDescription ?? "\(error)")"); continue
            }
            report.append("   list \(list.episodes.count) eps")
            let picks = Array(Set([1, 2, list.episodes.count / 2, list.episodes.count - 1, list.episodes.count])).sorted().filter { $0 >= 1 && $0 <= list.episodes.count }
            for index in picks {
                let ep = list.episodes[index - 1]
                var line = "   ep\(index) vid(\(ep.vid.count)ch): "
                do {
                    let resolved = try await source.resolveWithMeta(vid: ep.vid, force: true)
                    line += "ok route=\(resolved.route) \(resolved.info.codec) \(resolved.info.quality?.shortSide ?? 0)p"
                } catch {
                    line += "failed \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                    // The raw reply of the scene path, for its shape.
                    do {
                        let identity = try await PersistentAppDevice.shared.get(transport: transport)
                        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
                        let request = try AppSource.modelRequest(base: AppSource.playerAPI,
                                                                 payload: try AppSource.modelPayload(vids: [ep.vid]), identity: identity)
                        let raw = try await transport.requestJSON(request.url, method: "POST", headers: request.headers + dToken,
                                                                  body: request.body, deadline: Date().addingTimeInterval(10))
                        line += "\n      raw: \(Self.shape(raw))"
                    } catch let error as AppSourceError {
                        line += "\n      raw: \(error.code.rawValue) status=\(error.status.map(String.init) ?? "-") \(error.message)"
                    }
                }
                report.append(line)
                try await Task.sleep(for: .milliseconds(600))
            }
        }
        print("PROBE\n" + report.joined(separator: "\n"))
    }
}

/// `HONGGUO_LIVE=1 swift test --filter PlayShapeLiveTests`: a handful of read-only play-model
/// requests that differ only in host and path (the official iOS 7.4.3 RPC table), with the
/// persistent device and the iOS profile. Prints outcome only. Try this before blaming signatures
/// when every reply is empty.
final class PlayShapeLiveTests: XCTestCase {
    func testShapes() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let vid = env["HONGGUO_VID"] ?? "7694243705045126169"
        let transport = AppTransport(http: .shared)
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
        let payload = try AppSource.modelPayload(vids: [vid])
        let hosts = ["api5-normal-sinfonlineb.fqnovel.com", "api5-normal-sinfonlinea.fqnovel.com", "reading.snssdk.com"]
        let paths = ["/novel/player/multi_video_model/player/v1/", "/novel/player/multi_video_model/v1/", "/novel/player/video_model/v1/"]
        var report: [String] = []
        for host in hosts {
            for path in paths {
                let name = "\(host.prefix(26)) \(path)"
                let request = try AppSource.modelRequest(base: "https://\(host)\(path)", payload: payload, identity: identity)
                do {
                    let json = try await transport.requestJSON(request.url, method: "POST", headers: request.headers + dToken,
                                                               body: request.body, deadline: Date().addingTimeInterval(10))
                    report.append("\(name): code=\(json["code"].number.map { String($0) } ?? "-") data keys=\(json["data"].object?.keys.sorted().prefix(4).joined(separator: ",") ?? "-")")
                } catch let error as AppSourceError {
                    report.append("\(name): \(error.code.rawValue)")
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
        // Whether the device token matters: the first route once more without it.
        let bare = try AppSource.modelRequest(base: AppSource.playerAPI, payload: payload, identity: identity)
        do {
            let json = try await transport.requestJSON(bare.url, method: "POST", headers: bare.headers, body: bare.body,
                                                       deadline: Date().addingTimeInterval(10))
            report.append("plain path without x-tt-dt: code=\(json["code"].number.map { String($0) } ?? "-")")
        } catch let error as AppSourceError {
            report.append("plain path without x-tt-dt: \(error.code.rawValue)")
        }
        // The play source itself, end to end, no cache.
        let source = AuthenticatedPlaybackSource(diskCache: VideoModelDiskCache(fileURL: nil))
        let started = Date()
        do {
            let resolved = try await source.resolveWithMeta(vid: vid, force: true)
            report.append("source: ok route=\(resolved.route) \(resolved.info.codec) \(resolved.info.quality?.shortSide ?? 0)p \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            report.append("source: failed \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        print("SHAPES\n" + report.joined(separator: "\n"))
    }
}

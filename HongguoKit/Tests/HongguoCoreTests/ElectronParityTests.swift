// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Features ported from the Electron app in the parity pass: proxy settings, series metadata and
/// the NAS layout, in-app update asset choice, comment danmaku, ByteVC2 arguments, merge naming.
final class ElectronParityTests: XCTestCase {
    func testProxyValidation() throws {
        var proxy = ProxySettings()
        XCTAssertNoThrow(try proxy.validate())   // direct needs nothing
        proxy.mode = .custom
        XCTAssertNoThrow(try proxy.validate())
        XCTAssertEqual(proxy.summary, "HTTP 127.0.0.1:7890")
        proxy.port = 70000
        XCTAssertThrowsError(try proxy.validate())
        proxy.port = 1080; proxy.host = "bad host/"
        XCTAssertThrowsError(try proxy.validate())
        proxy.host = "proxy.local"; proxy.kind = .socks5
        XCTAssertNoThrow(try proxy.validate())
        XCTAssertEqual(proxy.summary, "SOCKS5 proxy.local:1080")
    }

    func testProxyConfiguresSessions() {
        let config = URLSessionConfiguration.ephemeral
        NetworkProxy.configure(config, settings: ProxySettings(), password: "")
        XCTAssertEqual(config.connectionProxyDictionary?.isEmpty, true)
        XCTAssertTrue(config.proxyConfigurations.isEmpty)
        var system = ProxySettings(); system.mode = .system
        NetworkProxy.configure(config, settings: system, password: "")
        XCTAssertNil(config.connectionProxyDictionary)
        var custom = ProxySettings(); custom.mode = .custom; custom.username = "u"
        NetworkProxy.configure(config, settings: custom, password: "p")
        XCTAssertEqual(config.proxyConfigurations.count, 1)
    }

    func testSettingsDecodeOlderFile() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.proxy.mode, .direct)
        XCTAssertFalse(settings.searchAppFirst)
        XCTAssertFalse(settings.downloadMetadata)
        XCTAssertTrue(settings.byteVC2Conversion)
        XCTAssertEqual(settings.danmaku.source, .auto)
        var changed = settings
        changed.proxy.mode = .custom; changed.proxy.port = 1080; changed.danmaku.source = .comments
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(again.proxy.port, 1080)
        XCTAssertEqual(again.danmaku.source, .comments)
    }

    func testSeriesMetadataFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let series = SeriesMetadata.Series(seriesId: "7200000000000000001", title: "少夫人 <来自> 东北", description: "简介 & 剧情")
        let warnings = try await SeriesMetadata.writeSeries(series, into: directory)
        XCTAssertEqual(warnings, ["来源没有提供封面"])
        let nfo = try String(contentsOf: directory.appendingPathComponent("tvshow.nfo"), encoding: .utf8)
        XCTAssertTrue(nfo.contains("<title>少夫人 &lt;来自&gt; 东北</title>"))
        XCTAssertTrue(nfo.contains("<plot>简介 &amp; 剧情</plot>"))
        XCTAssertTrue(nfo.contains("<uniqueid type=\"hongguo\" default=\"true\">7200000000000000001</uniqueid>"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("简介.txt").path))
        // Another series must not be mixed into the same folder.
        let other = SeriesMetadata.Series(seriesId: "7200000000000000002", title: "别的剧")
        do { _ = try await SeriesMetadata.writeSeries(other, into: directory); XCTFail("expected refusal") } catch {}
        // The same series again keeps the files.
        _ = try await SeriesMetadata.writeSeries(series, into: directory)
    }

    func testImageSignature() {
        XCTAssertEqual(SeriesMetadata.imageExtension(Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertEqual(SeriesMetadata.imageExtension(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "png")
        XCTAssertEqual(SeriesMetadata.imageExtension(Data("RIFFxxxxWEBPVP8 ".utf8)), "webp")
        XCTAssertNil(SeriesMetadata.imageExtension(Data("<html>".utf8)))
    }

    func testNASLayout() {
        let root = URL(fileURLWithPath: "/Volumes/media/短剧", isDirectory: true)
        let episode = Episode(vid: "7300000000000000009", index: 7, title: "", seriesId: "7200000000000000001", webAvailable: nil)
        let layout = NASLayout(root: root, seriesTitle: "少夫人来自东北第二季", createFolder: true)
        XCTAssertEqual(layout.season, 2)
        XCTAssertEqual(layout.videoURL(for: episode).path, "/Volumes/media/短剧/少夫人来自东北第二季/Season 02/少夫人来自东北第二季 S02E007.mp4")
        XCTAssertEqual(layout.nfoURL(for: episode).lastPathComponent, "少夫人来自东北第二季 S02E007.nfo")
        let flat = NASLayout(root: root, seriesTitle: "某剧", createFolder: false)
        XCTAssertEqual(flat.season, 1)
        XCTAssertEqual(flat.videoURL(for: episode).path, "/Volumes/media/短剧/Season 01/某剧 S01E007.mp4")
        let nfo = SeriesMetadata.episodeNFO(seriesTitle: "某剧", episode: episode, season: 1)
        XCTAssertTrue(nfo.contains("<episode>7</episode>"))
        XCTAssertTrue(nfo.contains("<title>第7集</title>"))
    }

    func testReleaseAssetChoice() {
        func asset(_ name: String, digest: String? = "sha256:" + String(repeating: "ab", count: 32), host: String = "github.com") -> JSONValue {
            var object: [String: JSONValue] = ["name": .string(name), "size": .int(50_000_000),
                                               "browser_download_url": .string("https://\(host)/shuiandy/hongguo-drama/releases/download/v9/\(name)")]
            if let digest { object["digest"] = .string(digest) }
            return .object(object)
        }
        // Electron archives, files without a digest and foreign hosts are never chosen.
        XCTAssertNil(ReleaseAsset.pick([asset("红果短剧-9.0.0-arm64-mac.zip"), asset("HongguoDrama-9.0.0-universal.zip", digest: nil),
                                        asset("HongguoDrama-9.0.0-universal.zip", host: "evil.example.com"), asset("HongguoDrama-9.0.0.dmg")]))
        let picked = ReleaseAsset.pick([asset("HongguoDrama-9.0.0-universal.zip"), asset("HongguoDrama-9.0.0-arm64.zip"), asset("HongguoDrama-9.0.0-x86_64.zip")])
        #if arch(arm64)
        XCTAssertEqual(picked?.name, "HongguoDrama-9.0.0-arm64.zip")
        #else
        XCTAssertEqual(picked?.name, "HongguoDrama-9.0.0-x86_64.zip")
        #endif
        XCTAssertEqual(picked?.sha256, String(repeating: "ab", count: 32))
        let release: JSONValue = .object(["tag_name": .string("v9.0.0"), "assets": .array([asset("HongguoDrama-9.0.0-universal.zip")])])
        XCTAssertEqual(UpdateChecker.availableRelease(release, currentVersion: "7.5.0")?.asset?.name, "HongguoDrama-9.0.0-universal.zip")
    }

    func testUpdateArchiveDigest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try AppUpdateInstaller.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testCommentsAsDanmaku() {
        let comments = EpisodeComments(seriesId: "1", vid: "2",
                                       items: [.init(id: "a", content: "第一条\n换行"), .init(id: "b", content: "  "),
                                               .init(id: "c", content: String(repeating: "长", count: 80))],
                                       total: 3, likeCount: nil, notice: "")
        let unknown = comments.danmakuItems()
        XCTAssertEqual(unknown.map(\.time), [1, 4])
        XCTAssertEqual(unknown[0].text, "第一条 换行")
        XCTAssertEqual(unknown[1].text.count, 59)
        let spread = comments.danmakuItems(duration: 20)
        XCTAssertEqual(spread.map(\.time), [1, 9])
    }

    func testByteVC2Arguments() {
        let args = ByteVC2Converter.arguments(input: URL(fileURLWithPath: "/tmp/in.mp4"), output: URL(fileURLWithPath: "/tmp/out.mp4"),
                                              key: Array(0..<16), encoder: "libx264", fast: false)
        XCTAssertEqual(args[args.firstIndex(of: "-decryption_key")! + 1], "000102030405060708090a0b0c0d0e0f")
        XCTAssertTrue(args.firstIndex(of: "-decryption_key")! < args.firstIndex(of: "-i")!)
        XCTAssertEqual(args.last, "/tmp/out.mp4")
        XCTAssertTrue(args.contains("libx264"))
        let plain = ByteVC2Converter.arguments(input: URL(fileURLWithPath: "/tmp/in.mp4"), output: URL(fileURLWithPath: "/tmp/out.mp4"),
                                               key: nil, encoder: "h264_videotoolbox", fast: true)
        XCTAssertFalse(plain.contains("-decryption_key"))
        XCTAssertEqual(plain[plain.firstIndex(of: "-threads:v")! + 1], "4")
    }

    func testMergeOutputName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let full = MergeExporter.outputURL(directory: directory, seriesTitle: "某剧", count: 80, total: 80)
        XCTAssertEqual(full.lastPathComponent, "某剧 全集.mp4")
        XCTAssertEqual(MergeExporter.outputURL(directory: directory, seriesTitle: "某剧", count: 12, total: 80).lastPathComponent, "某剧 合并12集.mp4")
        try Data().write(to: full)
        XCTAssertEqual(MergeExporter.outputURL(directory: directory, seriesTitle: "某剧", count: 80, total: 80).lastPathComponent, "某剧 全集 (2).mp4")
    }

    func testDownloadToCustomDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-nas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = DownloadConfiguration(root: directory.appendingPathComponent("local"))
        config.maxConcurrent = 1
        let manager = DownloadManager(configuration: config, store: nil, resolver: NeverResolver(), transfer: URLSessionMediaTransfer())
        let episode = Episode(vid: "7300000000000000001", index: 1, title: "", seriesId: "7200000000000000001", webAvailable: nil)
        let target = directory.appendingPathComponent("nas/Season 01/某剧 S01E001.mp4")
        let queued = try await manager.enqueue(seriesId: "7200000000000000001", seriesTitle: "某剧", episodes: [episode], destination: { _ in target })
        XCTAssertEqual(queued, 1)
        let tasks = await manager.allTasks()
        XCTAssertEqual(tasks.first?.savePath, target.path)
        _ = await manager.pauseAll()
    }
}

private struct NeverResolver: PlayInfoResolving {
    func playInfo(vid: String, seriesId: String?, force: Bool) async throws -> PlayInfo {
        try await Task.sleep(for: .seconds(60))
        throw HongguoError(.unavailable, "not used")
    }
}

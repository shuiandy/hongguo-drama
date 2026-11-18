import XCTest
@testable import HongguoCore

final class DownloadNamingTests: XCTestCase {
    func testSanitizeAndRender() {
        XCTAssertEqual(DownloadNaming.sanitizeFolderName(" 剧名:<测试>/? . "), "剧名测试")
        XCTAssertEqual(DownloadNaming.sanitizeFolderName("CON"), "_CON")
        XCTAssertEqual(DownloadNaming.sanitizeFolderName(String(repeating: "长", count: 100)).count, 80)
        XCTAssertEqual(DownloadNaming.renderName(format: "剧名 集数", seriesTitle: "霸总", index: 7, episodeTitle: ""), "霸总 007")
        XCTAssertEqual(DownloadNaming.renderName(format: "series_title-vid_index-ep_title", seriesTitle: "A", index: 12, episodeTitle: "开端"), "A-012-开端")
        XCTAssertNil(DownloadNaming.renderName(format: "  ", seriesTitle: "A", index: 1, episodeTitle: ""))
        XCTAssertEqual(DownloadNaming.episodeFilename(format: "剧名 集数", seriesTitle: "霸总", index: 3, episodeTitle: ""), "霸总 003.mp4")
        XCTAssertEqual(DownloadNaming.episodeFilename(format: "剧名", seriesTitle: "霸总", index: 3, episodeTitle: ""), "霸总_第003集.mp4")
    }

    func testSeriesDirectoryMatchesElectron() {
        // sha256("7200000000000000002") prefix, as main.js seriesDownloadDir computes it.
        let dir = DownloadNaming.seriesDirectory(root: URL(fileURLWithPath: "/tmp/dl"), seriesId: "7200000000000000002", seriesTitle: "霸总/归来")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "红果短剧")
        XCTAssertTrue(dir.lastPathComponent.hasPrefix("霸总归来-"))
        XCTAssertEqual(dir.lastPathComponent.count, "霸总归来-".count + 12)
    }

    func testRangeDecision() {
        XCTAssertEqual(RangeDecision.decide(status: 206, offset: 100, contentRange: "bytes 100-999/1000", contentLength: 900, expectedTotal: 1000),
                       .append(total: 1000))
        XCTAssertEqual(RangeDecision.decide(status: 206, offset: 100, contentRange: "bytes 0-999/1000", contentLength: 1000, expectedTotal: nil),
                       .restart(total: nil))
        XCTAssertEqual(RangeDecision.decide(status: 206, offset: 100, contentRange: "bytes 100-999/2000", contentLength: 900, expectedTotal: 1000),
                       .restart(total: nil))
        XCTAssertEqual(RangeDecision.decide(status: 200, offset: 100, contentRange: nil, contentLength: 1000, expectedTotal: 1000),
                       .restart(total: 1000))
        XCTAssertEqual(RangeDecision.decide(status: 416, offset: 1000, contentRange: "bytes */1000", contentLength: nil, expectedTotal: nil),
                       .alreadyComplete(total: 1000))
        XCTAssertEqual(RangeDecision.decide(status: 503, offset: 0, contentRange: nil, contentLength: nil, expectedTotal: nil),
                       .failure(status: 503))
    }
}

/// Fake source: every episode resolves to a plain URL.
struct FakeResolver: PlayInfoResolving {
    var encrypted = false
    func playInfo(vid: String, seriesId: String?, force: Bool) async throws -> PlayInfo {
        PlayInfo(url: URL(string: "https://cdn.example.com/\(vid).mp4")!, spadeA: nil, codec: "h264", source: .app, vid: vid,
                 userAgent: "test", referer: nil, contentKey: encrypted ? Array(repeating: 7, count: 16) : nil)
    }
}

/// Fake transfer: writes `size` bytes in chunks, honours the existing partial file like a real
/// range request, and can be held at a gate to test pause and concurrency.
actor FakeTransfer: MediaTransferring {
    let size: Int64
    var gateOpen: Bool
    var active = 0
    var peak = 0
    var offsets: [Int64] = []
    var failuresLeft: Int

    init(size: Int64 = 1000, gateOpen: Bool = true, failures: Int = 0) {
        self.size = size; self.gateOpen = gateOpen; self.failuresLeft = failures
    }

    func open() { gateOpen = true }
    /// Polls so a cancelled (paused) transfer leaves the gate like a real cancelled request.
    private func waitGate() async throws {
        while !gateOpen { try await Task.sleep(for: .milliseconds(10)) }
    }

    nonisolated func transfer(_ request: MediaTransferRequest, to file: URL, onResponse: @escaping @Sendable (Int64, String?) -> Void,
                              progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MediaTransferResult {
        try await run(file: file, onResponse: onResponse, progress: progress)
    }

    private func run(file: URL, onResponse: @escaping @Sendable (Int64, String?) -> Void,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MediaTransferResult {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if failuresLeft > 0 { failuresLeft -= 1; throw HTTPMediaStatusError(status: 503) }
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        offsets.append(Int64(offset))
        onResponse(size, "\"etag\"")
        // First half, then wait at the gate, then the rest.
        let half = UInt64(size / 2)
        if offset < half {
            try handle.write(contentsOf: Data(repeating: 1, count: Int(half - offset)))
            offset = half
            progress(Int64(offset), size)
        }
        try await waitGate()
        try Task.checkCancellation()
        try handle.write(contentsOf: Data(repeating: 2, count: Int(UInt64(size) - offset)))
        progress(size, size)
        return MediaTransferResult(totalBytes: size, validator: "\"etag\"", resumed: offset > 0)
    }
}

final class DownloadManagerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func config(max: Int = 2) -> DownloadConfiguration {
        DownloadConfiguration(root: root, maxConcurrent: max, lookupSpacing: .zero, retryDelays: [.milliseconds(50)])
    }

    func episodes(_ n: Int) -> [Episode] {
        (1...n).map { Episode(vid: "73000000000000000\(String(format: "%02d", $0))", index: $0, title: "", seriesId: "7200000000000000002") }
    }

    func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out")
    }

    func testConcurrencyCapAndCompletion() async throws {
        let transfer = FakeTransfer(gateOpen: false)
        let store = JSONFileStore<[DownloadTask]>(directory: root, name: "downloads.json")
        let manager = DownloadManager(configuration: config(max: 2), store: store, resolver: FakeResolver(), transfer: transfer)
        let queued = try await manager.enqueue(seriesId: "7200000000000000002", seriesTitle: "测试剧", episodes: episodes(5))
        XCTAssertEqual(queued, 5)
        try await waitUntil { await transfer.active == 2 }
        let status = await manager.queueStatus()
        XCTAssertEqual(status.downloading, 2)
        XCTAssertEqual(status.pending, 3)
        await transfer.open()
        try await waitUntil { await manager.queueStatus().completed == 5 }
        let peak = await transfer.peak
        XCTAssertEqual(peak, 2)
        let tasks = await manager.allTasks()
        for task in tasks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: task.savePath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: task.partialURL.path))
            XCTAssertEqual(task.progress, 1)
        }
        let local = await manager.localFile(vid: tasks[0].vid)
        XCTAssertNotNil(local)
        // Persisted.
        XCTAssertEqual(store.load(default: []).filter { $0.status == .completed }.count, 5)
    }

    func testPauseKeepsPartialAndResumeContinues() async throws {
        let transfer = FakeTransfer(size: 1000, gateOpen: false)
        let manager = DownloadManager(configuration: config(max: 1), store: nil, resolver: FakeResolver(), transfer: transfer)
        try await manager.enqueue(seriesId: "7200000000000000002", seriesTitle: "测试剧", episodes: episodes(1))
        let id = await manager.allTasks()[0].id
        try await waitUntil { await manager.task(id)?.receivedBytes == 500 }
        await manager.pause(id)
        try await waitUntil { await transfer.active == 0 }
        let paused = await manager.task(id)!
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.validator, "\"etag\"")
        XCTAssertEqual(paused.totalBytes, 1000)
        XCTAssertEqual(DownloadManager.fileSize(paused.partialURL), 500)
        await transfer.open()
        await manager.resume(id)
        try await waitUntil { await manager.task(id)?.status == .completed }
        let offsets = await transfer.offsets
        XCTAssertEqual(offsets, [0, 500], "resume starts where the partial file ends")
        XCTAssertEqual(DownloadManager.fileSize(paused.fileURL), 1000)
    }

    func testTransientFailureRetriesAutomatically() async throws {
        let transfer = FakeTransfer(failures: 1)
        let manager = DownloadManager(configuration: config(), store: nil, resolver: FakeResolver(), transfer: transfer)
        try await manager.enqueue(seriesId: "7200000000000000002", seriesTitle: "测试剧", episodes: episodes(1))
        let id = await manager.allTasks()[0].id
        try await waitUntil { await manager.task(id)?.status == .completed }
        let task = await manager.task(id)!
        XCTAssertEqual(task.retryCount, 1)
    }

    func testEncryptedSourceIsDecryptedBeforePublishing() async throws {
        let transfer = FakeTransfer(size: 10)
        let manager = DownloadManager(configuration: config(), store: nil, resolver: FakeResolver(encrypted: true), transfer: transfer,
                                      decrypt: { data, key in
                                          XCTAssertEqual(key, Array(repeating: 7, count: 16))
                                          return Data(data.reversed()) + Data("ok".utf8)
                                      })
        try await manager.enqueue(seriesId: "7200000000000000002", seriesTitle: "测试剧", episodes: episodes(1))
        let id = await manager.allTasks()[0].id
        try await waitUntil { await manager.task(id)?.status == .completed }
        let task = await manager.task(id)!
        XCTAssertEqual(try Data(contentsOf: task.fileURL).suffix(2), Data("ok".utf8))
        XCTAssertEqual(task.totalBytes, 12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.partialURL.path))
    }

    func testDuplicatesAndInterruptedRestore() async throws {
        let transfer = FakeTransfer(gateOpen: false)
        let store = JSONFileStore<[DownloadTask]>(directory: root, name: "downloads.json")
        let manager = DownloadManager(configuration: config(max: 1), store: store, resolver: FakeResolver(), transfer: transfer)
        try await manager.enqueue(seriesId: "7200000000000000002", seriesTitle: "测试剧", episodes: episodes(2))
        let again = try await manager.enqueue(seriesId: "7200000000000000002", seriesTitle: "测试剧", episodes: episodes(2))
        XCTAssertEqual(again, 0, "queued episodes are not added twice")
        try await waitUntil { await transfer.active == 1 }
        // A new manager on the same file simulates relaunching after a quit mid-download.
        let relaunched = DownloadManager(configuration: config(), store: store, resolver: FakeResolver(), transfer: FakeTransfer())
        let restored = await relaunched.allTasks()
        XCTAssertEqual(Set(restored.map(\.status)), [.paused])
        XCTAssertTrue(restored.allSatisfy { $0.error?.contains("应用关闭") == true })
        await transfer.open()
    }

    func testRemoveDeletesPartialAndOptionallyFile() async throws {
        let manager = DownloadManager(configuration: config(), store: nil, resolver: FakeResolver(), transfer: FakeTransfer())
        try await manager.enqueue(seriesId: "7200000000000000002", seriesTitle: "测试剧", episodes: episodes(1))
        let task = await manager.allTasks()[0]
        try await waitUntil { await manager.task(task.id)?.status == .completed }
        let deleted = await manager.deleteFile(seriesId: task.seriesId, episodeIndex: 1)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.savePath))
        let status = await manager.task(task.id)?.status
        XCTAssertEqual(status, .paused)
        try await manager.remove([task.id])
        let remaining = await manager.allTasks()
        XCTAssertTrue(remaining.isEmpty)
    }
}

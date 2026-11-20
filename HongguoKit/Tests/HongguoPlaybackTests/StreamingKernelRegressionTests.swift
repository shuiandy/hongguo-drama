import Network
import XCTest
@testable import HongguoCore
@testable import HongguoPlayback

final class StreamingKernelRegressionTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kernel-reg-\(UUID().uuidString)")
    }

    private func makePlayInfo(
        vid: String = "7708645419428891673",
        url: String = "https://v3-cdn.example.com/media/clip_v1.mp4?auth_key=tokenA&expire=1760000000",
        codec: String = "h265",
        shortSide: Int = 720,
        keyByte: UInt8 = 0x1A,
        encrypted: Bool = true
    ) -> PlayInfo {
        var info = PlayInfo(
            url: URL(string: url)!,
            spadeA: nil,
            codec: codec,
            source: .app,
            vid: vid,
            userAgent: "TestUA/1.0",
            referer: nil
        )
        if encrypted {
            info.contentKey = Array(repeating: keyByte, count: 16)
        }
        info.quality = QualityOption(shortSide: shortSide)
        return info
    }

    // MARK: - Codex #1: Warmed loader reads newly written disk prefix bytes

    func testLoaderDynamicallyReadsExpandedDiskPrefixAfterCreation() {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MediaPrefixCache(directory: dir)
        let key = "vid1-720-abc123"

        // Initial warmed loader only has 512 KiB in memory.
        let initialSize = 512 * 1024
        let initialPrefix = MediaPrefixCache.Prefix(
            start: 0,
            data: Data(repeating: 0x11, count: initialSize),
            fromDisk: false
        )
        let loader = StreamingResourceLoader(
            source: URL(string: "https://v3-cdn.example.com/clip.mp4")!,
            headers: [:],
            map: nil,
            prefix: initialPrefix,
            prefixCacheKey: key,
            prefixCache: cache
        )

        // Request within initial 512 KiB hits in-memory prefix.
        let before = loader.resolvePrefixSlice(forInputRange: 0..<4096)
        XCTAssertEqual(before?.data.count, 4096)
        XCTAssertEqual(before?.fromDisk, false)

        // Beyond 512 KiB is not cached yet.
        XCTAssertNil(loader.resolvePrefixSlice(forInputRange: Int64(initialSize)..<Int64(initialSize + 4096)))

        // Background prefetch later writes 2 MiB unified prefix to disk.
        let expandedSize = 2 * 1024 * 1024
        var expanded = Data(repeating: 0x22, count: expandedSize)
        expanded[initialSize] = 0x7F
        cache.storeUnified(key: key, totalLength: 10_000_000, data: expanded)

        // Same loader instance now reads beyond its original 512 KiB straight from disk.
        let after = loader.resolvePrefixSlice(forInputRange: Int64(initialSize)..<Int64(initialSize + 4096))
        XCTAssertEqual(after?.data.count, 4096)
        XCTAssertEqual(after?.data.first, 0x7F)
        XCTAssertEqual(after?.fromDisk, true)

        // Spanning across the old 512 KiB boundary also upgrades and returns the full slice.
        let spanningStart = Int64(initialSize - 1024)
        let spanningEnd = Int64(initialSize + 1024)
        let spanning = loader.resolvePrefixSlice(forInputRange: spanningStart..<spanningEnd)
        XCTAssertEqual(spanning?.data.count, 2048)
        XCTAssertEqual(spanning?.fromDisk, true)
    }

    // MARK: - Codex #2: HTTP 200 (Range ignored) aborts on headers and maps to unsupportedLayout

    func testFastCencOpenerAbortsImmediatelyOnHTTP200FullFileResponse() async throws {
        MockHTTP200Protocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP200Protocol.self]

        let info = makePlayInfo(
            url: "https://mock-http200.example.com/full_1mib.mp4",
            encrypted: true
        )

        do {
            _ = try await FastCencOpener.open(
                info,
                candidates: [info.url],
                configuration: config,
                skipURLGuardForTesting: true,
                initialBytes: 512 * 1024
            )
            XCTFail("Expected FastCencOpenError.unsupportedLayout on HTTP 200")
        } catch let error as FastCencOpenError {
            if case .unsupportedLayout = error {
                // Expected: triggers whole-file fallback instead of marking media unavailable.
            } else {
                XCTFail("Expected .unsupportedLayout, got \(error)")
            }
            // Verify response was cancelled on headers without streaming the 1 MiB body.
            XCTAssertLessThan(MockHTTP200Protocol.bytesSent, 64 * 1024)
        }
    }

    // MARK: - Codex #3: Versioned MediaPrefixCache key isolates re-encodes while surviving URL renewal

    func testMediaPrefixCacheKeyReusesAcrossSignedQueryRenewalAndIsolatesAssetChanges() {
        let base = makePlayInfo(
            url: "https://v3-cdn.example.com/obj/video/clip_720.mp4?auth_key=sig1&expire=100",
            codec: "h265",
            shortSide: 720,
            keyByte: 0xAA
        )
        let renewed = makePlayInfo(
            url: "https://v9-other-edge.example.com/obj/video/clip_720.mp4?auth_key=sig2&expire=999",
            codec: "h265",
            shortSide: 720,
            keyByte: 0xAA
        )
        let differentCodec = makePlayInfo(
            url: "https://v3-cdn.example.com/obj/video/clip_720.mp4?auth_key=sig1&expire=100",
            codec: "h264",
            shortSide: 720,
            keyByte: 0xAA
        )
        let differentPath = makePlayInfo(
            url: "https://v3-cdn.example.com/obj/video/clip_720_reencoded.mp4?auth_key=sig1&expire=100",
            codec: "h265",
            shortSide: 720,
            keyByte: 0xAA
        )
        let differentKey = makePlayInfo(
            url: "https://v3-cdn.example.com/obj/video/clip_720.mp4?auth_key=sig1&expire=100",
            codec: "h265",
            shortSide: 720,
            keyByte: 0xBB
        )

        XCTAssertEqual(MediaPrefixCache.key(for: base), MediaPrefixCache.key(for: renewed))
        XCTAssertNotEqual(MediaPrefixCache.key(for: base), MediaPrefixCache.key(for: differentCodec))
        XCTAssertNotEqual(MediaPrefixCache.key(for: base), MediaPrefixCache.key(for: differentPath))
        XCTAssertNotEqual(MediaPrefixCache.key(for: base), MediaPrefixCache.key(for: differentKey))
    }

    // MARK: - Codex #4: CDN failover preserves remaining backup edges

    func testRotateCandidatesPreservesAllRemainingEdges() {
        let a = URL(string: "https://edge-a.example.com/clip.mp4")!
        let b = URL(string: "https://edge-b.example.com/clip.mp4")!
        let c = URL(string: "https://edge-c.example.com/clip.mp4")!

        XCTAssertEqual(EpisodeResolver.rotateCandidates([a, b, c], promoting: b), [b, c, a])
        XCTAssertEqual(EpisodeResolver.rotateCandidates([a, b, c], promoting: c), [c, a, b])
        XCTAssertEqual(EpisodeResolver.rotateCandidates([a, b, c], promoting: a), [a, b, c])

        let info = makePlayInfo(url: b.absoluteString, encrypted: false)
        let prepared = PreparedEpisode(
            info: info,
            mediaURLs: [b, c, a],
            map: nil,
            resolvedAt: Date(),
            sourceSeconds: 0.1,
            headerSeconds: 0.05,
            fromPrefetch: false
        )
        XCTAssertEqual(prepared.mediaURLs, [b, c, a])
        XCTAssertEqual(Array(prepared.mediaURLs.dropFirst()), [c, a])
    }

    // MARK: - Codex #5 & #8: RangeTransferState skip/resume, 206 start validation, clamping & truncated EOF

    func testRangeTransferStateResumeAfterSkipDisconnectUsesNextNeededOffset() {
        let oneMiB: Int64 = 1024 * 1024
        let twoMiB: Int64 = 2 * 1024 * 1024
        var state = RangeTransferState(start: oneMiB, inputEnd: twoMiB - 1)

        // CDN replies HTTP 200 from byte 0 even though player requested 1 MiB.
        XCTAssertTrue(state.acceptResponse(statusCode: 200, contentRange: nil))
        XCTAssertEqual(state.skip, oneMiB)
        XCTAssertEqual(state.streamOffset, 0)
        XCTAssertEqual(state.nextNeededOffset, oneMiB)

        // Client discards 256 KiB and disconnects before reaching 1 MiB.
        let discarded = state.consume(Data(repeating: 0x00, count: 256 * 1024))
        XCTAssertTrue(discarded.deliver.isEmpty)
        XCTAssertFalse(discarded.reachedEnd)
        XCTAssertEqual(state.streamOffset, 256 * 1024)
        XCTAssertEqual(state.nextNeededOffset, oneMiB)
        XCTAssertTrue(state.isTruncated)

        // Failover resume must ask the backup CDN from 1 MiB (NOT 256 KiB!).
        state.prepareResume()
        XCTAssertEqual(state.attemptStart, oneMiB)
        XCTAssertEqual(state.streamOffset, oneMiB)
        XCTAssertEqual(state.nextNeededOffset, oneMiB)
        XCTAssertEqual(state.skip, 0)
    }

    func testRangeTransferStateValidates206StartClamps200AndDetectsTruncatedEOF() {
        var state = RangeTransferState(start: 1000, inputEnd: 1499)

        // Mismatched 206 Content-Range start is rejected.
        XCTAssertFalse(state.acceptResponse(statusCode: 206, contentRange: "bytes 0-1499/5000"))
        XCTAssertFalse(state.acceptResponse(statusCode: 206, contentRange: nil))

        // Matching 206 start is accepted.
        XCTAssertTrue(state.acceptResponse(statusCode: 206, contentRange: "bytes 1000-1499/5000"))

        // Partial delivery leaves isTruncated == true.
        let part1 = state.consume(Data(repeating: 0x33, count: 200))
        XCTAssertEqual(part1.offset, 1000)
        XCTAssertEqual(part1.deliver.count, 200)
        XCTAssertFalse(part1.reachedEnd)
        XCTAssertTrue(state.isTruncated)
        XCTAssertEqual(state.nextNeededOffset, 1200)

        // Oversized chunk past finite inputEnd is strictly clamped to the remaining 300 bytes.
        let part2 = state.consume(Data(repeating: 0x44, count: 900))
        XCTAssertEqual(part2.offset, 1200)
        XCTAssertEqual(part2.deliver.count, 300)
        XCTAssertTrue(part2.reachedEnd)
        XCTAssertFalse(state.isTruncated)
        XCTAssertEqual(state.nextNeededOffset, 1500)
    }

    // MARK: - Codex #6: Cancelling background prefetch never cancels foreground waiter

    func testCancellingPrefetchDoesNotCancelJoinedForegroundViewer() async throws {
        let counter = LookupCounter()
        let gate = AsyncGate()
        let info = makePlayInfo(vid: "900001", encrypted: false)

        let resolver = EpisodeResolver { _, _, _, _, _ in
            await counter.increment()
            await gate.wait()
            try Task.checkCancellation()
            return (info, Date().addingTimeInterval(600), "mock-lookup")
        }

        // Background prefetch starts resolving vid 900001.
        let prefetchTask = Task {
            try await resolver.prepare(vid: "900001", seriesId: "s1", preferredShortSide: 720, prefetch: true)
        }
        await gate.waitUntilEntered()

        // Foreground viewer joins the exact same in-flight task.
        let viewerTask = Task {
            try await resolver.prepare(vid: "900001", seriesId: "s1", preferredShortSide: 720, prefetch: false)
        }
        try await Task.sleep(for: .milliseconds(30))

        // Cancelling the old prefetch must NOT cancel the shared task now owned by the viewer.
        prefetchTask.cancel()
        try await Task.sleep(for: .milliseconds(30))
        await gate.open()

        let prepared = try await viewerTask.value
        XCTAssertEqual(prepared.info.vid, "900001")
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testForegroundTargetMarkPreservesPrefetchAcrossCancelBeforeViewerEnters() async throws {
        let counter = LookupCounter()
        let gate = AsyncGate()
        let info = makePlayInfo(vid: "900002", encrypted: false)

        let resolver = EpisodeResolver { _, _, _, _, _ in
            await counter.increment()
            await gate.wait()
            try Task.checkCancellation()
            return (info, Date().addingTimeInterval(600), "mock-lookup")
        }

        let prefetchTask = Task {
            try await resolver.prepare(vid: "900002", seriesId: "s1", preferredShortSide: 720, prefetch: true)
        }
        await gate.waitUntilEntered()

        // Mirrors FeedModel.activate: synchronously mark foreground target, cancel old prefetch,
        // then start viewer prepare in an async Task.
        resolver.markForegroundTarget(vid: "900002", preferredShortSide: 720)
        prefetchTask.cancel()
        try await Task.sleep(for: .milliseconds(30))

        let viewerTask = Task {
            try await resolver.prepare(vid: "900002", seriesId: "s1", preferredShortSide: 720, prefetch: false)
        }
        try await Task.sleep(for: .milliseconds(30))
        await gate.open()

        let prepared = try await viewerTask.value
        XCTAssertEqual(prepared.info.vid, "900002")
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Codex #7: Expired seeds are rejected instead of re-accepted

    func testExpiredSeedIsRejectedAndFreshLookupRuns() async throws {
        let counter = LookupCounter()
        let staleInfo = makePlayInfo(vid: "900003", url: "https://cdn.example.com/old.mp4", encrypted: false)
        let freshInfo = makePlayInfo(vid: "900003", url: "https://cdn.example.com/new.mp4", encrypted: false)

        let resolver = EpisodeResolver { _, _, _, _, _ in
            await counter.increment()
            return (freshInfo, Date().addingTimeInterval(600), "mock-fresh")
        }

        await resolver.seed(staleInfo, expiresAt: Date().addingTimeInterval(-30), preferredShortSide: 720)
        let prepared = try await resolver.prepare(vid: "900003", seriesId: "s1", preferredShortSide: 720)
        XCTAssertEqual(prepared.info.url, freshInfo.url)
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Follow-up P1-1: Slow prefetch cannot overwrite a completed force refresh

    func testSlowPrefetchCannotOverwriteNewerForceRefresh() async throws {
        let oldGate = AsyncGate()
        let oldInfo = makePlayInfo(vid: "900010", url: "https://cdn.example.com/old.mp4", encrypted: false)
        let newInfo = makePlayInfo(vid: "900010", url: "https://cdn.example.com/new.mp4", encrypted: false)

        let resolver = EpisodeResolver { _, _, _, force, _ in
            if force {
                return (newInfo, Date().addingTimeInterval(600), "mock-force-new")
            }
            // Deliberately ignore Task cancellation so the stale lookup still returns `oldInfo`
            // after `force: true` has already completed.
            await oldGate.wait()
            return (oldInfo, Date().addingTimeInterval(600), "mock-slow-old")
        }

        // 1. Start slow background prefetch and pause it in flight.
        let slowPrefetch = Task {
            try await resolver.prepare(vid: "900010", seriesId: "s1", preferredShortSide: 720, prefetch: true)
        }
        await oldGate.waitUntilEntered()

        // 2. Complete a force refresh for the same episode.
        let forced = try await resolver.prepare(vid: "900010", seriesId: "s1", preferredShortSide: 720, force: true)
        XCTAssertEqual(forced.info.url, newInfo.url)

        // 3. Release the paused slow prefetch so it completes AFTER the force refresh.
        await oldGate.open()
        _ = try? await slowPrefetch.value

        // 4. Subsequent normal playback MUST still hit `newInfo` (never overwritten by `oldInfo`).
        let subsequent = try await resolver.prepare(vid: "900010", seriesId: "s1", preferredShortSide: 720)
        XCTAssertEqual(subsequent.info.url, newInfo.url)
    }

    func testOrdinaryReaderJoinsRefreshOfPreviouslyCachedEpisode() async throws {
        let gate = AsyncGate()
        let old = makePlayInfo(url: "https://example.invalid/old", encrypted: false)
        let new = makePlayInfo(url: "https://example.invalid/new", encrypted: false)
        let resolver = EpisodeResolver { _, _, _, force, _ in
            if force { await gate.wait() }
            return (force ? new : old, Date().addingTimeInterval(600), "fixture")
        }
        _ = try await resolver.prepare(vid: old.vid, seriesId: "1")
        let refresh = Task { try await resolver.prepare(vid: old.vid, seriesId: "1", force: true) }
        await gate.waitUntilEntered()
        let stale = await resolver.resolvedInfo(vid: old.vid, preferredShortSide: nil)
        XCTAssertNil(stale)
        let reader = Task { try await resolver.prepare(vid: old.vid, seriesId: "1") }
        await gate.open()
        let result = try await reader.value
        let refreshed = try await refresh.value
        XCTAssertEqual(result.info.url, new.url)
        XCTAssertEqual(refreshed.info.url, new.url)
    }

    func testRetiringPendingCastDoesNotInvalidateNewSelection() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("clip.mp4")
        let data = Data([1, 2, 3])
        try data.write(to: file)
        let media = LocalCastServer.Media.file(url: file, size: Int64(data.count))
        let gate = AsyncGate()
        let old = CastPublication(useLoopbackForTesting: true) { await gate.wait(); return media }
        await gate.waitUntilEntered()
        old.cancel()
        let new = CastPublication(useLoopbackForTesting: true) { media }
        defer { new.cancel() }
        async let first = new.url()
        async let second = new.url()
        let (url, duplicate) = try await (first, second)
        XCTAssertEqual(url, duplicate)
        await gate.open()
        do {
            _ = try await old.url()
            XCTFail("Retired selection published a URL")
        } catch is CancellationError {}
        let (received, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(received, data)
    }

    // MARK: - Follow-up P1-2: Whole-file PlaybackCache isolates media versions

    func testPlaybackCacheIsolatesMediaVersionsAndReusesAcrossURLRenewal() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PlaybackCache(directory: dir)

        let versionA = makePlayInfo(
            vid: "8001",
            url: "https://cdn-a.example.com/media/8001_v1.mp4?auth_key=sig1",
            codec: "h265",
            shortSide: 720,
            keyByte: 0x11
        )
        let versionARenewed = makePlayInfo(
            vid: "8001",
            url: "https://cdn-b.example.com/media/8001_v1.mp4?auth_key=sig2",
            codec: "h265",
            shortSide: 720,
            keyByte: 0x11
        )
        let versionB = makePlayInfo(
            vid: "8001",
            url: "https://cdn-a.example.com/media/8001_v2.mp4?auth_key=sig1",
            codec: "h264",
            shortSide: 720,
            keyByte: 0x22
        )

        let fileA = cache.fileURL(for: versionA)
        let fileB = cache.fileURL(for: versionB)
        XCTAssertNotEqual(fileA, fileB)
        XCTAssertEqual(fileA, cache.fileURL(for: versionARenewed))

        try Data("video-a".utf8).write(to: fileA)
        XCTAssertEqual(cache.cachedFile(for: versionA), fileA)
        XCTAssertEqual(cache.cachedFile(for: versionARenewed), fileA)
        XCTAssertNil(cache.cachedFile(for: versionB))
    }

    // MARK: - Follow-up P1-3: Plaintext Range EOF clamping & open-ended truncation detection

    func testRangeTransferStateFileTailClampingAndOpenEndedTruncation() {
        // Direction 1: Request 90...199 on a 100-byte file; server legally answers 90-99/100.
        var clamped = RangeTransferState(start: 90, inputEnd: 199)
        XCTAssertTrue(clamped.acceptResponse(statusCode: 206, contentRange: "bytes 90-99/100"))
        XCTAssertEqual(clamped.totalLength, 100)
        XCTAssertEqual(clamped.effectiveEnd, 99)

        let gotAll10 = clamped.consume(Data(repeating: 0xAA, count: 10))
        XCTAssertEqual(gotAll10.offset, 90)
        XCTAssertEqual(gotAll10.deliver.count, 10)
        XCTAssertTrue(gotAll10.reachedEnd)
        XCTAssertFalse(clamped.isTruncated)

        // Direction 2: Open-ended request 90... on a 100-byte file; server closes early at 90-94.
        var openEnded = RangeTransferState(start: 90, inputEnd: nil)
        XCTAssertTrue(openEnded.acceptResponse(statusCode: 206, contentRange: "bytes 90-99/100"))
        XCTAssertEqual(openEnded.effectiveEnd, 99)

        let partial5 = openEnded.consume(Data(repeating: 0xBB, count: 5))
        XCTAssertEqual(partial5.deliver.count, 5)
        XCTAssertFalse(partial5.reachedEnd)
        XCTAssertTrue(openEnded.isTruncated)

        openEnded.prepareResume()
        XCTAssertEqual(openEnded.attemptStart, 95)
        XCTAssertEqual(openEnded.nextNeededOffset, 95)

        // Direction 3: Open-ended HTTP 200 with Content-Length: 100 closing after 95 bytes.
        var open200 = RangeTransferState(start: 0, inputEnd: nil)
        XCTAssertTrue(open200.acceptResponse(statusCode: 200, contentRange: nil, expectedContentLength: 100))
        _ = open200.consume(Data(repeating: 0xCC, count: 95))
        XCTAssertTrue(open200.isTruncated)
        let last5 = open200.consume(Data(repeating: 0xCC, count: 5))
        XCTAssertTrue(last5.reachedEnd)
        XCTAssertFalse(open200.isTruncated)
    }

    // MARK: - Follow-up P2-1: FastCencOpener reuses TCP connections via shared URLSession

    func testFastCencOpenerReusesTCPConnectionAcrossOpens() async throws {
        let server = try LocalKeepAliveRangeServer()
        defer { server.stop() }
        let port = try await server.start()

        let info = makePlayInfo(
            url: "http://127.0.0.1:\(port)/clip.mp4",
            encrypted: true
        )

        // Each open gets a valid HTTP 206 response whose fake body has `mdat` at byte 0
        // (triggers structural `.unsupportedLayout` AFTER completing the 206 transfer cleanly,
        // returning the idle HTTP/1.1 keep-alive connection to SharedHeaderRangeSession).
        for _ in 0..<3 {
            do {
                _ = try await FastCencOpener.open(
                    info,
                    candidates: [info.url],
                    configuration: nil,
                    skipURLGuardForTesting: true,
                    initialBytes: 64
                )
                XCTFail("Expected structural unsupportedLayout on mdat-first test payload")
            } catch let error as FastCencOpenError {
                guard case .unsupportedLayout = error else {
                    XCTFail("Unexpected FastCencOpenError: \(error)")
                    return
                }
            }
        }

        XCTAssertEqual(server.requestCount, 3)
        XCTAssertEqual(server.acceptedConnectionCount, 1, "Shared URLSession should reuse 1 TCP connection across 3 opens")
    }

    // MARK: - Follow-up P2-2: FastCencOpener tries backup CDN when primary returns HTTP 200

    func testFastCencOpenerTriesBackupCDNAfterPrimaryHTTP200() async throws {
        MockFailoverAfter200Protocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockFailoverAfter200Protocol.self]

        let primary = URL(string: "https://edge-a-200.example.com/clip.mp4")!
        let backup = URL(string: "https://edge-b-200.example.com/clip.mp4")!
        let info = makePlayInfo(url: primary.absoluteString, encrypted: true)

        do {
            _ = try await FastCencOpener.open(
                info,
                candidates: [primary, backup],
                configuration: config,
                skipURLGuardForTesting: true,
                initialBytes: 64 * 1024
            )
            XCTFail("Expected unsupportedLayout when all edges fail Range")
        } catch let error as FastCencOpenError {
            guard case .unsupportedLayout = error else {
                XCTFail("Expected .unsupportedLayout, got \(error)")
                return
            }
        }

        XCTAssertEqual(MockFailoverAfter200Protocol.visitedHosts, [
            "edge-a-200.example.com",
            "edge-b-200.example.com",
        ])
    }

    // MARK: - Follow-up P2-3: Out-of-range reads past filled prefix never re-read or touch disk file

    func testOutOfRangeReadsPastFilledPrefixDoNotTouchDiskFile() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MediaPrefixCache(directory: dir)
        let key = "vid-filled-720-abcdef123456"

        let fullPrefix = Data(repeating: 0x5A, count: MediaPrefixCache.prefixBytes)
        let totalLength = Int64(MediaPrefixCache.prefixBytes * 3)
        cache.storeUnified(key: key, totalLength: totalLength, data: fullPrefix)

        let loaded = try XCTUnwrap(cache.load(key: key))
        let fileURL = dir.appendingPathComponent("\(key)@0+\(totalLength).bin")
        let sentinelDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: fileURL.path)

        let loader = StreamingResourceLoader(
            source: URL(string: "https://v3-cdn.example.com/clip.mp4")!,
            headers: [:],
            map: nil,
            prefix: loaded,
            prefixCacheKey: key,
            prefixCache: cache
        )

        // 16 out-of-range reads beyond 5 MiB must all return nil without reopening or touching mtime.
        let base = Int64(MediaPrefixCache.prefixBytes)
        for i in 0..<16 {
            let offset = base + Int64(i * 65_536)
            XCTAssertNil(loader.resolvePrefixSlice(forInputRange: offset..<(offset + 65_536)))
        }

        let afterDate = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(afterDate?.timeIntervalSince1970 ?? 0, sentinelDate.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Follow-up P2-4: MediaPrefixCache rejects misaligned/truncated 206 Range replies

    func testMediaPrefixCacheRejectsMisaligned206RangeResponses() {
        let start: Int64 = 524_288
        let total: Int64 = 10_000_000
        let maxEnd: Int64 = 5_242_879
        let expectedCount = Int(maxEnd - start + 1)

        // Exact match passes.
        XCTAssertTrue(MediaPrefixCache.validatePrefetchRangeResponse(
            statusCode: 206,
            contentRange: "bytes \(start)-\(maxEnd)/\(total)",
            expectedStart: start,
            expectedTotal: total,
            expectedMaxEnd: maxEnd,
            dataCount: expectedCount
        ))
        // Non-206 status fails.
        XCTAssertFalse(MediaPrefixCache.validatePrefetchRangeResponse(
            statusCode: 200,
            contentRange: "bytes \(start)-\(maxEnd)/\(total)",
            expectedStart: start,
            expectedTotal: total,
            expectedMaxEnd: maxEnd,
            dataCount: expectedCount
        ))
        // Misaligned start offset fails.
        XCTAssertFalse(MediaPrefixCache.validatePrefetchRangeResponse(
            statusCode: 206,
            contentRange: "bytes 0-\(expectedCount - 1)/\(total)",
            expectedStart: start,
            expectedTotal: total,
            expectedMaxEnd: maxEnd,
            dataCount: expectedCount
        ))
        // Mismatched total file length fails.
        XCTAssertFalse(MediaPrefixCache.validatePrefetchRangeResponse(
            statusCode: 206,
            contentRange: "bytes \(start)-\(maxEnd)/\(total + 1)",
            expectedStart: start,
            expectedTotal: total,
            expectedMaxEnd: maxEnd,
            dataCount: expectedCount
        ))
        // Truncated body shorter than declared Content-Range fails.
        XCTAssertFalse(MediaPrefixCache.validatePrefetchRangeResponse(
            statusCode: 206,
            contentRange: "bytes \(start)-\(maxEnd)/\(total)",
            expectedStart: start,
            expectedTotal: total,
            expectedMaxEnd: maxEnd,
            dataCount: expectedCount - 1024
        ))
    }
}

// MARK: - Offline Test Helpers

private actor LookupCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor AsyncGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        for cont in enteredWaiters { cont.resume() }
        enteredWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { cont in
            openWaiters.append(cont)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { cont in
            enteredWaiters.append(cont)
        }
    }

    func open() {
        isOpen = true
        for cont in openWaiters { cont.resume() }
        openWaiters.removeAll()
    }
}

private final class MockHTTP200Protocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _bytesSent = 0
    private var cancelled = false

    static var bytesSent: Int { lock.withLock { _bytesSent } }
    static func reset() { lock.withLock { _bytesSent = 0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock-http200.example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let total = 1024 * 1024
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(total)", "Content-Type": "video/mp4"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Stream chunks asynchronously so URLSession's header-cancel disposition aborts before sending 1 MiB.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.cancelled else { return }
            let chunk = Data(repeating: 0x55, count: 64 * 1024)
            Self.lock.withLock { Self._bytesSent += chunk.count }
            self.client?.urlProtocol(self, didLoad: chunk)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        cancelled = true
    }
}

private final class MockFailoverAfter200Protocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _visitedHosts: [String] = []

    static var visitedHosts: [String] { lock.withLock { _visitedHosts } }
    static func reset() { lock.withLock { _visitedHosts = [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "edge-a-200.example.com" || host == "edge-b-200.example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Self.lock.withLock { Self._visitedHosts.append(host) }
        let response: HTTPURLResponse
        if host == "edge-a-200.example.com" {
            response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "1048576", "Content-Type": "video/mp4"]
            )!
        } else {
            response = HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "0"]
            )!
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Minimal loopback HTTP/1.1 keep-alive server that serves 64-byte HTTP 206 replies with an
/// `mdat`-first MP4 box so `FastCencOpener` completes the Range transfer and exercises real
/// TCP connection reuse in `SharedHeaderRangeSession`.
private final class LocalKeepAliveRangeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.keepalive.range.server")
    private let lock = NSLock()
    private var _acceptedConnections = 0
    private var _requestCount = 0
    private var activeConnections: [NWConnection] = []

    var acceptedConnectionCount: Int { lock.withLock { _acceptedConnections } }
    var requestCount: Int { lock.withLock { _requestCount } }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let port = self?.listener.port?.rawValue {
                        resumed = true
                        cont.resume(returning: port)
                    }
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        let conns = lock.withLock { () -> [NWConnection] in
            let list = activeConnections
            activeConnections.removeAll()
            return list
        }
        conns.forEach { $0.cancel() }
    }

    private func handleConnection(_ conn: NWConnection) {
        lock.withLock {
            _acceptedConnections += 1
            activeConnections.append(conn)
        }
        conn.start(queue: queue)
        readLoop(conn, buffer: Data())
    }

    private func readLoop(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var acc = buffer
            if let data { acc.append(data) }
            let delimiter = Data("\r\n\r\n".utf8)
            while let range = acc.range(of: delimiter) {
                acc.removeSubrange(acc.startIndex..<range.upperBound)
                self.lock.withLock { self._requestCount += 1 }
                // 64-byte payload starting with an MP4 `mdat` box (size 64, type "mdat").
                var body = Data(repeating: 0, count: 64)
                body[3] = 64
                body[4] = UInt8(ascii: "m")
                body[5] = UInt8(ascii: "d")
                body[6] = UInt8(ascii: "a")
                body[7] = UInt8(ascii: "t")
                let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-63/4096\r\nContent-Length: 64\r\nConnection: keep-alive\r\n\r\n"
                var reply = Data(header.utf8)
                reply.append(body)
                conn.send(content: reply, completion: .contentProcessed { _ in })
            }
            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.readLoop(conn, buffer: acc)
        }
    }
}

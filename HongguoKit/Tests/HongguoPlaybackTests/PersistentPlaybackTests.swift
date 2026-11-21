import XCTest
@testable import HongguoCore
@testable import HongguoPlayback

final class PersistentPlaybackTests: XCTestCase {
    private func temporaryCacheFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("video-model-cache-\(UUID().uuidString).json")
    }

    private func samplePlayInfo(vid: String = "7708645419428891673", shortSide: Int = 1080) -> PlayInfo {
        var low = PlayInfo(
            url: URL(string: "https://v3-default.example.com/\(vid)_720.mp4")!,
            spadeA: nil,
            codec: "h265",
            source: .app,
            vid: vid,
            userAgent: "TestUA/1.0",
            referer: nil
        )
        low.contentKey = Array(repeating: 0x2A, count: 16)
        low.quality = QualityOption(shortSide: 720)

        var high = PlayInfo(
            url: URL(string: "https://v3-default.example.com/\(vid)_\(shortSide).mp4")!,
            spadeA: nil,
            codec: "h265",
            source: .app,
            vid: vid,
            userAgent: "TestUA/1.0",
            referer: nil
        )
        high.contentKey = Array(repeating: 0x1B, count: 16)
        high.quality = QualityOption(shortSide: shortSide)
        high.variants = [low]
        return high
    }

    // MARK: - PersistentAppDevice.StoredRecord (BDInstall 6h renewal rules)

    func testLegacyV1RecordDecodesAndRequiresRenewal() throws {
        let v1JSON = #"{"deviceId":"7600112233445566","iid":"7600998877665544","cdid":"11111111-2222-3333-4444-555555555555"}"#
        let record = try XCTUnwrap(PersistentAppDevice.decodeRecord(Data(v1JSON.utf8)))
        XCTAssertEqual(record.deviceId, "7600112233445566")
        XCTAssertEqual(record.iid, "7600998877665544")
        XCTAssertNil(record.deviceToken)
        XCTAssertNil(record.isActivated)
        XCTAssertNil(record.lastRegisteredAt)
        XCTAssertTrue(record.needsRenewal())
    }

    func testFreshActivatedRecordDoesNotNeedRenewalUntilSixHours() {
        let registeredAt = Date(timeIntervalSince1970: 1_760_000_000)
        let record = PersistentAppDevice.StoredRecord(
            deviceId: "7600112233445566",
            iid: "7600998877665544",
            cdid: "11111111-2222-3333-4444-555555555555",
            openudid: "0123456789abcdef",
            clientudid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            deviceToken: "token-placeholder-value",
            klinkEgdi: "egdi-placeholder",
            isActivated: true,
            lastRegisteredAt: registeredAt
        )

        XCTAssertEqual(PersistentAppDevice.renewalInterval, 21_600)
        XCTAssertFalse(record.needsRenewal(now: registeredAt.addingTimeInterval(3600)))
        XCTAssertFalse(record.needsRenewal(now: registeredAt.addingTimeInterval(21_599)))
        XCTAssertTrue(record.needsRenewal(now: registeredAt.addingTimeInterval(21_600)))
        XCTAssertTrue(record.needsRenewal(now: registeredAt.addingTimeInterval(25_000)))
    }

    func testMissingTokenOrUnactivatedRecordRequiresRenewal() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var missingToken = PersistentAppDevice.StoredRecord(
            deviceId: "7600112233445566",
            iid: "7600998877665544",
            cdid: "11111111-2222-3333-4444-555555555555",
            deviceToken: "   ",
            isActivated: true,
            lastRegisteredAt: now
        )
        XCTAssertTrue(missingToken.needsRenewal(now: now.addingTimeInterval(60)))

        missingToken.deviceToken = "valid-token"
        missingToken.isActivated = false
        XCTAssertTrue(missingToken.needsRenewal(now: now.addingTimeInterval(60)))

        var legacyAndroid = PersistentAppDevice.StoredRecord(
            deviceId: "7600112233445566",
            iid: "7600998877665544",
            cdid: "11111111-2222-3333-4444-555555555555",
            deviceToken: "valid-token",
            isActivated: true,
            lastRegisteredAt: now,
            platform: nil
        )
        XCTAssertTrue(legacyAndroid.needsRenewal(now: now.addingTimeInterval(60)), "legacy non-iOS device records must trigger a fresh iOS registration")
        legacyAndroid.platform = "iphone"
        XCTAssertFalse(legacyAndroid.needsRenewal(now: now.addingTimeInterval(60)))
    }

    func testRecordRoundTripAndValidation() throws {
        let record = PersistentAppDevice.StoredRecord(
            deviceId: "7600112233445566",
            iid: "7600998877665544",
            cdid: "11111111-2222-3333-4444-555555555555",
            openudid: "0123456789abcdef",
            clientudid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            deviceToken: "dt-sample",
            klinkEgdi: "egdi-sample",
            isActivated: true,
            lastRegisteredAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        let encoded = try XCTUnwrap(PersistentAppDevice.encodeRecord(record))
        let decoded = try XCTUnwrap(PersistentAppDevice.decodeRecord(encoded))
        XCTAssertEqual(decoded, record)

        let badJSON = #"{"deviceId":"not-digits","iid":"7600998877665544","cdid":"abc"}"#
        XCTAssertNil(PersistentAppDevice.decodeRecord(Data(badJSON.utf8)))
    }

    // MARK: - VideoModelDiskCache (FQVShortVideoVideoModelCacheManager)

    func testComputeExpiryMarginAndClamping() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        XCTAssertEqual(
            VideoModelDiskCache.computeExpiry(serverExpireTime: nil, now: now, defaultTTL: 900).timeIntervalSince(now),
            900,
            accuracy: 0.001
        )
        // Unix timestamp 1200 s in the future -> 60 s margin => 1140 s.
        XCTAssertEqual(
            VideoModelDiskCache.computeExpiry(serverExpireTime: now.timeIntervalSince1970 + 1200, now: now).timeIntervalSince(now),
            1140,
            accuracy: 0.001
        )
        // Very short Unix expiry clamps to minimum 120 s.
        XCTAssertEqual(
            VideoModelDiskCache.computeExpiry(serverExpireTime: now.timeIntervalSince1970 + 30, now: now).timeIntervalSince(now),
            120,
            accuracy: 0.001
        )
        // Very long Unix expiry clamps to maximum 3600 s.
        XCTAssertEqual(
            VideoModelDiskCache.computeExpiry(serverExpireTime: now.timeIntervalSince1970 + 86_400, now: now).timeIntervalSince(now),
            3600,
            accuracy: 0.001
        )
        // Relative expiry (seconds) also applies 60 s margin.
        XCTAssertEqual(
            VideoModelDiskCache.computeExpiry(serverExpireTime: 600, now: now).timeIntervalSince(now),
            540,
            accuracy: 0.001
        )
    }

    func testDiskCachePersistsReloadsExpiresAndRemoves() throws {
        let file = temporaryCacheFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let now = Date()
        let info = samplePlayInfo(vid: "990011223344")
        let expiresAt = now.addingTimeInterval(600)

        let writer = VideoModelDiskCache(fileURL: file, maxEntries: 8)
        writer.store(vid: info.vid, info: info, expiresAt: expiresAt, now: now)

        // Fresh instance reads from disk and preserves expiry + encryption key + variants.
        let reader = VideoModelDiskCache(fileURL: file, maxEntries: 8)
        let loaded = try XCTUnwrap(reader.loadWithExpiry(vid: info.vid, now: now.addingTimeInterval(10)))
        XCTAssertEqual(loaded.info, info)
        XCTAssertEqual(loaded.expiresAt.timeIntervalSince1970, expiresAt.timeIntervalSince1970, accuracy: 0.01)

        // Past expiry returns nil and evicts the entry.
        XCTAssertNil(reader.load(vid: info.vid, now: expiresAt.addingTimeInterval(1)))

        // Re-store and remove explicitly.
        writer.store(vid: info.vid, info: info, expiresAt: expiresAt, now: now)
        writer.remove(vid: info.vid)
        let readerAfterRemove = VideoModelDiskCache(fileURL: file, maxEntries: 8)
        XCTAssertNil(readerAfterRemove.load(vid: info.vid, now: now.addingTimeInterval(10)))
    }

    func testDiskCachePrunesOldestBeyondMaxEntries() {
        let file = temporaryCacheFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let base = Date()
        let cache = VideoModelDiskCache(fileURL: file, maxEntries: 2)
        for (idx, vid) in ["100001", "100002", "100003"].enumerated() {
            let t = base.addingTimeInterval(Double(idx))
            cache.store(vid: vid, info: samplePlayInfo(vid: vid), expiresAt: t.addingTimeInterval(600), now: t)
        }
        let checkTime = base.addingTimeInterval(10)
        XCTAssertNil(cache.load(vid: "100001", now: checkTime))
        XCTAssertNotNil(cache.load(vid: "100002", now: checkTime))
        XCTAssertNotNil(cache.load(vid: "100003", now: checkTime))
    }

    func testDiskCacheStoreBatchPersistsValidEntriesAndRespectsLimit() {
        let file = temporaryCacheFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let now = Date()
        let cache = VideoModelDiskCache(fileURL: file, maxEntries: 3)
        cache.storeBatch([
            (vid: "200001", info: samplePlayInfo(vid: "200001"), expiresAt: now.addingTimeInterval(600)),
            (vid: "200002", info: samplePlayInfo(vid: "200002"), expiresAt: now.addingTimeInterval(-10)),
            (vid: "200003", info: samplePlayInfo(vid: "200003"), expiresAt: now.addingTimeInterval(600)),
            (vid: "200004", info: samplePlayInfo(vid: "200004"), expiresAt: now.addingTimeInterval(600)),
        ], now: now)

        let reloaded = VideoModelDiskCache(fileURL: file, maxEntries: 3)
        let checkTime = now.addingTimeInterval(5)
        XCTAssertEqual(reloaded.load(vid: "200001", now: checkTime)?.vid, "200001")
        XCTAssertNil(reloaded.load(vid: "200002", now: checkTime), "expired entry must not be stored")
        XCTAssertEqual(reloaded.load(vid: "200003", now: checkTime)?.vid, "200003")
        XCTAssertEqual(reloaded.load(vid: "200004", now: checkTime)?.vid, "200004")
    }

    // MARK: - PlayBackupURLs & PlayInfoArchive Backup Persistence

    func testBackupURLsRegisterDeduplicateAndPersistInArchive() throws {
        let primary = URL(string: "https://v3-main.example.com/clip.mp4")!
        let backup1 = URL(string: "https://v3-bak1.example.com/clip.mp4")!
        let backup2 = URL(string: "https://v3-bak2.example.com/clip.mp4")!

        PlayBackupURLs.shared.register(primary: primary, backups: [primary, backup1, backup1, backup2])
        XCTAssertEqual(PlayBackupURLs.shared.backups(for: primary), [backup1, backup2])
        XCTAssertEqual(PlayBackupURLs.shared.allCandidates(startingWith: primary), [primary, backup1, backup2])

        var info = samplePlayInfo(vid: "880011223344")
        info.url = primary
        let archived = try XCTUnwrap(PlayInfoArchive.encode(info))
        PlayBackupURLs.shared.register(primary: primary, backups: [])
        XCTAssertTrue(PlayBackupURLs.shared.backups(for: primary).isEmpty)

        // Decoding restores the backup CDN URLs automatically.
        let decoded = try XCTUnwrap(PlayInfoArchive.decode(archived))
        XCTAssertEqual(decoded.url, primary)
        XCTAssertEqual(PlayBackupURLs.shared.backups(for: primary), [backup1, backup2])
    }

    func testFastCencOpenErrorClassification() {
        let expired = FastCencOpenError.mediaUnavailable(status: 403, message: "HTTP 403")
        XCTAssertTrue(expired.isExpiredOrAuthError)
        let serverError = FastCencOpenError.mediaUnavailable(status: 502, message: "HTTP 502")
        XCTAssertFalse(serverError.isExpiredOrAuthError)
        let layout = FastCencOpenError.unsupportedLayout("mdat before moov")
        XCTAssertFalse(layout.isExpiredOrAuthError)
    }
}

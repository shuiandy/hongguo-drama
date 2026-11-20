import XCTest
@testable import HongguoPlayback

final class MediaPrefixCacheTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("prefix-\(UUID().uuidString)")
    }

    func testSliceReturnsStoredPartOfARange() {
        let prefix = MediaPrefixCache.Prefix(start: 100, data: Data((0..<50).map { UInt8($0) }))
        XCTAssertEqual(prefix.end, 150)
        XCTAssertEqual(prefix.slice(100..<110), Data((0..<10).map { UInt8($0) }))
        // Runs past what is stored: only the stored part comes back.
        XCTAssertEqual(prefix.slice(140..<400)?.count, 10)
        XCTAssertEqual(prefix.slice(140..<400)?.first, 40)
        // Starts before or after the stored bytes: nothing.
        XCTAssertNil(prefix.slice(90..<120))
        XCTAssertNil(prefix.slice(150..<160))
    }

    func testStoreLoadAndKey() {
        let cache = MediaPrefixCache(directory: temporaryDirectory())
        let key = MediaPrefixCache.key(vid: "123", shortSide: 1080)
        XCTAssertEqual(key, "123-1080")
        XCTAssertNil(cache.load(key: key))
        cache.store(key: key, start: 4096, data: Data(repeating: 7, count: 32))
        XCTAssertTrue(cache.contains(key: key))
        let loaded = cache.load(key: key)
        XCTAssertEqual(loaded?.start, 4096)
        XCTAssertEqual(loaded?.data.count, 32)
        // Another quality of the same episode is a different entry.
        XCTAssertNil(cache.load(key: MediaPrefixCache.key(vid: "123", shortSide: 720)))
    }

    func testTrimDropsLeastRecentlyUsedFirst() throws {
        let directory = temporaryDirectory()
        let cache = MediaPrefixCache(directory: directory, limitBytes: 250)
        for (index, name) in ["a", "b", "c"].enumerated() {
            cache.store(key: name, start: 0, data: Data(repeating: 1, count: 100))
            // Distinct, increasing modification times without sleeping.
            let file = directory.appendingPathComponent("\(name)@0.bin")
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(index))], ofItemAtPath: file.path)
            }
        }
        cache.trim()
        XCTAssertFalse(cache.contains(key: "a"))
        XCTAssertTrue(cache.contains(key: "b"))
        XCTAssertTrue(cache.contains(key: "c"))
    }

    func testUnifiedPrefixReplacesLegacyAndLoadsRawHeader() throws {
        let directory = temporaryDirectory()
        let cache = MediaPrefixCache(directory: directory)
        let key = MediaPrefixCache.key(vid: "987654", shortSide: 1080)

        // Legacy file stored starting at offset 4096.
        cache.store(key: key, start: 4096, data: Data(repeating: 2, count: 64))
        XCTAssertNil(cache.loadRawHeader(key: key))
        XCTAssertEqual(cache.load(key: key)?.start, 4096)

        // Unified file stores byte 0 onward + totalLength and cleans up the legacy file.
        let unified = Data((0..<128).map { UInt8($0) })
        cache.storeUnified(key: key, totalLength: 10_485_760, data: unified)

        let rawHeader = try XCTUnwrap(cache.loadRawHeader(key: key))
        XCTAssertEqual(rawHeader.totalLength, 10_485_760)
        XCTAssertEqual(rawHeader.data, unified)

        let prefix = try XCTUnwrap(cache.load(key: key))
        XCTAssertEqual(prefix.start, 0)
        XCTAssertEqual(prefix.slice(64..<96), Data((64..<96).map { UInt8($0) }))
    }
}

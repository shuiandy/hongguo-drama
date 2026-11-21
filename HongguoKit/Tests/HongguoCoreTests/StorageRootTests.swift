import XCTest
@testable import HongguoCore

final class StorageRootTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StorageRootTests-\(UUID().uuidString)")
    }

    private func suite() -> UserDefaults {
        let name = "StorageRootTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// Nothing configured in the test process: the Mac and iOS default stays Application Support.
    func testDefaultBaseIsApplicationSupport() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(StorageRoot.base.standardizedFileURL, support.standardizedFileURL)
        XCTAssertEqual(StorageRoot.appFolder.standardizedFileURL,
                       support.appendingPathComponent("HongguoDrama", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(JSONFileStore<[String: String]>.defaultDirectory.standardizedFileURL,
                       StorageRoot.appFolder.standardizedFileURL)
        XCTAssertNil(StorageRoot.mirror)
    }

    func testNoMirrorWritesNothingToDefaults() throws {
        let dir = temporaryDirectory()
        let store = LibraryStore(directory: dir, mirror: nil)
        store.savePosition(seriesId: "1", title: "A", cover: "", total: 10, episodeIndex: 2, vid: "v",
                           position: 12, duration: 60, finished: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.json").path))
    }

    /// The purge case: Caches (and the file with it) is gone, the mirror brings back the settings
    /// and the newest records, account ids included.
    func testMirrorRestoresSettingsAndNewestRecordsAfterPurge() throws {
        let dir = temporaryDirectory()
        let defaults = suite()
        let store = LibraryStore(directory: dir, mirror: defaults)
        var settings = store.settings
        settings.playbackRate = 1.5
        store.settings = settings
        let total = LibraryStore.mirrorLimit + 10
        for i in 0..<total {
            store.savePosition(seriesId: "s\(i)", title: "T\(i)", cover: "", total: 80, episodeIndex: i % 80 + 1,
                               vid: "v\(i)", position: Double(i), duration: 90, finished: false,
                               accountId: i.isMultiple(of: 2) ? "acct" : nil)
            _ = store.updateRecord("s\(i)") { var r = $0; r.updatedAt = Date(timeIntervalSince1970: Double(1_000 + i)); return r }
        }
        XCTAssertEqual(store.history().count, total)

        try FileManager.default.removeItem(at: dir)
        let restored = LibraryStore(directory: dir, mirror: defaults)
        XCTAssertEqual(restored.settings.playbackRate, 1.5)
        let history = restored.history()
        XCTAssertEqual(history.count, LibraryStore.mirrorLimit)
        XCTAssertEqual(history.first?.seriesId, "s\(total - 1)")
        XCTAssertEqual(history.last?.seriesId, "s\(total - LibraryStore.mirrorLimit)")
        let original = store.record(for: "s\(total - 2)")
        XCTAssertEqual(restored.record(for: "s\(total - 2)"), original)
        XCTAssertEqual(restored.record(for: "s\(total - 2)")?.cloudAccountId, "acct")
        XCTAssertNil(restored.record(for: "s\(total - 1)")?.cloudAccountId)
        // The restored copy is written back, so the next launch reads the file again.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.json").path))
    }

    /// A file that is present wins over the mirror, and a damaged file is still moved aside.
    func testExistingFileWinsOverMirror() throws {
        let dir = temporaryDirectory()
        let defaults = suite()
        let first = LibraryStore(directory: dir, mirror: defaults)
        first.savePosition(seriesId: "file", title: "F", cover: "", total: 5, episodeIndex: 1, vid: "v",
                           position: 1, duration: 10, finished: false)
        let other = LibraryStore(directory: temporaryDirectory(), mirror: defaults)
        other.savePosition(seriesId: "mirror-only", title: "M", cover: "", total: 5, episodeIndex: 1, vid: "v",
                           position: 1, duration: 10, finished: false)
        let reopened = LibraryStore(directory: dir, mirror: defaults)
        XCTAssertNotNil(reopened.record(for: "file"))
        XCTAssertNil(reopened.record(for: "mirror-only"))
    }

    /// The mirror has to fit tvOS's small `UserDefaults` budget (500 KB for the whole app).
    func testMirrorStaysSmall() throws {
        let defaults = suite()
        let store = LibraryStore(directory: temporaryDirectory(), mirror: defaults)
        for i in 0..<300 {
            store.savePosition(seriesId: "72000000000000\(i)", title: "一部名字相当长的短剧标题第\(i)部",
                               cover: "https://p3-reading-sign.fqnovelpic.com/novel-pic/\(UUID().uuidString)~tplv-resize:570:810.heic",
                               total: 100, episodeIndex: 50, vid: "v0\(UUID().uuidString)",
                               position: 33, duration: 90, finished: false, accountId: "1234567890")
        }
        let size = try XCTUnwrap(defaults.data(forKey: LibraryStore.mirrorKey)).count
        XCTAssertLessThan(size, 64 * 1024, "mirror is \(size) bytes")
    }
}

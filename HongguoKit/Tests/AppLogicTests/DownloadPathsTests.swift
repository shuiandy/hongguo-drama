import XCTest
@testable import AppLogic

final class DownloadPathsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/NEW/Library/Application Support/Downloads")

    func testMovedContainerIsRebased() {
        let old = "/var/mobile/Containers/Data/Application/OLD/Library/Application Support/Downloads/红果短剧/某剧-abc/某剧 001.mp4"
        XCTAssertEqual(DownloadPaths.rebased(old, root: root),
                       "/var/mobile/Containers/Data/Application/NEW/Library/Application Support/Downloads/红果短剧/某剧-abc/某剧 001.mp4")
    }

    func testSamePathStaysTheSame() {
        let current = root.path + "/红果短剧/某剧-abc/某剧 002.mp4"
        XCTAssertEqual(DownloadPaths.rebased(current, root: root), current)
    }

    func testOtherPathsAreLeftAlone() {
        XCTAssertNil(DownloadPaths.rebased("/tmp/elsewhere/file.mp4", root: root))
        XCTAssertNil(DownloadPaths.rebased("/x/Downloads/红果短剧/", root: root))
        XCTAssertNil(DownloadPaths.rebased("/x/Downloads/红果短剧/../../etc/passwd", root: root))
    }
}

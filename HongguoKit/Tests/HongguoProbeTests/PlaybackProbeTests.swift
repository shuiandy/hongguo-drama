import XCTest
import HongguoCore

/// Live, read-only probe for the BDInstall-aligned `PersistentAppDevice` + `AuthenticatedPlaybackSource`.
/// Skipped unless `HONGGUO_PROBE=playback` is set. Never prints secrets or raw device IDs/tokens.
final class PlaybackProbeTests: XCTestCase {
    // Live probes of the iOS app: run with its behavior (PlatformBehavior.iOS).
    override func setUp() { super.setUp(); PlatformBehavior.current = .iOS }
    override func tearDown() { PlatformBehavior.current = .mac; super.tearDown() }

    func testAuthenticatedPlaybackSourceLive() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HONGGUO_PROBE"] == "playback",
            "set HONGGUO_PROBE=playback to run this live probe"
        )
        let vid = ProcessInfo.processInfo.environment["HONGGUO_PROBE_VID"] ?? "7706514645208534041"
        PersistentAppDevice.onLog = { line in
            print("PROBE_LOG: \(line)")
        }
        defer { PersistentAppDevice.onLog = nil }

        let t0 = Date()
        await AuthenticatedPlaybackSource.shared.warmUpIdentity()
        let warmMs = Int(Date().timeIntervalSince(t0) * 1000)

        let t1 = Date()
        let first = try await AuthenticatedPlaybackSource.shared.resolveWithRoute(vid: vid, force: true)
        let firstMs = Int(Date().timeIntervalSince(t1) * 1000)

        let t2 = Date()
        let second = try await AuthenticatedPlaybackSource.shared.resolveWithRoute(vid: vid, force: false)
        let secondMs = Int(Date().timeIntervalSince(t2) * 1000)

        let t3 = Date()
        let forced = try await AuthenticatedPlaybackSource.shared.resolveWithRoute(vid: vid, force: true)
        let forcedMs = Int(Date().timeIntervalSince(t3) * 1000)

        print("PROBE_RESULT: warmMs=\(warmMs) first=(\(first.route), \(firstMs)ms, codec=\(first.info.codec), q=\(first.info.quality?.label ?? "-"), enc=\(first.info.isEncrypted)) cached=(\(second.route), \(secondMs)ms) steady=(\(forced.route), \(forcedMs)ms, codec=\(forced.info.codec), q=\(forced.info.quality?.label ?? "-"))")

        XCTAssertEqual(first.info.vid, vid)
        XCTAssertEqual(second.route, "auth-mem")
        XCTAssertEqual(forced.info.vid, vid)
        XCTAssertFalse(forced.info.url.absoluteString.isEmpty)
    }
}

@testable import HongguoCore
import XCTest

/// URLGuard's handling of a proxy's virtual DNS answers under both `ProxyPolicy` values
/// (from the iOS app's URLGuardShimTests, iOS 382e2c2).
final class URLGuardProxyPolicyTests: XCTestCase {
    func testPublicAnswersPass() {
        XCTAssertEqual(URLGuard.classify(["155.102.176.84"]), .publicOnly)
        XCTAssertEqual(URLGuard.classify(["2604:980:3007:124::2a", "163.181.60.204"]), .publicOnly)
    }

    func testFakeIPAndULAAreProxyVirtual() {
        XCTAssertEqual(URLGuard.classify(["198.18.35.93"], policy: .mobileProxy), .proxyVirtual)
        XCTAssertEqual(URLGuard.classify(["198.19.255.1"], policy: .mobileProxy), .proxyVirtual)
        XCTAssertEqual(URLGuard.classify(["198.18.0.7", "fd00:6868:6868::7"], policy: .mobileProxy), .proxyVirtual)
        XCTAssertEqual(URLGuard.classify(["fc00::1"], policy: .mobileProxy), .proxyVirtual)
    }

    func testStrictPolicyCountsOnlyFakeIPAsVirtual() {
        XCTAssertEqual(URLGuard.classify(["198.18.35.93"], policy: .strict), .proxyVirtual)
        XCTAssertEqual(URLGuard.classify(["fc00::1"], policy: .strict), .privateTarget)
        XCTAssertEqual(URLGuard.classify(["198.18.0.7", "fd00:6868:6868::7"], policy: .strict), .privateTarget)
    }

    func testMacDefaultIsStrict() {
        XCTAssertEqual(PlatformBehavior.mac.proxyPolicy, .strict)
        XCTAssertEqual(PlatformBehavior.iOS.proxyPolicy, .mobileProxy)
    }

    func testRealPrivateTargetsStayBlocked() {
        for policy in [URLGuard.ProxyPolicy.strict, .mobileProxy] {
            for address in ["127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "169.254.1.1", "100.64.0.1", "::1", "fe80::1"] {
                XCTAssertEqual(URLGuard.classify([address], policy: policy), .privateTarget, address)
            }
            // A virtual answer mixed with a real private one is not a proxy's answer.
            XCTAssertEqual(URLGuard.classify(["198.18.0.7", "10.0.0.5"], policy: policy), .privateTarget)
            XCTAssertEqual(URLGuard.classify(["198.18.0.7", "127.0.0.1"], policy: policy), .privateTarget)
            XCTAssertEqual(URLGuard.classify([], policy: policy), .privateTarget)
        }
    }

    func testServiceHostsMatchWholeLabels() {
        for host in ["reading.snssdk.com", "api5-normal-sinfonlineb.fqnovel.com", "hongguoduanju.com",
                     "www.hongguoduanju.com", "v3-reading-videocdn302.qznovelvod.com",
                     "p3-reading-sign.fqnovelpic.com", "p3-novel.byteimg.com", "P3.DOUYINPIC.COM", "fqnovel.com."] {
            XCTAssertTrue(URLGuard.isServiceHost(host), host)
        }
        for host in ["evilfqnovel.com", "fqnovel.com.example.net", "snssdk.co", "example.com", "qznovelvod.com.evil",
                     "localhost", ""] {
            XCTAssertFalse(URLGuard.isServiceHost(host), host)
        }
    }

    func testUnconfirmedOnlyForServiceHostsOverHTTPS() {
        XCTAssertTrue(URLGuard.allowsUnconfirmed(host: "v3-reading-videocdn302.qznovelvod.com", scheme: "https"))
        XCTAssertFalse(URLGuard.allowsUnconfirmed(host: "v3-reading-videocdn302.qznovelvod.com", scheme: "http"))
        XCTAssertFalse(URLGuard.allowsUnconfirmed(host: "attacker.example.com", scheme: "https"))
    }

    func testBlocksAreReported() async {
        let box = Reported()
        URLGuard.onBlock = { host, reason in box.add("\(host)|\(reason)") }
        defer { URLGuard.onBlock = nil }
        do {
            try await URLGuard.check(URL(string: "http://localhost/x")!)
            XCTFail("localhost must be blocked")
        } catch {}
        XCTAssertEqual(box.all.first?.hasPrefix("localhost|"), true)
    }

    func testServiceHostProxyVirtualReturnsWithoutWaitingForSlowDoHAndEnforcesBackgroundDeny() async throws {
        let cache = ResolutionCache()
        let url = URL(string: "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/player/v1/")!
        let started = Date()
        try await URLGuard.check(
            url,
            policy: .mobileProxy,
            cache: cache,
            resolveHost: { _ in ["198.18.0.7"] },
            resolveDoH: { _ in
                try await Task.sleep(for: .milliseconds(120))
                return (["127.0.0.1"], 60)
            }
        )
        // Cold-start service host must NOT block waiting for slow DoH under Fake-IP VPN.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)

        // Once background DoH detects a non-public IP, subsequent checks must be blocked.
        try await Task.sleep(for: .milliseconds(200))
        do {
            try await URLGuard.check(
                url,
                policy: .mobileProxy,
                cache: cache,
                resolveHost: { _ in ["198.18.0.7"] },
                resolveDoH: { _ in (["155.102.176.84"], 60) }
            )
            XCTFail("Host marked denied by background DoH must be rejected")
        } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .security)
        }
    }

    func testNonServiceHostProxyVirtualStillRequiresSynchronousDoH() async {
        let cache = ResolutionCache()
        let url = URL(string: "https://unknown-host.example.com/video.mp4")!
        do {
            try await URLGuard.check(
                url,
                policy: .mobileProxy,
                cache: cache,
                resolveHost: { _ in ["198.18.0.7"] },
                resolveDoH: { _ in throw URLGuard.blocked() }
            )
            XCTFail("Unknown host with unconfirmed DoH must stay blocked")
        } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .security)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

extension URLGuardProxyPolicyTests {
    func testStrictPolicyMakesServiceHostsWaitForDoH() async {
        let url = URL(string: "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/")!
        do {
            try await URLGuard.check(url, policy: .strict, cache: ResolutionCache(),
                                     resolveHost: { _ in ["198.18.0.7"] }, resolveDoH: { _ in throw URLGuard.blocked() })
            XCTFail("Under .strict an unconfirmed service host must stay blocked")
        } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .security)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // A public DoH answer lets it through.
        do {
            try await URLGuard.check(url, policy: .strict, cache: ResolutionCache(),
                                     resolveHost: { _ in ["198.18.0.7"] }, resolveDoH: { _ in (["155.102.176.84"], 60) })
        } catch {
            XCTFail("A public DoH answer must pass: \(error)")
        }
    }
}

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

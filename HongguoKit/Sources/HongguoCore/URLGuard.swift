import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// SSRF protection for every URL that comes from remote data (media links, share links,
/// redirects). Ported from the Electron app's `web-media-guard.js`:
/// * only http/https without embedded credentials,
/// * hostnames must look public (no localhost/.local/.lan/...),
/// * IP literals and DNS answers must be public unicast addresses,
/// * when the system resolver only returns a local proxy's virtual answers (Fake-IP
///   198.18.0.0/15, or a ULA fc00::/7 address from the proxy's IPv6 interface, as Surge/Clash
///   hand out on a Mac or as a VPN on a phone), the real answer is checked through fixed
///   DNS-over-HTTPS resolvers before the request may continue. The service's own https hosts
///   (`serviceDomains`) go on at once and are DoH-verified in the background (a non-public answer
///   blocks the host from then on); other hosts wait for DoH (2 s).
/// One behavior for every app; each block is reported through `onBlock` (host and reason) for
/// the app's log. Real private, loopback and link-local answers, and a DoH answer that is not
/// public, are always blocked.
public enum URLGuard {
    /// Hosts kept checked at most (each for up to 300 seconds).
    static let cacheLimit = 300
    static let publicAnswerTTL = 120
    static let dohTimeout: TimeInterval = 2

    private static let blockedV4: [(UInt32, Int)] = [
        ("0.0.0.0", 8), ("10.0.0.0", 8), ("100.64.0.0", 10), ("127.0.0.0", 8),
        ("169.254.0.0", 16), ("172.16.0.0", 12), ("192.0.0.0", 24), ("192.0.2.0", 24),
        ("192.168.0.0", 16), ("198.18.0.0", 15), ("198.51.100.0", 24), ("203.0.113.0", 24),
        ("224.0.0.0", 3),
    ].map { (ipv4($0.0)!, $0.1) }

    /// Syntactic check, no network. Mirrors `isPublicMediaUrl`.
    public static func isPublicURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if url.user != nil || url.password != nil { return false }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if isIPLiteral(host) { return isPublicAddress(host) }
        guard host.contains(".") else { return false }
        let labels = host.split(separator: ".")
        if let last = labels.last, ["localhost", "local", "internal", "lan", "home"].contains(String(last)) { return false }
        if host == "localhost" { return false }
        return true
    }

    public static func isPublicURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return isPublicURL(url)
    }

    public static func isIPLiteral(_ host: String) -> Bool {
        ipv4(host) != nil || ipv6(host) != nil
    }

    public static func isFakeIP(_ address: String) -> Bool {
        guard let v = ipv4(address) else { return false }
        return inSubnet(v, ipv4("198.18.0.0")!, 15)
    }

    /// An address a local proxy hands out instead of the real one: Fake-IP 198.18.0.0/15, or an
    /// IPv6 unique local address (fc00::/7) from the proxy's virtual interface.
    public static func isProxyVirtual(_ address: String) -> Bool {
        if isFakeIP(address) { return true }
        if let v6 = ipv6(address) { return v6[0] & 0xfe == 0xfc }
        return false
    }

    /// The registrable domains this app talks to: its APIs, pages, covers and video CDN.
    public static let serviceDomains = [
        "fqnovel.com", "fqnovelpic.com", "fqnovelstatic.com", "qznovelvod.com", "fqnovelvod.com",
        "snssdk.com", "hongguoduanju.com", "byteimg.com", "douyinpic.com",
        "toutiaovod.com", "douyinvod.com",
    ]

    /// `host` is one of `serviceDomains` or a name under one (whole labels: `evilfqnovel.com`
    /// and `fqnovel.com.example.net` are not).
    public static func isServiceHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return serviceDomains.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    public enum Answer: Equatable, Sendable {
        /// Every address is public.
        case publicOnly
        /// Every address is a proxy's virtual one: the real answer has to be looked up.
        case proxyVirtual
        /// At least one address is private, loopback, link-local, reserved or unreadable.
        case privateTarget
    }

    /// Fake-IP and ULA answers are a proxy's virtual ones; anything else not public is a private target.
    public static func classify(_ addresses: [String]) -> Answer {
        if !addresses.isEmpty, addresses.allSatisfy(isPublicAddress) { return .publicOnly }
        if !addresses.isEmpty, addresses.allSatisfy(isProxyVirtual) { return .proxyVirtual }
        return .privateTarget
    }

    /// When the real address behind a proxy's virtual answer could not be confirmed: only the
    /// service's own https hosts may go on.
    public static func allowsUnconfirmed(host: String, scheme: String?) -> Bool {
        scheme?.lowercased() == "https" && isServiceHost(host)
    }

    private static let blockHook = BlockHook()

    /// Called with the host and the reason each time a request is blocked (for the app's log).
    public static var onBlock: (@Sendable (_ host: String, _ reason: String) -> Void)? {
        get { blockHook.get() }
        set { blockHook.set(newValue) }
    }

    public static func isPublicAddress(_ address: String) -> Bool {
        if let v4 = ipv4(address) {
            return !blockedV4.contains { inSubnet(v4, $0.0, $0.1) }
        }
        if let v6 = ipv6(address) {
            // IPv4-mapped (::ffff:a.b.c.d): judge by the embedded IPv4 address.
            if v6[0..<10].allSatisfy({ $0 == 0 }) && v6[10] == 0xff && v6[11] == 0xff {
                let v4 = UInt32(v6[12]) << 24 | UInt32(v6[13]) << 16 | UInt32(v6[14]) << 8 | UInt32(v6[15])
                return !blockedV4.contains { inSubnet(v4, $0.0, $0.1) }
            }
            // Global unicast 2000::/3 only.
            guard v6[0] & 0xe0 == 0x20 else { return false }
            // 2001:db8::/32 documentation, 2001::/32 Teredo, 2002::/16 6to4.
            if v6[0] == 0x20 && v6[1] == 0x01 && v6[2] == 0x0d && v6[3] == 0xb8 { return false }
            if v6[0] == 0x20 && v6[1] == 0x01 && v6[2] == 0x00 && v6[3] == 0x00 { return false }
            if v6[0] == 0x20 && v6[1] == 0x02 { return false }
            return true
        }
        return false
    }

    static func ipv4(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    static func ipv6(_ text: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, text, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func inSubnet(_ value: UInt32, _ base: UInt32, _ prefix: Int) -> Bool {
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        return value & mask == base & mask
    }

    // MARK: - Resolution check

    private static let cache = ResolutionCache()

    /// Full check including DNS. Throws `HongguoError(.security)` when the URL may reach a
    /// private network. Results are cached per host (up to 300 seconds).
    public static func check(_ url: URL) async throws {
        try await check(url, cache: cache, resolveHost: { try await resolve($0) },
                        resolveDoH: { try await DoHResolver.resolveA($0, timeout: dohTimeout) })
    }

    static func check(
        _ url: URL,
        cache: ResolutionCache,
        resolveHost: @escaping @Sendable (String) async throws -> [String],
        resolveDoH: @escaping @Sendable (String) async throws -> ([String], Int)
    ) async throws {
        let limit = cacheLimit
        let shownHost = url.host?.lowercased() ?? ""
        guard isPublicURL(url) else { throw blocked(host: shownHost, reason: "not a public http(s) URL") }
        guard var host = url.host?.lowercased() else { throw blocked(host: "", reason: "no host") }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isIPLiteral(host) { return }
        if await cache.isDenied(host) {
            throw blocked(host: host, reason: "DoH answer is not public")
        }
        if await cache.isFresh(host) { return }
        let addresses: [String]
        do {
            addresses = try await resolveHost(host)
        } catch {
            reportBlock(host: host, reason: "system DNS failed")
            throw error
        }
        guard !addresses.isEmpty else {
            reportBlock(host: host, reason: "no address")
            throw HongguoError(.network, "片源域名未解析到地址")
        }
        switch classify(addresses) {
        case .publicOnly:
            await cache.store(host, ttl: publicAnswerTTL, limit: limit)
            return
        case .privateTarget:
            throw blocked(host: host, reason: "resolves to a non-public address")
        case .proxyVirtual:
            // A local proxy's virtual answers are not the real destination.
            guard url.scheme?.lowercased() == "https" else {
                throw blocked(host: host, reason: "proxy virtual address, not https")
            }
            // The service's own https hosts do not wait for the DoH roundtrip on a cold start; they
            // are verified in the background instead (a non-public answer denies the host from then on).
            if allowsUnconfirmed(host: host, scheme: url.scheme) {
                await cache.store(host, ttl: 60, limit: limit)
                if await cache.beginBackgroundVerify(host) {
                    Task.detached(priority: .utility) {
                        defer { Task { await cache.endBackgroundVerify(host) } }
                        do {
                            let (real, ttl) = try await resolveDoH(host)
                            if !real.isEmpty, real.allSatisfy(isPublicAddress) {
                                await cache.store(host, ttl: max(60, ttl), limit: limit)
                            } else {
                                await cache.markDenied(host, ttl: 300)
                                reportBlock(host: host, reason: "DoH answer is not public")
                            }
                        } catch {
                            // Unreachable/timed-out DoH on a proxy VPN keeps the provisional allow.
                        }
                    }
                }
                return
            }
            let real: [String]
            let ttl: Int
            do {
                (real, ttl) = try await resolveDoH(host)
            } catch {
                throw blocked(host: host, reason: "proxy virtual address, DoH did not confirm")
            }
            guard !real.isEmpty, real.allSatisfy(isPublicAddress) else {
                await cache.markDenied(host, ttl: 300)
                throw blocked(host: host, reason: "DoH answer is not public")
            }
            await cache.store(host, ttl: ttl, limit: limit)
        }
    }

    static func blocked() -> HongguoError {
        HongguoError(.security, "片源及其跳转、解析结果必须指向公网")
    }

    static func blocked(host: String, reason: String) -> HongguoError {
        reportBlock(host: host, reason: reason)
        return blocked()
    }

    private static func reportBlock(host: String, reason: String) {
        onBlock?(host, reason)
    }

    /// The system resolver can block for a long time when the network or a local proxy's DNS is
    /// stuck; the lookup gives up after this many seconds (the blocked thread finishes on its own).
    static let systemDNSTimeout: TimeInterval = 6

    static func resolve(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            let once = ResolveOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + systemDNSTimeout) {
                once.resume(.failure(HongguoError(.timeout, "DNS 解析超时")))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = Int32(SOCK_STREAM)
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let first = result else {
                    once.resume(.failure(HongguoError(.network, "DNS 解析失败")))
                    return
                }
                defer { freeaddrinfo(first) }
                var out: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let node = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        var text = String(cString: buffer)
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        if !out.contains(text) { out.append(text) }
                    }
                    cursor = node.pointee.ai_next
                }
                once.resume(.success(out))
            }
        }
    }
}

/// Resumes a DNS lookup's continuation once: with the answer or with the timeout, whichever is first.
private final class ResolveOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    init(_ continuation: CheckedContinuation<[String], Error>) { self.continuation = continuation }
    func resume(_ result: Result<[String], Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

actor ResolutionCache {
    private var expiry: [String: Date] = [:]
    private var denied: [String: Date] = [:]
    private var verifying: Set<String> = []

    func isFresh(_ host: String) -> Bool {
        guard !isDenied(host) else { return false }
        return (expiry[host] ?? .distantPast) > Date()
    }

    func isDenied(_ host: String) -> Bool {
        (denied[host] ?? .distantPast) > Date()
    }

    func store(_ host: String, ttl: Int, limit: Int = 300) {
        denied[host] = nil
        expiry[host] = Date().addingTimeInterval(TimeInterval(max(0, min(limit, ttl))))
        if expiry.count > 256 { expiry = expiry.filter { $0.value > Date() } }
    }

    func markDenied(_ host: String, ttl: Int) {
        expiry[host] = nil
        denied[host] = Date().addingTimeInterval(TimeInterval(max(10, min(600, ttl))))
        if denied.count > 128 { denied = denied.filter { $0.value > Date() } }
    }

    func beginBackgroundVerify(_ host: String) -> Bool {
        verifying.insert(host).inserted
    }

    func endBackgroundVerify(_ host: String) {
        verifying.remove(host)
    }
}

/// DNS-over-HTTPS A-record lookup against fixed resolvers, raced over a shared URLSession.
enum DoHResolver {
    static let endpoints = ["https://1.1.1.1/dns-query", "https://223.5.5.5/resolve"]

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }()

    static func resolveA(_ host: String, timeout: TimeInterval = 2) async throws -> ([String], Int) {
        let session = sharedSession
        return try await withThrowingTaskGroup(of: ([String], Int).self) { group in
            for endpoint in endpoints {
                group.addTask {
                    var components = URLComponents(string: endpoint)!
                    components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
                    var request = URLRequest(url: components.url!, timeoutInterval: timeout)
                    request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
                    let (data, response) = try await session.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536 else { throw URLGuard.blocked() }
                    let json = try JSONValue.parse(data)
                    guard json["Status"].number == 0 else { throw URLGuard.blocked() }
                    let rows = (json["Answer"].array ?? []).filter { $0["type"].number == 1 }
                    let addresses = rows.compactMap { $0["data"].string }
                    guard !addresses.isEmpty, addresses.count == rows.count,
                          addresses.allSatisfy({ URLGuard.ipv4($0) != nil && URLGuard.isPublicAddress($0) }) else {
                        throw URLGuard.blocked()
                    }
                    let ttl = rows.compactMap { $0["TTL"].number }.map { Int($0) }.min() ?? 0
                    return (addresses, ttl)
                }
            }
            var lastError: Error = URLGuard.blocked()
            while let next = await group.nextResult() {
                switch next {
                case .success(let value):
                    group.cancelAll()
                    return value
                case .failure(let error):
                    lastError = error
                }
            }
            throw lastError
        }
    }
}

final class BlockHook: @unchecked Sendable {
    private let lock = NSLock()
    private var hook: (@Sendable (String, String) -> Void)?
    func get() -> (@Sendable (String, String) -> Void)? { lock.lock(); defer { lock.unlock() }; return hook }
    func set(_ value: (@Sendable (String, String) -> Void)?) { lock.lock(); hook = value; lock.unlock() }
}

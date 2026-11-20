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
/// * when the system resolver only returns Fake-IP answers (198.18.0.0/15, used by
///   local proxy tools such as Surge/Clash), the real answer is checked through fixed
///   DNS-over-HTTPS resolvers before the request may continue.
public enum URLGuard {
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
    /// private network. Results are cached for up to 60 seconds per host.
    public static func check(_ url: URL) async throws {
        guard isPublicURL(url) else { throw blocked() }
        guard var host = url.host?.lowercased() else { throw blocked() }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isIPLiteral(host) { return }
        if await cache.isFresh(host) { return }
        let addresses = try await resolve(host)
        guard !addresses.isEmpty else { throw HongguoError(.network, "片源域名未解析到地址") }
        if addresses.allSatisfy(isPublicAddress) {
            await cache.store(host, ttl: 60)
            return
        }
        // A local proxy's Fake-IP answers are not the real destination. Ask fixed DoH
        // resolvers for the real answer and require it to be public.
        if addresses.allSatisfy(isFakeIP), url.scheme?.lowercased() == "https" {
            let (real, ttl) = try await DoHResolver.resolveA(host)
            guard !real.isEmpty, real.allSatisfy(isPublicAddress) else { throw blocked() }
            await cache.store(host, ttl: ttl)
            return
        }
        throw blocked()
    }

    static func blocked() -> HongguoError {
        HongguoError(.security, "片源及其跳转、解析结果必须指向公网")
    }

    static func resolve(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = Int32(SOCK_STREAM)
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let first = result else {
                    continuation.resume(throwing: HongguoError(.network, "DNS 解析失败"))
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
                continuation.resume(returning: out)
            }
        }
    }
}

actor ResolutionCache {
    private var expiry: [String: Date] = [:]
    func isFresh(_ host: String) -> Bool { (expiry[host] ?? .distantPast) > Date() }
    func store(_ host: String, ttl: Int) {
        expiry[host] = Date().addingTimeInterval(TimeInterval(max(0, min(60, ttl))))
        if expiry.count > 256 { expiry = expiry.filter { $0.value > Date() } }
    }
}

/// DNS-over-HTTPS A-record lookup against fixed resolvers, raced.
enum DoHResolver {
    static let endpoints = ["https://1.1.1.1/dns-query", "https://223.5.5.5/resolve"]

    static func resolveA(_ host: String) async throws -> ([String], Int) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await withThrowingTaskGroup(of: ([String], Int).self) { group in
            for endpoint in endpoints {
                group.addTask {
                    var components = URLComponents(string: endpoint)!
                    components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
                    var request = URLRequest(url: components.url!, timeoutInterval: 4)
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

import Foundation
import Network
import Security

/// 网络代理 (port of the Electron proxy settings): connect directly (default), follow the system
/// proxy, or use a manual HTTP / SOCKS5 proxy with optional credentials. The password lives in the
/// keychain, never in settings.json.
public struct ProxySettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case direct, system, custom }
    public enum Kind: String, Codable, CaseIterable, Sendable { case http, socks5 }

    public var mode: Mode = .direct
    public var kind: Kind = .http
    public var host: String = "127.0.0.1"
    public var port: Int = 7890
    public var username: String = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProxySettings()
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? d.mode
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? d.kind
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? d.host
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? d.port
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? d.username
    }

    /// Checks a manual proxy before it is used (`validateProxyDraft`).
    public func validate() throws {
        guard mode == .custom else { return }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 253,
              trimmed.range(of: "^[A-Za-z0-9.\\-:\\[\\]]+$", options: .regularExpression) != nil else {
            throw HongguoError(.input, "代理地址格式无效")
        }
        guard (1...65535).contains(port) else { throw HongguoError(.input, "代理端口需为 1 至 65535") }
        guard username.count <= 256 else { throw HongguoError(.input, "代理用户名过长") }
    }

    /// Display text such as "HTTP 127.0.0.1:7890".
    public var summary: String {
        switch mode {
        case .direct: return "直连"
        case .system: return "跟随系统代理"
        case .custom: return "\(kind == .http ? "HTTP" : "SOCKS5") \(host):\(port)"
        }
    }
}

/// The proxy every new URLSession uses. Changing it bumps `revision`; long-lived sessions
/// (HTTPClient, downloads) rebuild themselves on their next request.
public final class NetworkProxy: @unchecked Sendable {
    public static let shared = NetworkProxy()

    private let lock = NSLock()
    private var current = ProxySettings()
    private var password = ""
    private(set) var revisionValue = 0

    public var revision: Int { lock.withLock { revisionValue } }
    public var settings: ProxySettings { lock.withLock { current } }

    /// Applies new settings. An invalid manual proxy falls back to a direct connection and throws,
    /// so a typo never leaves the app unable to reach anything.
    public func apply(_ settings: ProxySettings, password newPassword: String? = nil) throws {
        let pass = newPassword ?? ProxyKeychain.load() ?? ""
        do {
            try settings.validate()
            lock.withLock {
                current = settings
                password = pass
                revisionValue &+= 1
            }
        } catch {
            var fallback = settings
            fallback.mode = .direct
            lock.withLock { current = fallback; revisionValue &+= 1 }
            throw error
        }
    }

    /// Writes the proxy into a session configuration.
    public func configure(_ config: URLSessionConfiguration) {
        let (settings, pass) = lock.withLock { (current, password) }
        Self.configure(config, settings: settings, password: pass)
    }

    static func configure(_ config: URLSessionConfiguration, settings: ProxySettings, password: String) {
        config.proxyConfigurations = []
        switch settings.mode {
        case .direct:
            // An empty dictionary turns the system proxy off.
            config.connectionProxyDictionary = [:]
        case .system:
            config.connectionProxyDictionary = nil
        case .custom:
            config.connectionProxyDictionary = [:]
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: settings.port)) else { return }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(settings.host.trimmingCharacters(in: .whitespaces)), port: port)
            var proxy = settings.kind == .http
                ? ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
                : ProxyConfiguration(socksv5Proxy: endpoint)
            if !settings.username.isEmpty {
                proxy.applyCredential(username: settings.username, password: password)
            }
            config.proxyConfigurations = [proxy]
        }
    }

    /// 测试连接: one request to the Hongguo website through `settings` (not yet applied).
    /// Returns the round trip time.
    public static func test(_ settings: ProxySettings, password: String) async throws -> TimeInterval {
        try settings.validate()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        configure(config, settings: settings, password: password)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://hongguoduanju.com/")!, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.setValue(UserAgents.web, forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status < 500 else {
                throw HongguoError(.upstream, "代理可以连接，但红果官网返回异常状态")
            }
            return Date().timeIntervalSince(start)
        } catch let error as HongguoError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw HongguoError(.timeout, "连接超时，请检查代理地址和端口")
            case .cannotConnectToHost, .cannotFindHost: throw HongguoError(.network, "无法连接到代理服务器")
            case .userAuthenticationRequired: throw HongguoError(.network, "代理需要用户名和密码")
            default: throw HongguoError(.network, "连接失败：\(error.localizedDescription)")
            }
        }
    }
}

/// The manual proxy password, as a keychain generic password of this app.
public enum ProxyKeychain {
    static let service = "HongguoDrama.proxy"
    static let account = "proxy"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func load() -> String? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ password: String) throws {
        if password.isEmpty { clear(); return }
        let data = Data(password.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard update == errSecItemNotFound, SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw HongguoError(.unavailable, "系统钥匙串不可用，代理密码未保存")
        }
    }

    public static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

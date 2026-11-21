import Foundation

public enum UserAgents {
    /// Product name for this client’s requests to public web resources.
    public static let web = "HongguoDrama"
}

public struct HTTPResponse: Sendable {
    public var data: Data
    public var status: Int
    public var headers: [String: String]
    public var url: URL

    public var text: String { String(decoding: data, as: UTF8.self) }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// URLSession wrapper. Every request URL and every redirect target goes through `URLGuard`.
/// Cookies are not stored and no account credentials are attached.
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    private let lock = NSLock()
    private var currentSession: URLSession
    /// Proxy revision the session was built with; nil for an injected configuration (tests),
    /// which is never rebuilt.
    private var proxyRevision: Int?

    /// The session, rebuilt after the proxy setting changed (see `NetworkProxy`).
    var session: URLSession {
        lock.withLock {
            if let built = proxyRevision, built != NetworkProxy.shared.revision {
                currentSession.finishTasksAndInvalidate()
                currentSession = URLSession(configuration: Self.defaultConfiguration())
                proxyRevision = NetworkProxy.shared.revision
            }
            return currentSession
        }
    }

    public init() {
        proxyRevision = NetworkProxy.shared.revision
        currentSession = URLSession(configuration: Self.defaultConfiguration())
    }

    public init(configuration: URLSessionConfiguration) {
        proxyRevision = nil
        currentSession = URLSession(configuration: configuration)
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        // By default connect directly instead of through the system HTTP proxy, like the
        // Electron app's default ("未启用（所有请求直连）"). A local proxy's CONNECT tunnel (e.g.
        // Surge on 127.0.0.1:6152) stalled TLS handshakes to some CDNs; a TUN-mode
        // proxy still sees the traffic. 设置 > 网络 can switch to the system or a manual proxy.
        NetworkProxy.shared.configure(config)
        return config
    }

    public struct Options: Sendable {
        public var headers: [String: String] = [:]
        public var timeout: TimeInterval = 15
        public var maxBytes: Int = 8 * 1024 * 1024
        /// nil follows up to 5 guarded redirects; 0 returns the 3xx response itself.
        public var maxRedirects: Int = 5
        public var acceptStatus: ClosedRange<Int> = 200...299
        public init() {}
    }

    public func get(_ url: URL, options: Options = Options()) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await send(request, options: options)
    }

    public func post(_ url: URL, json: Data, options: Options = Options()) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = json
        return try await send(request, options: options)
    }

    public func send(_ original: URLRequest, options: Options) async throws -> HTTPResponse {
        guard let url = original.url else { throw HongguoError(.input, "无效的地址") }
        try await URLGuard.check(url)
        var request = original
        request.timeoutInterval = options.timeout
        for (key, value) in options.headers { request.setValue(value, forHTTPHeaderField: key) }
        let delegate = GuardedRedirectDelegate(maxRedirects: options.maxRedirects)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch let error as HongguoError {
            throw error
        } catch {
            if let guardError = delegate.failure { throw guardError }
            throw Self.classify(error)
        }
        if let guardError = delegate.failure { throw guardError }
        guard let http = response as? HTTPURLResponse else { throw HongguoError(.upstream, "无效的响应") }
        if data.count > options.maxBytes { throw HongguoError(.upstream, "响应过大") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        let result = HTTPResponse(data: data, status: http.statusCode, headers: headers, url: http.url ?? url)
        let redirectPassthrough = options.maxRedirects == 0 && (300...399).contains(http.statusCode)
        guard options.acceptStatus.contains(http.statusCode) || redirectPassthrough else {
            throw HTTPStatusError(status: http.statusCode, response: result)
        }
        return result
    }

    static func classify(_ error: Error) -> HongguoError {
        if error is CancellationError { return HongguoError(.cancelled, "已取消") }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return HongguoError(.network, ns.localizedDescription) }
        switch ns.code {
        case NSURLErrorCancelled: return HongguoError(.cancelled, "已取消")
        case NSURLErrorTimedOut: return HongguoError(.timeout, "请求超时")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return HongguoError(.network, "DNS 解析失败，请稍后重试")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            return HongguoError(.network, "TLS 证书或握手失败")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return HongguoError(.security, "片源不是 HTTPS 地址，已拒绝")
        default: return HongguoError(.network, "网络连接失败，请稍后重试")
        }
    }
}

public struct HTTPStatusError: LocalizedError, @unchecked Sendable {
    public var status: Int
    public var response: HTTPResponse
    public var errorDescription: String? { "请求失败（HTTP \(status)）" }
}

/// Validates each redirect hop before URLSession follows it.
final class GuardedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxRedirects: Int
    private var count = 0
    private let lock = NSLock()
    private var _failure: HongguoError?
    var failure: HongguoError? { lock.lock(); defer { lock.unlock() }; return _failure }

    init(maxRedirects: Int) { self.maxRedirects = maxRedirects }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        count += 1
        let tooMany = count > maxRedirects
        lock.unlock()
        if maxRedirects == 0 { completionHandler(nil); return }
        guard !tooMany, let target = request.url else {
            fail(HongguoError(.upstream, "跳转次数过多"))
            task.cancel()
            completionHandler(nil)
            return
        }
        Task {
            do {
                try await URLGuard.check(target)
                completionHandler(request)
            } catch {
                self.fail(error as? HongguoError ?? URLGuard.blocked())
                task.cancel()
                completionHandler(nil)
            }
        }
    }

    private func fail(_ error: HongguoError) {
        lock.lock(); _failure = error; lock.unlock()
    }
}

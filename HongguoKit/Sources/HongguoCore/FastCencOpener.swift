// SPDX-License-Identifier: GPL-3.0-only
// Opens an encrypted MP4 header in a single 512 KiB ranged request (or directly from a disk-cached
// `[0 ..< N]` prefix with zero network RTT), reusing a process-wide URLSession for TCP/TLS/HTTP2
// keep-alive, failing over across server-supplied `backup_url`s on both CDN errors and edge-level
// HTTP 200 (Range ignored) responses, and cancelling immediately on HTTP 200 headers so a full
// MP4 is never downloaded into memory before falling back to whole-file decryption.
import Foundation

public struct FastCencOpenResult: Sendable {
    public let map: CencStreamMap
    /// Absolute input offset where `initialMediaData` begins (equal to `moovEnd`).
    public let initialMediaStart: Int64
    /// Encrypted media bytes already fetched right after `moov`.
    public let initialMediaData: Data
    /// Full encrypted bytes starting at offset 0 (`0 ..< rawPrefixData.count`), for unified disk caching.
    public let rawPrefixData: Data
    /// Total encrypted MP4 length reported by CDN `Content-Range` (or cached file metadata).
    public let totalLength: Int64
    /// True when parsed directly from a disk-cached prefix without touching the network.
    public let fromDisk: Bool
    /// The CDN URL that answered (may be a backup URL if the primary edge failed).
    public let resolvedURL: URL
}

public enum FastCencOpenError: LocalizedError, Equatable, Sendable {
    /// MP4 structure cannot be decrypted progressively (e.g. `mdat` precedes `moov`, >16 MiB header,
    /// or every CDN edge ignored `Range` and replied HTTP 200): caller should fall back to whole-file download.
    case unsupportedLayout(String)
    /// Upstream CDN rejected or dropped the request (e.g. HTTP 403 expired signature, 5xx, timeout).
    /// Caller should invalidate cached PlayInfo and re-resolve instead of downloading the whole file.
    case mediaUnavailable(status: Int?, message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLayout(let text): return text
        case .mediaUnavailable(_, let text): return text
        }
    }

    public var isExpiredOrAuthError: Bool {
        if case .mediaUnavailable(let status, _) = self {
            return status == 401 || status == 403 || status == 404 || status == 410
        }
        return false
    }
}

/// Edge-specific Range failure (HTTP 200, malformed `Content-Range`, oversized range body).
/// Treated separately from structural MP4 incompatibility so `FastCencOpener.open` tries remaining
/// backup CDN edges before falling back to `.unsupportedLayout`.
private struct EdgeRangeUnsupported: Error {
    let message: String
}

/// Process-wide URLSession shared by `FastCencOpener` so consecutive header Range opens reuse
/// warm TCP/TLS/HTTP2 connections instead of handshaking per episode.
private final class SharedHeaderRangeSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SharedHeaderRangeSession()

    private struct WeakFetcher { weak var value: StreamingRangeFetcher? }

    private let lock = NSLock()
    private let delegateQueue: OperationQueue
    private var session: URLSession!
    private var proxyRevision: Int
    private var routes: [ObjectIdentifier: WeakFetcher] = [:]

    override init() {
        delegateQueue = OperationQueue()
        delegateQueue.name = "HongguoDrama.FastCencHeaderSession"
        delegateQueue.maxConcurrentOperationCount = 1
        proxyRevision = NetworkProxy.shared.revision
        super.init()
        session = makeSession()
    }

    private func makeSession() -> URLSession {
        let cfg = HTTPClient.defaultConfiguration()
        cfg.timeoutIntervalForRequest = 12
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }

    func startTask(for request: URLRequest, owner: StreamingRangeFetcher) -> URLSessionDataTask {
        lock.withLock {
            if proxyRevision != NetworkProxy.shared.revision {
                session.finishTasksAndInvalidate()
                proxyRevision = NetworkProxy.shared.revision
                session = makeSession()
            }
            let task = session.dataTask(with: request)
            routes[ObjectIdentifier(task)] = WeakFetcher(value: owner)
            return task
        }
    }

    func removeRoute(for task: URLSessionTask) {
        lock.withLock { _ = routes.removeValue(forKey: ObjectIdentifier(task)) }
    }

    private func owner(for task: URLSessionTask) -> StreamingRangeFetcher? {
        lock.withLock { routes[ObjectIdentifier(task)]?.value }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let fetcher = owner(for: task) else {
            completionHandler(nil)
            return
        }
        fetcher.handleRedirect(response: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let fetcher = owner(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        fetcher.handleResponse(response: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner(for: dataTask)?.handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let fetcher: StreamingRangeFetcher? = lock.withLock {
            routes.removeValue(forKey: ObjectIdentifier(task))?.value
        }
        fetcher?.handleComplete(error: error)
    }
}

/// Streaming byte-range fetcher that inspects HTTP status and `Content-Range` on response headers.
/// Uses `SharedHeaderRangeSession.shared` when no test configuration is injected so TCP/TLS
/// connections stay warm across consecutive opens.
private final class StreamingRangeFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let from: Int
    private let maxBytes: Int
    private let skipURLGuard: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<([UInt8], Int64), Error>?
    private var ownedSession: URLSession?
    private var sharedRouter: SharedHeaderRangeSession?
    private var task: URLSessionDataTask?
    private var totalLength: Int64 = 0
    private var buffer = Data()
    private var finished = false

    init(from: Int, maxBytes: Int, skipURLGuard: Bool) {
        self.from = from
        self.maxBytes = maxBytes
        self.skipURLGuard = skipURLGuard
    }

    func fetch(url: URL, headers: [String: String], to: Int, configuration: URLSessionConfiguration?) async throws -> ([UInt8], Int64) {
        if !skipURLGuard {
            try await URLGuard.check(url)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")

        let dataTask: URLSessionDataTask
        let ephemeralSession: URLSession?
        let router: SharedHeaderRangeSession?
        if let configuration {
            configuration.timeoutIntervalForRequest = 12
            let s = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            ephemeralSession = s
            router = nil
            dataTask = s.dataTask(with: request)
        } else {
            ephemeralSession = nil
            router = SharedHeaderRangeSession.shared
            dataTask = SharedHeaderRangeSession.shared.startTask(for: request, owner: self)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let shouldStart = lock.withLock {
                    if finished {
                        cont.resume(throwing: CancellationError())
                        router?.removeRoute(for: dataTask)
                        dataTask.cancel()
                        ephemeralSession?.invalidateAndCancel()
                        return false
                    }
                    self.continuation = cont
                    self.ownedSession = ephemeralSession
                    self.sharedRouter = router
                    self.task = dataTask
                    return true
                }
                if shouldStart { dataTask.resume() }
            }
        } onCancel: {
            self.finish(with: .failure(CancellationError()), cancelTask: true)
        }
    }

    private func finish(with result: Result<([UInt8], Int64), Error>, cancelTask: Bool) {
        let (cont, ephemeral, router, dataTask): (CheckedContinuation<([UInt8], Int64), Error>?, URLSession?, SharedHeaderRangeSession?, URLSessionDataTask?) = lock.withLock {
            guard !finished else { return (nil, nil, nil, nil) }
            finished = true
            let c = continuation
            let s = ownedSession
            let r = sharedRouter
            let t = task
            continuation = nil
            ownedSession = nil
            sharedRouter = nil
            task = nil
            return (c, s, r, t)
        }
        if let dataTask {
            router?.removeRoute(for: dataTask)
            if cancelTask { dataTask.cancel() }
        }
        if let ephemeral {
            if cancelTask {
                ephemeral.invalidateAndCancel()
            } else {
                ephemeral.finishTasksAndInvalidate()
            }
        }
        cont?.resume(with: result)
    }

    // MARK: Shared & Ephemeral Callback Implementation

    func handleRedirect(response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url else {
            completionHandler(nil)
            finish(with: .failure(FastCencOpenError.mediaUnavailable(status: response.statusCode, message: "片源跳转地址无效")), cancelTask: true)
            return
        }
        if skipURLGuard {
            completionHandler(request)
            return
        }
        Task {
            do {
                try await URLGuard.check(target)
                completionHandler(request)
            } catch {
                completionHandler(nil)
                self.finish(with: .failure(FastCencOpenError.mediaUnavailable(status: response.statusCode, message: error.localizedDescription)), cancelTask: true)
            }
        }
    }

    func handleResponse(response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: .failure(FastCencOpenError.mediaUnavailable(status: nil, message: "片源响应无效")), cancelTask: true)
            return
        }
        if http.statusCode == 200 {
            // CDN edge ignored Range and is streaming the full file: abort immediately on headers
            // and signal `EdgeRangeUnsupported` so `open` tries backup edges before falling back.
            completionHandler(.cancel)
            finish(with: .failure(EdgeRangeUnsupported(message: "片源服务器不支持分段请求，改用整集解密")), cancelTask: true)
            return
        }
        if http.statusCode == 206 {
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard contentRange.hasPrefix("bytes \(from)-"),
                  let totalText = contentRange.split(separator: "/").last,
                  let total = Int64(totalText), total > 0 else {
                completionHandler(.cancel)
                finish(with: .failure(EdgeRangeUnsupported(message: "片源分段头格式异常，改用整集解密")), cancelTask: true)
                return
            }
            lock.withLock { totalLength = total }
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
        finish(with: .failure(FastCencOpenError.mediaUnavailable(status: http.statusCode, message: "片源头部请求失败（HTTP \(http.statusCode)）")), cancelTask: true)
    }

    func handleData(_ data: Data) {
        let exceeded: Bool = lock.withLock {
            guard !finished else { return false }
            buffer.append(data)
            return buffer.count > maxBytes
        }
        if exceeded {
            finish(with: .failure(EdgeRangeUnsupported(message: "片源分段响应超出预期，改用整集解密")), cancelTask: true)
        }
    }

    func handleComplete(error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                finish(with: .failure(CancellationError()), cancelTask: false)
            } else {
                finish(with: .failure(FastCencOpenError.mediaUnavailable(status: nil, message: error.localizedDescription)), cancelTask: false)
            }
            return
        }
        let (bytes, total): ([UInt8], Int64) = lock.withLock { ([UInt8](buffer), totalLength) }
        finish(with: .success((bytes, total)), cancelTask: false)
    }

    // MARK: Ephemeral URLSessionDataDelegate (custom configuration / unit tests)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        handleRedirect(response: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        handleResponse(response: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handleComplete(error: error)
    }
}

public enum FastCencOpener {
    /// Default initial range size: large enough to cover `moov` + opening `mdat` frames in one RTT.
    public static let defaultInitialBytes = 512 * 1024

    /// Attempts to open the MP4 header directly from an already-cached `[0 ..< N]` prefix buffer
    /// (zero network RTT). Returns nil if the cached prefix does not contain the full `moov` box.
    public static func openFromCachedPrefix(
        _ info: PlayInfo,
        rawPrefix: Data,
        totalLength: Int64
    ) throws -> FastCencOpenResult? {
        guard totalLength > 0, !rawPrefix.isEmpty else { return nil }
        guard let key = info.contentKey ?? info.spadeA.flatMap(CencDecryptor.deriveKey) else {
            throw HongguoError(.decrypt, "片源密钥无法解析")
        }
        let bytes = [UInt8](rawPrefix)
        switch CencStreamMap.headerStatus(bytes, totalLength: totalLength) {
        case .complete(let end):
            guard bytes.count >= end else { return nil }
            let map = try CencStreamMap(input: Array(bytes[0..<end]), inputLength: totalLength, key: key)
            let trailing = rawPrefix.count > end ? rawPrefix.subdata(in: end..<rawPrefix.count) : Data()
            return FastCencOpenResult(
                map: map,
                initialMediaStart: Int64(end),
                initialMediaData: trailing,
                rawPrefixData: rawPrefix,
                totalLength: totalLength,
                fromDisk: true,
                resolvedURL: info.url
            )
        case .needMore:
            return nil
        case .unsupported:
            throw FastCencOpenError.unsupportedLayout("片源不支持边下边播，改用整集解密")
        }
    }

    public static func open(_ info: PlayInfo,
                            candidates: [URL]? = nil,
                            configuration: URLSessionConfiguration? = nil,
                            skipURLGuardForTesting: Bool = false,
                            initialBytes: Int = defaultInitialBytes,
                            maxHeaderBytes: Int = 16 * 1024 * 1024) async throws -> FastCencOpenResult {
        guard let key = info.contentKey ?? info.spadeA.flatMap(CencDecryptor.deriveKey) else {
            throw HongguoError(.decrypt, "片源密钥无法解析")
        }
        let urls = candidates ?? PlayBackupURLs.shared.allCandidates(startingWith: info.url)
        var lastError: Error?
        var lastRangeUnsupported: EdgeRangeUnsupported?

        for candidateURL in urls {
            try Task.checkCancellation()
            do {
                return try await openSingle(
                    url: candidateURL,
                    headers: info.httpHeaders,
                    key: key,
                    configuration: configuration,
                    skipURLGuard: skipURLGuardForTesting,
                    initialBytes: initialBytes,
                    maxHeaderBytes: maxHeaderBytes
                )
            } catch let edgeUnsupported as EdgeRangeUnsupported {
                // Edge ignored Range (HTTP 200) or returned malformed Content-Range: try remaining
                // backup CDN nodes before falling back to whole-file decryption.
                lastRangeUnsupported = edgeUnsupported
                continue
            } catch let error as FastCencOpenError {
                if case .unsupportedLayout = error { throw error }
                lastError = error
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HongguoError where error.kind == .cancelled || error.kind == .decrypt {
                throw error
            } catch {
                lastError = error
                continue
            }
        }
        if let lastRangeUnsupported {
            throw FastCencOpenError.unsupportedLayout(lastRangeUnsupported.message)
        }
        throw lastError ?? FastCencOpenError.mediaUnavailable(status: nil, message: "片源头部请求失败")
    }

    private static func openSingle(
        url: URL,
        headers: [String: String],
        key: [UInt8],
        configuration: URLSessionConfiguration?,
        skipURLGuard: Bool,
        initialBytes: Int,
        maxHeaderBytes: Int
    ) async throws -> FastCencOpenResult {
        var prefix: [UInt8] = []
        var total: Int64 = 0
        var want = initialBytes
        while true {
            try Task.checkCancellation()
            if want > maxHeaderBytes {
                throw FastCencOpenError.unsupportedLayout("片源头部过大，改用整集解密")
            }
            if want > prefix.count {
                let from = prefix.count
                let to = want - 1
                let fetcher = StreamingRangeFetcher(from: from, maxBytes: to - from + 1 + 1024, skipURLGuard: skipURLGuard)
                let (bytes, length) = try await fetcher.fetch(url: url, headers: headers, to: to, configuration: configuration)
                prefix += bytes
                total = length
                if bytes.isEmpty {
                    throw FastCencOpenError.mediaUnavailable(status: nil, message: "片源头部不完整")
                }
            }
            switch CencStreamMap.headerStatus(prefix, totalLength: total) {
            case .complete(let end):
                if prefix.count >= end {
                    let map = try CencStreamMap(input: Array(prefix[0..<end]), inputLength: total, key: key)
                    let rawData = Data(prefix)
                    let trailing = prefix.count > end ? Data(prefix[end..<prefix.count]) : Data()
                    return FastCencOpenResult(
                        map: map,
                        initialMediaStart: Int64(end),
                        initialMediaData: trailing,
                        rawPrefixData: rawData,
                        totalLength: total,
                        fromDisk: false,
                        resolvedURL: url
                    )
                }
                want = end
            case .needMore(let n):
                want = max(n, prefix.count + 256 * 1024)
            case .unsupported:
                throw FastCencOpenError.unsupportedLayout("片源不支持边下边播，改用整集解密")
            }
        }
    }
}

// Ported from Vendor/hongguo-drama/macos/Sources/HongguoDrama/Player/StreamingResourceLoader.swift
// (commit 2da187e) and extended for iOS:
//   - `public` on the type and the members the app calls
//   - `prefix` + dynamic `prefixCacheKey` refresh: if disk prefetch extends the cached prefix
//     after this loader was created (e.g. a warmed player), subsequent ranges pick up the new
//     disk bytes instead of re-fetching from CDN
//   - `backupURLs`: seamless CDN failover across server-supplied `backup_url` / `backup_url_list`
//     using separate `streamOffset` vs `nextNeededOffset` tracking, strict 206 `Content-Range`
//     start validation, finite-range clamping, and truncated-EOF resume/failover
//   - `discard()`: cancels active tasks while keeping the process-wide shared URLSession warm
import AVFoundation
import HongguoCore
import UniformTypeIdentifiers

/// Process-wide URLSession shared by every `StreamingResourceLoader` so TCP/TLS/HTTP2
/// connections to VOD CDN hosts stay warm across episode switches.
private final class SharedStreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SharedStreamingSession()

    private struct WeakLoader { weak var value: StreamingResourceLoader? }

    private let lock = NSLock()
    private var routes: [Int: WeakLoader] = [:]
    private var tasks: [Int: URLSessionDataTask] = [:]
    private let delegateQueue: OperationQueue
    private var session: URLSession!

    init(configuration: URLSessionConfiguration? = nil) {
        delegateQueue = OperationQueue()
        delegateQueue.name = "HongguoDrama.SharedStreamingSession"
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        let config = configuration ?? HTTPClient.defaultConfiguration()
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    func makeTask(for request: URLRequest, owner: StreamingResourceLoader) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.withLock {
            routes[task.taskIdentifier] = WeakLoader(value: owner)
            tasks[task.taskIdentifier] = task
        }
        return task
    }

    func cancel(taskID: Int) {
        let task: URLSessionDataTask? = lock.withLock {
            routes[taskID] = nil
            return tasks.removeValue(forKey: taskID)
        }
        task?.cancel()
    }

    func cancel(taskIDs: [Int]) {
        guard !taskIDs.isEmpty else { return }
        let doomed: [URLSessionDataTask] = lock.withLock {
            taskIDs.compactMap { id in
                routes[id] = nil
                return tasks.removeValue(forKey: id)
            }
        }
        doomed.forEach { $0.cancel() }
    }

    private func owner(for taskID: Int) -> StreamingResourceLoader? {
        lock.withLock { routes[taskID]?.value }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let loader = owner(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        loader.handleResponse(dataTask: dataTask, response: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner(for: dataTask.taskIdentifier)?.handleData(dataTask: dataTask, data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let loader: StreamingResourceLoader? = lock.withLock {
            tasks[task.taskIdentifier] = nil
            return routes.removeValue(forKey: task.taskIdentifier)?.value
        }
        loader?.handleComplete(task: task, error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let loader = owner(for: task.taskIdentifier) else {
            completionHandler(nil)
            return
        }
        loader.handleRedirect(task: task, response: response, newRequest: request, completionHandler: completionHandler)
    }
}

/// Pure, unit-testable range transfer state shared by `StreamingResourceLoader`.
/// Keeps network arrival position (`streamOffset` / `skip`) strictly separate from the next
/// undelivered player byte (`nextNeededOffset`), validates `HTTP 206` `Content-Range` start,
/// clamps chunks at finite `inputEnd`, and detects truncated finite EOFs.
public struct RangeTransferState: Sendable, Equatable {
    /// Start offset requested on the current HTTP attempt.
    public var attemptStart: Int64
    /// Inclusive end offset requested by AVPlayer, or nil for open-ended (`bytes=<start>-`).
    public let inputEnd: Int64?
    /// Total file length declared by `Content-Range` (206) or `Content-Length` (200), when known.
    public var totalLength: Int64?
    /// Absolute offset of the next byte the player still needs (advances ONLY on delivery).
    public var nextNeededOffset: Int64
    /// Absolute offset of the next byte arriving from the network (advances on skip and delivery).
    public var streamOffset: Int64
    /// Leading bytes to discard when the server answered HTTP 200 from offset 0.
    public var skip: Int64 = 0

    public init(start: Int64, inputEnd: Int64?, totalLength: Int64? = nil) {
        self.attemptStart = start
        self.inputEnd = inputEnd
        self.totalLength = totalLength
        self.nextNeededOffset = start
        self.streamOffset = start
    }

    /// Inclusive end offset of the bytes that actually exist for this request: the earlier of
    /// the caller's `inputEnd` and the real file tail (`totalLength - 1`).
    public var effectiveEnd: Int64? {
        switch (inputEnd, totalLength) {
        case (let reqEnd?, let total?) where total > 0:
            return min(reqEnd, total - 1)
        case (let reqEnd?, _):
            return reqEnd
        case (nil, let total?) where total > 0:
            return total - 1
        case (nil, _):
            return nil
        }
    }

    /// Validates an HTTP 200 or 206 response header and records the server-declared total file
    /// length when present. Returns false when a 206 `Content-Range` does not start at `attemptStart`.
    public mutating func acceptResponse(statusCode: Int, contentRange: String?, expectedContentLength: Int64? = nil) -> Bool {
        if statusCode == 200 {
            if let expectedContentLength, expectedContentLength > 0 {
                totalLength = expectedContentLength
            }
            if attemptStart > 0 {
                skip = attemptStart
                streamOffset = 0
            } else {
                skip = 0
                streamOffset = 0
            }
            return true
        }
        guard statusCode == 206, let contentRange else { return false }
        let trimmed = contentRange.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return false }
        let spec = trimmed.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let rangeStart = Int64(bounds[0]),
              let rangeEnd = Int64(bounds[1]),
              rangeStart == attemptStart,
              rangeEnd >= rangeStart else {
            return false
        }
        if parts[1] != "*" {
            guard let total = Int64(parts[1]), total > 0, rangeEnd < total else { return false }
            totalLength = total
        }
        skip = 0
        streamOffset = attemptStart
        return true
    }

    /// Consumes a raw network chunk, returning the exact slice (clamped to `effectiveEnd`) and the
    /// input offset at which that slice starts, plus whether the request is now satisfied.
    public mutating func consume(_ data: Data) -> (deliver: Data, offset: Int64, reachedEnd: Bool) {
        var chunk = data
        if skip > 0 {
            let drop = Int(min(Int64(chunk.count), skip))
            chunk = chunk.dropFirst(drop)
            skip -= Int64(drop)
            streamOffset += Int64(drop)
            if chunk.isEmpty { return (Data(), nextNeededOffset, false) }
        }
        let deliveryOffset = nextNeededOffset
        if let end = effectiveEnd {
            let remaining = end - nextNeededOffset + 1
            if remaining <= 0 {
                return (Data(), deliveryOffset, true)
            }
            if Int64(chunk.count) > remaining {
                chunk = chunk.prefix(Int(remaining))
            }
        }
        let deliveredCount = Int64(chunk.count)
        streamOffset += deliveredCount
        nextNeededOffset += deliveredCount
        let reachedEnd = effectiveEnd.map { nextNeededOffset > $0 } ?? false
        return (chunk, deliveryOffset, reachedEnd)
    }

    /// True when the connection closed cleanly before reaching `effectiveEnd` (the earlier of the
    /// requested end and the declared file tail).
    public var isTruncated: Bool {
        guard let end = effectiveEnd else { return false }
        return nextNeededOffset <= end
    }

    /// Resets attempt-scoped tracking for a resume/failover starting at `nextNeededOffset`.
    public mutating func prepareResume() {
        attemptStart = nextNeededOffset
        streamOffset = nextNeededOffset
        skip = 0
    }
}

public final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let scheme = "hgstream"

    private let source: URL
    private let sources: [URL]
    private var activeSourceIndex = 0
    private let headers: [String: String]
    private let map: CencStreamMap?
    /// The opening of the encrypted media, already on disk or in memory. Can be upgraded lazily
    /// from `prefixCache` when background prefetch writes a larger unified prefix after init.
    private var prefix: MediaPrefixCache.Prefix?
    private let prefixCacheKey: String?
    private let prefixCache: MediaPrefixCache
    /// Upper bound that `MediaPrefixCache.prefetch` can ever populate for this asset.
    private let prefixCeiling: Int64
    /// True once `prefix` has already reached `prefixCeiling` from disk; avoids re-checking disk.
    private var prefixCompleteOnDisk = false
    private let sessionRouter: SharedStreamingSession
    private let queue = DispatchQueue(label: "HongguoDrama.StreamingResourceLoader")
    private var pending: [Int: Pending] = [:]
    private let taskLock = NSLock()
    private var activeTaskIDs: Set<Int> = []
    /// Reusable decryption buffer on `queue` to avoid per-chunk array allocations on hot 1080P streams.
    private var decryptScratch: [UInt8] = []
    /// Called on the main queue when all CDN sources failed (or decrypt/redirect blocked).
    public var onMediaFailure: (@Sendable (String) -> Void)?

    private final class Pending {
        let request: AVAssetResourceLoadingRequest
        var transfer: RangeTransferState
        /// Index into `sources` currently serving this loading request.
        var sourceIndex: Int
        /// Number of network attempts made for this loading request across CDN candidates.
        var attemptCount: Int

        init(request: AVAssetResourceLoadingRequest, start: Int64, inputEnd: Int64?, sourceIndex: Int, attemptCount: Int = 1) {
            self.request = request
            self.transfer = RangeTransferState(start: start, inputEnd: inputEnd)
            self.sourceIndex = sourceIndex
            self.attemptCount = attemptCount
        }
    }

    public init(source: URL, backupURLs: [URL]? = nil, headers: [String: String],
                map: CencStreamMap? = nil, prefix: MediaPrefixCache.Prefix? = nil,
                prefixCacheKey: String? = nil, prefixCache: MediaPrefixCache = .shared) {
        self.source = source
        let extras = backupURLs ?? PlayBackupURLs.shared.backups(for: source)
        var list = [source]
        for url in extras where !list.contains(url) { list.append(url) }
        self.sources = list
        self.headers = headers
        self.map = map
        self.prefix = prefix
        self.prefixCacheKey = prefixCacheKey
        self.prefixCache = prefixCache
        let maxPrefix = Int64(MediaPrefixCache.prefixBytes)
        let ceiling = map.map { min($0.inputLength, maxPrefix) } ?? maxPrefix
        self.prefixCeiling = ceiling
        self.prefixCompleteOnDisk = prefix.map { $0.fromDisk && $0.end >= ceiling } ?? false
        self.sessionRouter = SharedStreamingSession.shared
        super.init()
    }

    deinit {
        let ids = taskLock.withLock { Array(activeTaskIDs) }
        sessionRouter.cancel(taskIDs: ids)
    }

    /// Resolves cached prefix bytes for `range`, dynamically upgrading from `prefixCache` only
    /// when `range` lies within `prefixCeiling`, the disk prefix is not already complete, and
    /// lightweight file metadata confirms the file on disk grew past our current in-memory end.
    func resolvePrefixSlice(forInputRange range: Range<Int64>) -> (data: Data, fromDisk: Bool)? {
        if let current = prefix, let slice = current.slice(range) {
            let wantLength = Int(range.upperBound - range.lowerBound)
            if slice.count < wantLength, !prefixCompleteOnDisk, range.lowerBound < prefixCeiling,
               let key = prefixCacheKey,
               let diskEnd = prefixCache.cachedEndOffset(key: key), diskEnd > current.end,
               let newer = prefixCache.load(key: key), newer.end > current.end {
                prefix = newer
                if newer.fromDisk && newer.end >= prefixCeiling { prefixCompleteOnDisk = true }
                if let expanded = newer.slice(range) {
                    return (expanded, newer.fromDisk)
                }
            }
            return (slice, current.fromDisk)
        }
        // Once past the prefix ceiling (e.g. > 5 MiB) or once the full disk prefix is already
        // loaded, skip all filesystem calls so out-of-range playback never re-reads or touches mtime.
        guard !prefixCompleteOnDisk, range.lowerBound < prefixCeiling, let key = prefixCacheKey else {
            return nil
        }
        let currentEnd = prefix?.end ?? 0
        guard let diskEnd = prefixCache.cachedEndOffset(key: key), diskEnd > currentEnd,
              let newer = prefixCache.load(key: key) else {
            return nil
        }
        if newer.end > currentEnd {
            prefix = newer
            if newer.fromDisk && newer.end >= prefixCeiling { prefixCompleteOnDisk = true }
        }
        if let slice = newer.slice(range) {
            return (slice, newer.fromDisk)
        }
        return nil
    }

    public func makeAsset() -> AVURLAsset {
        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    public func cancelAll() {
        queue.async {
            let ids = self.taskLock.withLock { () -> [Int] in
                let all = Array(self.activeTaskIDs)
                self.activeTaskIDs.removeAll()
                return all
            }
            self.sessionRouter.cancel(taskIDs: ids)
        }
    }

    /// Stops every request belonging to this loader while keeping the shared URLSession warm.
    public func discard() {
        queue.async {
            self.pending.removeAll()
            self.decryptScratch.removeAll(keepingCapacity: false)
            let ids = self.taskLock.withLock { () -> [Int] in
                let all = Array(self.activeTaskIDs)
                self.activeTaskIDs.removeAll()
                return all
            }
            self.sessionRouter.cancel(taskIDs: ids)
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let map {
            return serveEncrypted(loadingRequest, map: map)
        }
        var start: Int64 = 0
        var inputEnd: Int64? = 1
        if let dataRequest = loadingRequest.dataRequest {
            start = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                inputEnd = nil
            } else {
                let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
                inputEnd = max(start, end)
            }
        }
        startTask(for: loadingRequest, inputStart: start, inputEnd: inputEnd, sourceIndex: activeSourceIndex, attemptCount: 1)
        return true
    }

    /// Header bytes from memory, the rest from disk/memory prefix (dynamically refreshed if
    /// background prefetch grew the cache) or network shifted by `map.delta`.
    private func serveEncrypted(_ loadingRequest: AVAssetResourceLoadingRequest, map: CencStreamMap) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = AVFileType.mp4.rawValue
            info.contentLength = map.outputLength
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let headerLength = Int64(map.header.count)
        var offset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let end: Int64 = dataRequest.requestsAllDataToEndOfResource
            ? map.outputLength
            : min(map.outputLength, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        if offset < headerLength {
            let upper = min(end, headerLength)
            dataRequest.respond(with: Data(map.header[Int(offset)..<Int(upper)]))
            offset = upper
        }
        if offset >= end {
            loadingRequest.finishLoading()
            return true
        }
        let inputRange = map.inputOffset(forOutput: offset)..<map.inputOffset(forOutput: end)
        if let hit = resolvePrefixSlice(forInputRange: inputRange) {
            if let decrypted = decryptData(hit.data, map: map, atInputOffset: inputRange.lowerBound) {
                dataRequest.respond(with: decrypted)
                offset += Int64(decrypted.count)
                if hit.fromDisk { prefixCache.noteServed(decrypted.count) }
            }
            if offset >= end {
                loadingRequest.finishLoading()
                return true
            }
        }
        let inputStart = map.inputOffset(forOutput: offset)
        let inputEnd = map.inputOffset(forOutput: end) - 1
        startTask(for: loadingRequest, inputStart: inputStart, inputEnd: inputEnd, sourceIndex: activeSourceIndex, attemptCount: 1)
        return true
    }

    private func startTask(for loadingRequest: AVAssetResourceLoadingRequest, inputStart: Int64,
                           inputEnd: Int64?, sourceIndex: Int, attemptCount: Int) {
        let url = sources[sourceIndex % sources.count]
        let range = inputEnd.map { "bytes=\(inputStart)-\($0)" } ?? "bytes=\(inputStart)-"
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(range, forHTTPHeaderField: "Range")
        let task = sessionRouter.makeTask(for: request, owner: self)
        let id = task.taskIdentifier
        pending[id] = Pending(request: loadingRequest, start: inputStart, inputEnd: inputEnd,
                              sourceIndex: sourceIndex % sources.count, attemptCount: attemptCount)
        taskLock.withLock { _ = activeTaskIDs.insert(id) }
        task.resume()
    }

    /// Seamlessly moves an active loading request to the next backup CDN edge (or retries once
    /// after a truncated EOF) starting at `item.transfer.nextNeededOffset` (never `streamOffset`).
    private func failoverIfPossible(_ item: Pending, oldTaskID: Int, allowSingleSourceResume: Bool = false) -> Bool {
        let maxAttempts = allowSingleSourceResume ? max(sources.count, 2) : sources.count
        guard item.attemptCount < maxAttempts else { return false }
        item.transfer.prepareResume()
        let resumeStart = item.transfer.nextNeededOffset
        if let end = item.transfer.effectiveEnd, resumeStart > end { return false }
        let nextIndex = (item.sourceIndex + 1) % sources.count
        pending[oldTaskID] = nil
        taskLock.withLock { _ = activeTaskIDs.remove(oldTaskID) }
        startTask(for: item.request, inputStart: resumeStart, inputEnd: item.transfer.effectiveEnd ?? item.transfer.inputEnd,
                  sourceIndex: nextIndex, attemptCount: item.attemptCount + 1)
        return true
    }

    private func decryptData(_ chunk: Data, map: CencStreamMap, atInputOffset inputOffset: Int64) -> Data? {
        guard !chunk.isEmpty else { return Data() }
        decryptScratch.removeAll(keepingCapacity: true)
        decryptScratch.append(contentsOf: chunk)
        guard (try? map.decrypt(&decryptScratch, atInputOffset: inputOffset)) != nil else { return nil }
        return Data(decryptScratch)
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (id, item) in pending where item.request === loadingRequest {
            pending[id] = nil
            taskLock.withLock { _ = activeTaskIDs.remove(id) }
            sessionRouter.cancel(taskID: id)
        }
    }

    // MARK: SharedStreamingSession callbacks

    fileprivate func handleResponse(dataTask: URLSessionDataTask, response: URLResponse,
                                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async {
            let id = dataTask.taskIdentifier
            guard let item = self.pending[id] else { completionHandler(.cancel); return }
            guard let http = response as? HTTPURLResponse,
                  item.transfer.acceptResponse(statusCode: http.statusCode,
                                               contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                               expectedContentLength: http.expectedContentLength > 0 ? http.expectedContentLength : nil) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if self.failoverIfPossible(item, oldTaskID: id) {
                    completionHandler(.cancel)
                    return
                }
                self.fail(item, id: id, message: "片源请求失败（HTTP \(status)）")
                completionHandler(.cancel)
                return
            }
            // Promote a healthy backup edge for future range requests on this episode.
            self.activeSourceIndex = item.sourceIndex
            if self.map == nil, let info = item.request.contentInformationRequest {
                info.contentType = Self.contentType(for: http.mimeType)
                info.isByteRangeAccessSupported = http.statusCode == 206
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalText = range.split(separator: "/").last, let total = Int64(totalText) {
                    info.contentLength = total
                } else if http.expectedContentLength > 0 {
                    info.contentLength = http.expectedContentLength
                }
            }
            if item.request.dataRequest == nil {
                item.request.finishLoading()
                self.pending[id] = nil
                self.taskLock.withLock { _ = self.activeTaskIDs.remove(id) }
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }
    }

    fileprivate func handleData(dataTask: URLSessionDataTask, data: Data) {
        queue.async {
            let id = dataTask.taskIdentifier
            guard let item = self.pending[id], let dataRequest = item.request.dataRequest else { return }
            let consumed = item.transfer.consume(data)
            if !consumed.deliver.isEmpty {
                let payload: Data
                if let map = self.map {
                    guard let decrypted = self.decryptData(consumed.deliver, map: map, atInputOffset: consumed.offset) else {
                        self.fail(item, id: id, message: "片源解密失败")
                        self.sessionRouter.cancel(taskID: id)
                        return
                    }
                    payload = decrypted
                } else {
                    payload = consumed.deliver
                }
                dataRequest.respond(with: payload)
            }
            if consumed.reachedEnd {
                item.request.finishLoading()
                self.pending[id] = nil
                self.taskLock.withLock { _ = self.activeTaskIDs.remove(id) }
                self.sessionRouter.cancel(taskID: id)
            }
        }
    }

    fileprivate func handleComplete(task: URLSessionTask, error: Error?) {
        queue.async {
            let id = task.taskIdentifier
            self.taskLock.withLock { _ = self.activeTaskIDs.remove(id) }
            guard let item = self.pending.removeValue(forKey: id) else { return }
            if let error {
                if (error as NSError).code == NSURLErrorCancelled { return }
                if self.failoverIfPossible(item, oldTaskID: id) { return }
                self.fail(item, id: id, message: describeError(error))
                return
            }
            // Connection closed cleanly before delivering all requested finite bytes: resume/failover.
            if item.transfer.isTruncated {
                if self.failoverIfPossible(item, oldTaskID: id, allowSingleSourceResume: true) { return }
                self.fail(item, id: id, message: "片源传输提前结束")
                return
            }
            item.request.finishLoading()
        }
    }

    fileprivate func handleRedirect(task: URLSessionTask, response: HTTPURLResponse,
                                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url else { completionHandler(nil); return }
        Task {
            do {
                try await URLGuard.check(target)
                completionHandler(request)
            } catch {
                self.queue.async {
                    let id = task.taskIdentifier
                    if let item = self.pending[id] {
                        if !self.failoverIfPossible(item, oldTaskID: id) {
                            self.fail(item, id: id, message: describeError(error))
                        }
                    }
                    self.sessionRouter.cancel(taskID: id)
                }
                completionHandler(nil)
            }
        }
    }

    private func fail(_ item: Pending, id: Int, message: String) {
        pending[id] = nil
        taskLock.withLock { _ = activeTaskIDs.remove(id) }
        item.request.finishLoading(with: NSError(domain: "HongguoDrama", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        let callback = onMediaFailure
        DispatchQueue.main.async { callback?(message) }
    }

    private static func contentType(for mime: String?) -> String {
        if let mime, let type = UTType(mimeType: mime), type.conforms(to: .audiovisualContent) { return type.identifier }
        return AVFileType.mp4.rawValue
    }
}

public func describeError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

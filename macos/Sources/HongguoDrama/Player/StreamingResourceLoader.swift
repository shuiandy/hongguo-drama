import AVFoundation
import HongguoCore
import UniformTypeIdentifiers

/// Streams media into AVPlayer through our own URLSession, so the upstream User-Agent /
/// Referer are sent and every redirect passes `URLGuard`. AVPlayer sees a private
/// `hgstream://` URL and asks this delegate for byte ranges.
///
/// With a `CencStreamMap` the loader serves a virtual clear MP4: the rebuilt header comes
/// from memory and later ranges are fetched shifted by `map.delta` and decrypted as they arrive,
/// so encrypted episodes start playing without downloading the whole file first.
final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let scheme = "hgstream"

    private let source: URL
    private let headers: [String: String]
    private let map: CencStreamMap?
    private let queue = DispatchQueue(label: "HongguoDrama.StreamingResourceLoader")
    private var session: URLSession!
    private var pending: [Int: Pending] = [:]
    /// Called on the main queue when the upstream refused the media (HTTP error, blocked redirect, decrypt error).
    var onMediaFailure: (@Sendable (String) -> Void)?

    private final class Pending {
        let request: AVAssetResourceLoadingRequest
        /// Input offset the HTTP request started at.
        let start: Int64
        /// Absolute input offset of the next byte that will arrive (after any skip).
        var cursor: Int64
        /// Bytes to drop when the server ignored our Range header and replied 200 from offset 0.
        var skip: Int64 = 0
        init(request: AVAssetResourceLoadingRequest, start: Int64) {
            self.request = request
            self.start = start
            self.cursor = start
        }
    }

    init(source: URL, headers: [String: String], map: CencStreamMap? = nil) {
        self.source = source
        self.headers = headers
        self.map = map
        super.init()
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue
        operationQueue.maxConcurrentOperationCount = 1
        let config = HTTPClient.defaultConfiguration()
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: operationQueue)
    }

    deinit { session.invalidateAndCancel() }

    func makeAsset() -> AVURLAsset {
        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func cancelAll() {
        queue.async {
            self.session.getAllTasks { $0.forEach { $0.cancel() } }
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let map {
            return serveEncrypted(loadingRequest, map: map)
        }
        var range = "bytes=0-1"
        var start: Int64 = 0
        if let dataRequest = loadingRequest.dataRequest {
            start = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                range = "bytes=\(start)-"
            } else {
                let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
                range = "bytes=\(start)-\(max(start, end))"
            }
        }
        startTask(for: loadingRequest, range: range, inputStart: start)
        return true
    }

    /// Header bytes from memory, the rest from the network shifted by `map.delta`.
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
        let inputStart = map.inputOffset(forOutput: offset)
        let inputEnd = map.inputOffset(forOutput: end) - 1
        startTask(for: loadingRequest, range: "bytes=\(inputStart)-\(inputEnd)", inputStart: inputStart)
        return true
    }

    private func startTask(for loadingRequest: AVAssetResourceLoadingRequest, range: String, inputStart: Int64) {
        var request = URLRequest(url: source)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(range, forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        pending[task.taskIdentifier] = Pending(request: loadingRequest, start: inputStart)
        task.resume()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (id, item) in pending where item.request === loadingRequest {
            pending[id] = nil
            session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == id }?.cancel() }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let item = pending[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            fail(item, id: dataTask.taskIdentifier, message: "片源请求失败（HTTP \(status)）")
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 200 && item.start > 0 {
            item.skip = item.start
            item.cursor = 0
        }
        if map == nil, let info = item.request.contentInformationRequest {
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
            pending[dataTask.taskIdentifier] = nil
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let item = pending[dataTask.taskIdentifier], let dataRequest = item.request.dataRequest else { return }
        var chunk = data
        if item.skip > 0 {
            let drop = Int(min(Int64(chunk.count), item.skip))
            chunk = chunk.dropFirst(drop)
            item.skip -= Int64(drop)
            item.cursor += Int64(drop)
            if chunk.isEmpty { return }
        }
        if let map {
            var bytes = [UInt8](chunk)
            do {
                try map.decrypt(&bytes, atInputOffset: item.cursor)
            } catch {
                fail(item, id: dataTask.taskIdentifier, message: describeError(error))
                dataTask.cancel()
                return
            }
            item.cursor += Int64(bytes.count)
            chunk = Data(bytes)
        } else {
            item.cursor += Int64(chunk.count)
        }
        dataRequest.respond(with: chunk)
        if !dataRequest.requestsAllDataToEndOfResource {
            let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
            if dataRequest.currentOffset >= end {
                item.request.finishLoading()
                pending[dataTask.taskIdentifier] = nil
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let item = pending.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            item.request.finishLoading(with: error)
        } else {
            item.request.finishLoading()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url else { completionHandler(nil); return }
        Task {
            do {
                try await URLGuard.check(target)
                completionHandler(request)
            } catch {
                self.queue.async {
                    if let item = self.pending[task.taskIdentifier] {
                        self.fail(item, id: task.taskIdentifier, message: describeError(error))
                    }
                    task.cancel()
                }
                completionHandler(nil)
            }
        }
    }

    private func fail(_ item: Pending, id: Int, message: String) {
        pending[id] = nil
        item.request.finishLoading(with: NSError(domain: "HongguoDrama", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        let callback = onMediaFailure
        DispatchQueue.main.async { callback?(message) }
    }

    private static func contentType(for mime: String?) -> String {
        if let mime, let type = UTType(mimeType: mime), type.conforms(to: .audiovisualContent) { return type.identifier }
        return AVFileType.mp4.rawValue
    }
}

func describeError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

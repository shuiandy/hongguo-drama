import AVFoundation
import HongguoCore
import UniformTypeIdentifiers

/// Streams plain (unencrypted) media into AVPlayer through our own URLSession, so the
/// upstream User-Agent / Referer are sent and every redirect passes `URLGuard`.
/// AVPlayer sees a private `hgstream://` URL and asks this delegate for byte ranges.
final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let scheme = "hgstream"

    private let source: URL
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "HongguoDrama.StreamingResourceLoader")
    private var session: URLSession!
    private var pending: [Int: Pending] = [:]
    /// Called on the main queue when the upstream refused the media (HTTP error or blocked redirect).
    var onMediaFailure: (@Sendable (String) -> Void)?

    private final class Pending {
        let request: AVAssetResourceLoadingRequest
        /// Bytes to drop when the server ignored our Range header and replied 200 from offset 0.
        var skip: Int64 = 0
        let start: Int64
        init(request: AVAssetResourceLoadingRequest, start: Int64) {
            self.request = request
            self.start = start
        }
    }

    init(source: URL, headers: [String: String]) {
        self.source = source
        self.headers = headers
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
        var request = URLRequest(url: source)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        var start: Int64 = 0
        if let dataRequest = loadingRequest.dataRequest {
            start = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            } else {
                let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
                request.setValue("bytes=\(start)-\(max(start, end))", forHTTPHeaderField: "Range")
            }
        } else {
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        pending[task.taskIdentifier] = Pending(request: loadingRequest, start: start)
        task.resume()
        return true
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
        if http.statusCode == 200 && item.start > 0 { item.skip = item.start }
        if let info = item.request.contentInformationRequest {
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
            if chunk.isEmpty { return }
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

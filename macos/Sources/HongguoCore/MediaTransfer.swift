import Foundation

public struct MediaTransferRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    /// ETag or Last-Modified of the partial file; sent as `If-Range` when resuming.
    public var validator: String?
    /// Total size recorded when the partial file was started; a different total restarts.
    public var expectedTotal: Int64?
    public init(url: URL, headers: [String: String], validator: String? = nil, expectedTotal: Int64? = nil) {
        self.url = url; self.headers = headers; self.validator = validator; self.expectedTotal = expectedTotal
    }
}

public struct MediaTransferResult: Sendable, Equatable {
    public var totalBytes: Int64
    public var validator: String?
    /// True when the server honoured the range and the existing bytes were kept.
    public var resumed: Bool
}

/// Streams one media URL into a file, resuming from the bytes already there.
public protocol MediaTransferring: Sendable {
    /// `onResponse` fires once the response headers are accepted, with the total size (-1 when
    /// unknown) and the validator, so a pause right after still has what a later resume needs.
    func transfer(_ request: MediaTransferRequest, to file: URL,
                  onResponse: @escaping @Sendable (_ total: Int64, _ validator: String?) -> Void,
                  progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws -> MediaTransferResult
}

/// What a resumed response means for the partial file. Pure, so it is unit tested.
enum RangeDecision: Equatable {
    /// 206 matching our offset: append, total is known.
    case append(total: Int64)
    /// 200 (range ignored or validator changed): truncate and write from zero.
    case restart(total: Int64?)
    /// 416 with the full size already on disk.
    case alreadyComplete(total: Int64)
    case failure(status: Int)

    static func decide(status: Int, offset: Int64, contentRange: String?, contentLength: Int64?, expectedTotal: Int64?) -> RangeDecision {
        switch status {
        case 206:
            guard let range = contentRange.flatMap(parseContentRange), range.start == offset else { return .restart(total: nil) }
            if let expectedTotal, let total = range.total, total != expectedTotal { return .restart(total: nil) }
            return .append(total: range.total ?? (contentLength.map { offset + $0 } ?? -1))
        case 200...299:
            return .restart(total: contentLength)
        case 416:
            if let total = contentRange.flatMap(parseContentRange)?.total ?? expectedTotal, total == offset, offset > 0 {
                return .alreadyComplete(total: total)
            }
            return .restart(total: nil)
        default:
            return .failure(status: status)
        }
    }

    /// `bytes 100-199/1000`, `bytes */1000`, `bytes 0-9/*`.
    static func parseContentRange(_ header: String) -> (start: Int64?, total: Int64?)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let halves = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let total = Int64(halves[1])
        if halves[0] == "*" { return (nil, total) }
        guard let start = halves[0].split(separator: "-").first.flatMap({ Int64($0) }) else { return nil }
        return (start, total)
    }
}

/// URLSession implementation. Every URL and redirect hop goes through `URLGuard`; data is
/// written as it arrives, so memory stays flat for long episodes.
public final class URLSessionMediaTransfer: MediaTransferring, @unchecked Sendable {
    private let session: URLSession
    private let guardCheck: @Sendable (URL) async throws -> Void

    public init(configuration: URLSessionConfiguration = HTTPClient.defaultConfiguration(),
                guardCheck: @escaping @Sendable (URL) async throws -> Void = { try await URLGuard.check($0) }) {
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: configuration)
        self.guardCheck = guardCheck
    }

    public func transfer(_ request: MediaTransferRequest, to file: URL,
                         onResponse: @escaping @Sendable (Int64, String?) -> Void,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MediaTransferResult {
        try await guardCheck(request.url)
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let offset = ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var urlRequest = URLRequest(url: request.url)
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        if offset > 0 {
            urlRequest.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let validator = request.validator { urlRequest.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let delegate = TransferDelegate(handle: handle, offset: offset, expectedTotal: request.expectedTotal,
                                        guardCheck: guardCheck, onResponse: onResponse, progress: progress)
        let task = session.dataTask(with: urlRequest)
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let handle: FileHandle
    let offset: Int64
    let expectedTotal: Int64?
    let guardCheck: @Sendable (URL) async throws -> Void
    let progress: @Sendable (Int64, Int64) -> Void
    let onResponse: @Sendable (Int64, String?) -> Void
    var continuation: CheckedContinuation<MediaTransferResult, Error>?
    private var received: Int64 = 0
    private var total: Int64 = -1
    private var validator: String?
    private var resumed = false
    private var failure: Error?
    private var lastReport = Date.distantPast
    private var redirects = 0

    init(handle: FileHandle, offset: Int64, expectedTotal: Int64?, guardCheck: @escaping @Sendable (URL) async throws -> Void,
         onResponse: @escaping @Sendable (Int64, String?) -> Void, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.handle = handle; self.offset = offset; self.expectedTotal = expectedTotal
        self.guardCheck = guardCheck; self.onResponse = onResponse; self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let target = request.url else {
            failure = HongguoError(.upstream, "跳转次数过多")
            completionHandler(nil)
            return
        }
        let check = guardCheck
        Task {
            do { try await check(target); completionHandler(request) }
            catch {
                self.failure = error
                task.cancel()
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = HongguoError(.upstream, "无效的响应")
            completionHandler(.cancel)
            return
        }
        validator = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
        let length = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        let decision = RangeDecision.decide(status: http.statusCode, offset: offset,
                                            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                            contentLength: length, expectedTotal: expectedTotal)
        do {
            switch decision {
            case .append(let total):
                try handle.seekToEnd()
                received = offset
                self.total = total
                resumed = true
            case .restart(let total):
                if http.statusCode == 206 || http.statusCode == 416 {
                    // A range body that does not start at our offset, or 416: start over cleanly.
                    try handle.truncate(atOffset: 0)
                    failure = MediaTransferRestart()
                    completionHandler(.cancel)
                    return
                }
                try handle.truncate(atOffset: 0)
                received = 0
                self.total = total ?? -1
            case .alreadyComplete(let total):
                received = total
                self.total = total
                resumed = true
                completionHandler(.cancel)
                failure = nil
                finished = true
                return
            case .failure(let status):
                failure = HTTPMediaStatusError(status: status)
                completionHandler(.cancel)
                return
            }
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        onResponse(total, validator)
        progress(received, total)
        completionHandler(.allow)
    }

    private var finished = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastReport) >= 0.15 {
                lastReport = Date()
                progress(received, total)
            }
        } catch {
            failure = HongguoError(.input, "写入下载文件失败：\(error.localizedDescription)")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if finished {
            continuation.resume(returning: MediaTransferResult(totalBytes: total, validator: validator, resumed: true))
            return
        }
        if let failure { continuation.resume(throwing: failure); return }
        if let error { continuation.resume(throwing: HTTPClient.classify(error)); return }
        if received == 0 || (total >= 0 && received != total) {
            continuation.resume(throwing: HongguoError(.network, "视频下载不完整，请重试"))
            return
        }
        progress(received, received)
        continuation.resume(returning: MediaTransferResult(totalBytes: received, validator: validator, resumed: resumed))
    }
}

/// The server answered a range request in a way that requires a fresh start.
struct MediaTransferRestart: Error {}

public struct HTTPMediaStatusError: LocalizedError, Sendable, Equatable {
    public var status: Int
    public var errorDescription: String? { "片源请求失败（HTTP \(status)）" }
    /// 408 and 5xx are worth an automatic retry.
    public var isTransient: Bool { status == 408 || status == 429 || (500...599).contains(status) }
}

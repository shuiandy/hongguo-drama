import CryptoKit
import Darwin
import Foundation
import HongguoCore
import Network

/// One publication belongs to one player selection. All callers await the same URL,
/// and retiring this selection cannot stop the listener serving a different selection.
public final class CastPublication: Sendable {
    private let server: LocalCastServer
    private let task: Task<URL, Error>

    public init(useLoopbackForTesting: Bool = false,
                resolve: @escaping @Sendable () async throws -> LocalCastServer.Media) {
        let server = LocalCastServer()
        self.server = server
        task = Task {
            try Task.checkCancellation()
            let media = try await resolve()
            try Task.checkCancellation()
            let url = try await server.publish(media, useLoopbackForTesting: useLoopbackForTesting)
            try Task.checkCancellation()
            return url
        }
    }

    public func url() async throws -> URL { try await task.value }

    public func cancel() {
        task.cancel()
        Task { [task, server] in
            _ = await task.result
            await server.stop()
        }
    }
}

/// Minimal HTTP/1.1 byte-range server on the device's Wi-Fi interface so AirPlay 2 receivers
/// (Apple TV, AirPlay TVs, Macs) can pull on-the-fly decrypted Hongguo MP4 streams directly
/// over LAN. Custom `hgstream://` `AVAssetResourceLoader` URLs cannot be handed off to
/// external AirPlay receivers; exposing a standard `http://<lan-ip>:<port>/cast/<token>.mp4`
/// URL lets `AVPlayer.allowsExternalPlayback` work at full native resolution with seeking.
public actor LocalCastServer {
    public static let shared = LocalCastServer()

    public enum Media: Sendable {
        case file(url: URL, size: Int64)
        case encrypted(source: URL, headers: [String: String], map: CencStreamMap, prefix: MediaPrefixCache.Prefix?)
        case remote(source: URL, headers: [String: String], contentLength: Int64?)
    }

    public enum CastServerError: LocalizedError, Sendable {
        case noLocalNetworkAddress
        case listenerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noLocalNetworkAddress: return "未检测到局域网 Wi-Fi 地址，请确认与投屏设备在同一局域网"
            case .listenerFailed(let msg): return "投屏本地服务启动失败：\(msg)"
            }
        }
    }

    private let queue = DispatchQueue(label: "HongguoDrama.LocalCastServer", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var activeToken: String = ""
    private var activeMedia: Media?
    private let session: URLSession

    public init() {
        let config = HTTPClient.defaultConfiguration()
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config)
    }

    /// Starts the LAN HTTP server if needed and publishes `media` under a fresh unguessable path.
    /// When `useLoopbackForTesting` is true, returns `127.0.0.1` instead of requiring Wi-Fi `en0`.
    public func publish(_ media: Media, useLoopbackForTesting: Bool = false) async throws -> URL {
        try await startIfNeeded()
        let host: String
        if useLoopbackForTesting {
            host = "127.0.0.1"
        } else if let lan = Self.localIPv4Address() {
            host = lan
        } else {
            throw CastServerError.noLocalNetworkAddress
        }
        let token = Self.randomToken()
        activeToken = token
        activeMedia = media
        return URL(string: "http://\(host):\(port)/cast/\(token).mp4")!
    }

    /// Tears down the listener and forgets published media.
    public func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        activeToken = ""
        activeMedia = nil
    }

    private func startIfNeeded() async throws {
        if listener != nil, port > 0 { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: params, on: .any)
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let resumed = LockedFlag()
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumed.markOnce() else { return }
                    if let p = newListener.port?.rawValue, p > 0 {
                        cont.resume(returning: p)
                    } else {
                        cont.resume(throwing: CastServerError.listenerFailed("端口分配失败"))
                    }
                case .failed(let error):
                    guard resumed.markOnce() else { return }
                    cont.resume(throwing: CastServerError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    guard resumed.markOnce() else { return }
                    cont.resume(throwing: CastServerError.listenerFailed("服务已取消"))
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                Task { await self.handleConnection(connection) }
            }
            newListener.start(queue: queue)
        }
        listener = newListener
        port = boundPort
    }

    private func mediaForPath(_ path: String) -> Media? {
        guard !activeToken.isEmpty, path == "/cast/\(activeToken).mp4" else { return nil }
        return activeMedia
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { [weak self] in
            guard let self else { connection.cancel(); return }
            defer { connection.cancel() }
            guard let requestHead = await Self.receiveRequestHeaders(on: connection) else { return }
            guard let parsed = Self.parseHTTPRequest(requestHead) else {
                await Self.sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
                return
            }
            guard parsed.method == "GET" || parsed.method == "HEAD" else {
                await Self.sendRaw("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
                return
            }
            guard let media = await self.mediaForPath(parsed.path) else {
                await Self.sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
                return
            }
            await self.serve(media: media, method: parsed.method, rangeHeader: parsed.rangeHeader, on: connection)
        }
    }

    private func serve(media: Media, method: String, rangeHeader: String?, on connection: NWConnection) async {
        switch media {
        case .file(let url, let size):
            await serveFile(url: url, totalSize: size, method: method, rangeHeader: rangeHeader, on: connection)
        case .encrypted(let source, let headers, let map, let prefix):
            await serveEncrypted(source: source, headers: headers, map: map, prefix: prefix,
                                 method: method, rangeHeader: rangeHeader, on: connection)
        case .remote(let source, let headers, let knownLength):
            await serveRemote(source: source, headers: headers, knownLength: knownLength,
                              method: method, rangeHeader: rangeHeader, on: connection)
        }
    }

    // MARK: - Route 1: Local File

    private func serveFile(url: URL, totalSize: Int64, method: String, rangeHeader: String?, on connection: NWConnection) async {
        guard totalSize > 0, let range = Self.resolveRange(rangeHeader, total: totalSize) else {
            await Self.sendRaw("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(totalSize)\r\nConnection: close\r\n\r\n", on: connection)
            return
        }
        let header = Self.responseHeaders(status: range.isPartial ? "206 Partial Content" : "200 OK",
                                          start: range.start, end: range.end, total: totalSize,
                                          isPartial: range.isPartial)
        guard await Self.sendData(Data(header.utf8), on: connection) else { return }
        if method == "HEAD" { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.start))
            var remaining = range.length
            let chunkSize = 262_144
            while remaining > 0 {
                let toRead = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else { break }
                guard await Self.sendData(chunk, on: connection) else { break }
                remaining -= Int64(chunk.count)
            }
        } catch {
        }
    }

    // MARK: - Route 2: On-the-Fly CENC Progressive Decryption

    private func serveEncrypted(source: URL, headers: [String: String], map: CencStreamMap,
                                prefix: MediaPrefixCache.Prefix?, method: String,
                                rangeHeader: String?, on connection: NWConnection) async {
        let total = map.outputLength
        guard total > 0, let range = Self.resolveRange(rangeHeader, total: total) else {
            await Self.sendRaw("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nConnection: close\r\n\r\n", on: connection)
            return
        }
        let header = Self.responseHeaders(status: range.isPartial ? "206 Partial Content" : "200 OK",
                                          start: range.start, end: range.end, total: total,
                                          isPartial: range.isPartial)
        guard await Self.sendData(Data(header.utf8), on: connection) else { return }
        if method == "HEAD" { return }

        var cursor = range.start
        let exclusiveEnd = range.end + 1
        let headerLen = Int64(map.header.count)

        // 1. Rebuilt cleartext moov header from RAM.
        if cursor < headerLen {
            let upper = min(exclusiveEnd, headerLen)
            let slice = Data(map.header[Int(cursor)..<Int(upper)])
            guard await Self.sendData(slice, on: connection) else { return }
            cursor = upper
        }
        if cursor >= exclusiveEnd { return }

        // 2. Cached opening prefix (decrypted in memory).
        if let prefix,
           let stored = prefix.slice(map.inputOffset(forOutput: cursor)..<map.inputOffset(forOutput: exclusiveEnd)) {
            var bytes = [UInt8](stored)
            if (try? map.decrypt(&bytes, atInputOffset: map.inputOffset(forOutput: cursor))) != nil {
                guard await Self.sendData(Data(bytes), on: connection) else { return }
                cursor += Int64(bytes.count)
            }
        }
        if cursor >= exclusiveEnd { return }

        // 3. Stream remaining range from upstream in 512 KB windows, decrypting each window in place.
        let windowSize: Int64 = 524_288
        while cursor < exclusiveEnd {
            let chunkOutEnd = min(exclusiveEnd, cursor + windowSize)
            let inputStart = map.inputOffset(forOutput: cursor)
            let inputEnd = map.inputOffset(forOutput: chunkOutEnd) - 1
            var req = URLRequest(url: source)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue("bytes=\(inputStart)-\(inputEnd)", forHTTPHeaderField: "Range")
            guard let (rawData, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !rawData.isEmpty else {
                return
            }
            var bytes: [UInt8]
            if http.statusCode == 200 && inputStart > 0 {
                let startIdx = Int(min(Int64(rawData.count), inputStart))
                let endIdx = Int(min(Int64(rawData.count), inputEnd + 1))
                guard startIdx < endIdx else { return }
                bytes = [UInt8](rawData[startIdx..<endIdx])
            } else {
                bytes = [UInt8](rawData)
            }
            do {
                try map.decrypt(&bytes, atInputOffset: inputStart)
            } catch {
                return
            }
            guard await Self.sendData(Data(bytes), on: connection) else { return }
            cursor += Int64(bytes.count)
        }
    }

    // MARK: - Route 3: Plain Remote MP4 Proxy

    private func serveRemote(source: URL, headers: [String: String], knownLength: Int64?,
                             method: String, rangeHeader: String?, on connection: NWConnection) async {
        // Resolve total length if unknown via a 0-0 Range probe.
        var total = knownLength ?? 0
        if total <= 0 {
            var probe = URLRequest(url: source)
            for (k, v) in headers { probe.setValue(v, forHTTPHeaderField: k) }
            probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            if let (_, resp) = try? await session.data(for: probe), let http = resp as? HTTPURLResponse {
                if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let last = cr.split(separator: "/").last, let parsed = Int64(last) {
                    total = parsed
                } else if http.expectedContentLength > 0 {
                    total = http.expectedContentLength
                }
            }
        }
        guard total > 0, let range = Self.resolveRange(rangeHeader, total: total) else {
            await Self.sendRaw("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }
        let header = Self.responseHeaders(status: range.isPartial ? "206 Partial Content" : "200 OK",
                                          start: range.start, end: range.end, total: total,
                                          isPartial: range.isPartial)
        guard await Self.sendData(Data(header.utf8), on: connection) else { return }
        if method == "HEAD" { return }

        var cursor = range.start
        let exclusiveEnd = range.end + 1
        let windowSize: Int64 = 524_288
        while cursor < exclusiveEnd {
            let chunkEnd = min(exclusiveEnd - 1, cursor + windowSize - 1)
            var req = URLRequest(url: source)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue("bytes=\(cursor)-\(chunkEnd)", forHTTPHeaderField: "Range")
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !data.isEmpty else {
                return
            }
            guard await Self.sendData(data, on: connection) else { return }
            cursor += Int64(data.count)
        }
    }

    // MARK: - HTTP Helpers

    struct ByteRange {
        let start: Int64
        let end: Int64
        let isPartial: Bool
        var length: Int64 { end - start + 1 }
    }

    static func resolveRange(_ header: String?, total: Int64) -> ByteRange? {
        guard total > 0 else { return nil }
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.lowercased().hasPrefix("bytes=") else {
            return ByteRange(start: 0, end: total - 1, isPartial: false)
        }
        let spec = raw.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let start: Int64
        let end: Int64
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            start = max(0, total - suffix)
            end = total - 1
        } else {
            guard let s = Int64(parts[0]), s >= 0, s < total else { return nil }
            start = s
            if parts[1].isEmpty {
                end = total - 1
            } else if let e = Int64(parts[1]) {
                end = min(total - 1, e)
            } else {
                return nil
            }
        }
        guard start <= end else { return nil }
        return ByteRange(start: start, end: end, isPartial: true)
    }

    private static func responseHeaders(status: String, start: Int64, end: Int64, total: Int64, isPartial: Bool) -> String {
        var lines = [
            "HTTP/1.1 \(status)",
            "Content-Type: video/mp4",
            "Accept-Ranges: bytes",
            "Content-Length: \(end - start + 1)",
        ]
        if isPartial {
            lines.append("Content-Range: bytes \(start)-\(end)/\(total)")
        }
        lines.append("Connection: close")
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func parseHTTPRequest(_ raw: String) -> (method: String, path: String, rangeHeader: String?)? {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])
        var range: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                range = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
        }
        return (method, path, range)
    }

    private static func receiveRequestHeaders(on connection: NWConnection) async -> String? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.count < 16_384 {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if error != nil {
                        cont.resume(returning: nil)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(returning: Data())
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let range = buffer.range(of: terminator) {
                return String(data: buffer[..<range.upperBound], encoding: .utf8)
            }
        }
        return String(data: buffer, encoding: .utf8)
    }

    private static func sendRaw(_ text: String, on connection: NWConnection) async {
        _ = await sendData(Data(text.utf8), on: connection)
    }

    private static func sendData(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the device's active Wi-Fi IPv4 address (`en0` preferred, else any non-loopback `en*`).
    public static func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp, !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostBuffer)
                    if !ip.hasPrefix("169.254.") {
                        if name == "en0" { return ip }
                        if name.hasPrefix("en"), fallback == nil { fallback = ip }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return fallback
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        func markOnce() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if set { return false }
            set = true
            return true
        }
    }
}

import CryptoKit
import Foundation

public extension PlayInfo {
    /// Stable 12-hex-char media-version fingerprint derived from codec, immutable URL path
    /// (ignoring expiring query signatures), and encryption key material.
    var mediaVersionFingerprint: String {
        var hasher = SHA256()
        hasher.update(data: Data(codec.lowercased().utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(url.path.utf8))
        if let contentKey {
            hasher.update(data: Data("|k:".utf8))
            hasher.update(data: Data(contentKey))
        } else if let spadeA {
            hasher.update(data: Data("|s:".utf8))
            hasher.update(data: Data(spadeA.utf8))
        }
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// Encrypted episodes that cannot stream progressively are downloaded once, decrypted, and played
/// from a local file. Files live in Caches and the oldest are pruned beyond `maxFiles` / `maxBytes`.
public final class PlaybackCache: @unchecked Sendable {
    public static let shared = PlaybackCache()

    public let directory: URL
    private let http: HTTPClient
    private let maxFiles: Int
    /// Size cap in bytes (settings: 缓存上限); 0 = only the file count applies.
    private var maxBytes: Int64 = 0
    private var inflight: [String: Task<URL, Error>] = [:]
    private let lock = NSLock()

    public init(http: HTTPClient = .shared, maxFiles: Int = 12, directory: URL? = nil) {
        self.http = http
        self.maxFiles = maxFiles
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoDrama/playback", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    func fileURL(for info: PlayInfo) -> URL {
        let tier = info.quality.map { "-\($0.shortSide)" } ?? ""
        let converted = info.isByteVC2 ? "-h264" : ""
        let version = info.mediaVersionFingerprint
        return directory.appendingPathComponent("\(info.vid.filter(\.isNumber))\(tier)-\(version)\(converted).mp4")
    }

    public func cachedFile(for info: PlayInfo) -> URL? {
        let url = fileURL(for: info)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns a local playable file for an encrypted or ByteVC2 `PlayInfo` (decrypted, or
    /// converted to H.264). Concurrent calls for the same media version share one download.
    public func prepare(_ info: PlayInfo, progress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        guard info.needsLocalFile else { throw HongguoError(.input, "片源未加密，无需解密缓存") }
        if let url = cachedFile(for: info) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        let target = fileURL(for: info)
        let inflightKey = target.lastPathComponent
        let task: Task<URL, Error> = lock.withLock {
            if let existing = inflight[inflightKey] { return existing }
            let created = Task { () throws -> URL in
                defer { self.lock.withLock { self.inflight[inflightKey] = nil } }
                let key = info.contentKey ?? info.spadeA.flatMap(CencDecryptor.deriveKey)
                if info.isEncrypted, key == nil { throw HongguoError(.decrypt, "片源密钥无法解析") }
                var options = HTTPClient.Options()
                options.headers = info.httpHeaders
                options.timeout = 120
                options.maxBytes = 1024 * 1024 * 1024
                let candidates = PlayBackupURLs.shared.allCandidates(startingWith: info.url)
                var response: HTTPResponse?
                var lastError: Error?
                for candidate in candidates {
                    try Task.checkCancellation()
                    do {
                        response = try await self.http.get(candidate, options: options)
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }
                guard let response else {
                    throw lastError ?? HongguoError(.network, "片源下载失败")
                }
                try Task.checkCancellation()
                let partial = target.appendingPathExtension("part")
                if info.isByteVC2 {
                    let source = target.appendingPathExtension("src")
                    try response.data.write(to: source, options: [.atomic])
                    defer { try? FileManager.default.removeItem(at: source) }
                    progress?("正在进行 ByteVC2 兼容转换…")
                    try await ByteVC2Converter.shared.convert(input: source, output: partial, key: key) { seconds in
                        progress?("正在进行 ByteVC2 兼容转换… \(Int(seconds)) 秒")
                    }
                } else {
                    let plain = try CencDecryptor.decryptMP4(response.data, key: key!)
                    try plain.write(to: partial, options: [.atomic])
                }
                _ = try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: partial, to: target)
                self.prune()
                return target
            }
            inflight[inflightKey] = created
            return created
        }
        return try await task.value
    }

    /// Sets the size cap (0 = none) and removes the oldest files beyond it now.
    public func setLimit(bytes: Int64) {
        lock.withLock { maxBytes = max(0, bytes) }
        prune()
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func usageBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let sorted = files.filter { $0.pathExtension == "mp4" }.sorted { lhs, rhs in
            let a = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        let limit = lock.withLock { maxBytes }
        var kept: Int64 = 0
        for (offset, file) in sorted.enumerated() {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            // Always keep the newest file (the one playing), whatever its size.
            if offset >= maxFiles || (limit > 0 && offset > 0 && kept + size > limit) {
                try? FileManager.default.removeItem(at: file)
            } else {
                kept += size
            }
        }
    }
}

import Foundation

/// Encrypted episodes cannot be streamed straight into AVPlayer, so they are downloaded once,
/// decrypted, and played from a local file. Files live in the user's Caches folder and the
/// oldest are pruned beyond `maxFiles`.
public final class PlaybackCache: @unchecked Sendable {
    public static let shared = PlaybackCache()

    public let directory: URL
    private let http: HTTPClient
    private let maxFiles: Int
    private var inflight: [String: Task<URL, Error>] = [:]
    private let lock = NSLock()

    public init(http: HTTPClient = .shared, maxFiles: Int = 12) {
        self.http = http
        self.maxFiles = maxFiles
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoDrama/playback", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    func fileURL(for info: PlayInfo) -> URL {
        directory.appendingPathComponent("\(info.vid.filter(\.isNumber)).mp4")
    }

    public func cachedFile(for info: PlayInfo) -> URL? {
        let url = fileURL(for: info)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns a local decrypted file for an encrypted `PlayInfo`. Concurrent calls share one download.
    public func prepare(_ info: PlayInfo) async throws -> URL {
        guard info.isEncrypted else { throw HongguoError(.input, "片源未加密，无需解密缓存") }
        if let url = cachedFile(for: info) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        let task: Task<URL, Error> = lock.withLock {
            if let existing = inflight[info.vid] { return existing }
            let created = Task { () throws -> URL in
                defer { self.lock.withLock { self.inflight[info.vid] = nil } }
                guard let key = info.contentKey ?? info.spadeA.flatMap(CencDecryptor.deriveKey) else {
                    throw HongguoError(.decrypt, "片源密钥无法解析")
                }
                var options = HTTPClient.Options()
                options.headers = info.httpHeaders
                options.timeout = 120
                options.maxBytes = 1024 * 1024 * 1024
                let response = try await self.http.get(info.url, options: options)
                try Task.checkCancellation()
                let plain = try CencDecryptor.decryptMP4(response.data, key: key)
                let target = self.fileURL(for: info)
                let partial = target.appendingPathExtension("part")
                try plain.write(to: partial, options: [.atomic])
                _ = try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: partial, to: target)
                self.prune()
                return target
            }
            inflight[info.vid] = created
            return created
        }
        return try await task.value
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
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let sorted = files.filter { $0.pathExtension == "mp4" }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(maxFiles) { try? FileManager.default.removeItem(at: file) }
    }
}

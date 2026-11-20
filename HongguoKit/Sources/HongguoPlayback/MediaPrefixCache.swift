import Foundation
import HongguoCore

/// The first few megabytes of upcoming episodes, kept on disk as they come from the server
/// (still encrypted). Unified format (`<key>@0+<totalLength>.bin`) stores byte 0 onward so both
/// `moov` header parsing (`FastCencOpener.openFromCachedPrefix`) and opening media playback
/// (`StreamingResourceLoader`) read from the same file with zero network RTT and zero redundant
/// download. Cache keys include a stable media-version fingerprint (`codec` + URL path + content
/// key digest, ignoring expiring query signatures) so renewed URLs reuse cached bytes while
/// re-encoded or codec-switched streams never collide.
///
/// Files live in Caches, are capped in total size and the least recently used go first.
public final class MediaPrefixCache: @unchecked Sendable {
    public static let shared = MediaPrefixCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("media-prefix"))

    /// How much of each episode is fetched ahead: what the official app takes by default.
    public static let prefixBytes = 5 * 1024 * 1024

    /// A stored run of input bytes: `data` holds the bytes from `start` on.
    public struct Prefix: Sendable {
        public let start: Int64
        public let data: Data
        /// True when read from the disk prefix cache; false for in-memory opening bytes fetched alongside `moov`.
        public let fromDisk: Bool
        public var end: Int64 { start + Int64(data.count) }

        public init(start: Int64, data: Data, fromDisk: Bool = true) {
            self.start = start
            self.data = data
            self.fromDisk = fromDisk
        }

        /// The stored bytes of `range`, from its lower bound, as far as they go.
        public func slice(_ range: Range<Int64>) -> Data? {
            guard range.lowerBound >= start, range.lowerBound < end else { return nil }
            let from = Int(range.lowerBound - start)
            let to = Int(min(range.upperBound, end) - start)
            return data.subdata(in: (data.startIndex + from)..<(data.startIndex + to))
        }
    }

    private let directory: URL
    private let limitBytes: Int64
    private let lock = NSLock()
    private var served: Int64 = 0

    /// Bytes handed to the player from disk since the last call, for the playback log.
    public func takeServedBytes() -> Int64 {
        lock.withLock { let value = served; served = 0; return value }
    }

    func noteServed(_ count: Int) {
        lock.withLock { served += Int64(count) }
    }
    private var inflight: Set<String> = []

    public init(directory: URL, limitBytes: Int64 = 400 * 1024 * 1024) {
        self.directory = directory
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Legacy key format kept for backward-compatible tests.
    public static func key(vid: String, shortSide: Int?) -> String { "\(vid)-\(shortSide ?? 0)" }

    /// Collision-proof media-version key shared with `PlaybackCache`: combines `vid`, `shortSide`,
    /// and `PlayInfo.mediaVersionFingerprint` (`codec` + URL path + encryption key material).
    public static func key(for info: PlayInfo) -> String {
        "\(info.vid)-\(info.quality?.shortSide ?? 0)-\(info.mediaVersionFingerprint)"
    }

    private func file(_ key: String, start: Int64) -> URL { directory.appendingPathComponent("\(key)@\(start).bin") }
    private func unifiedFile(_ key: String, totalLength: Int64) -> URL { directory.appendingPathComponent("\(key)@0+\(totalLength).bin") }

    /// Parses `<key>@0+<totalLength>.bin` or legacy `<key>@<start>.bin`.
    private static func parseFilename(_ name: String, key: String) -> (start: Int64, totalLength: Int64?)? {
        guard name.hasPrefix("\(key)@"), name.hasSuffix(".bin") else { return nil }
        let stem = String(name.dropFirst(key.count + 1).dropLast(4))
        if let plus = stem.firstIndex(of: "+") {
            let startPart = stem[..<plus]
            let totalPart = stem[stem.index(after: plus)...]
            guard let start = Int64(startPart), let total = Int64(totalPart), start == 0, total > 0 else { return nil }
            return (0, total)
        }
        guard let start = Int64(stem) else { return nil }
        return (start, nil)
    }

    /// The stored opening of an episode, if any. Reading it marks it as recently used.
    public func load(key: String) -> Prefix? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        // Prefer unified `0+<total>` file over legacy `@<start>` file if both exist.
        let candidates = names.compactMap { name -> (String, Int64, Int64?)? in
            guard let parsed = Self.parseFilename(name, key: key) else { return nil }
            return (name, parsed.start, parsed.totalLength)
        }.sorted { ($0.2 != nil ? 0 : 1) < ($1.2 != nil ? 0 : 1) }
        guard let best = candidates.first else { return nil }
        let url = directory.appendingPathComponent(best.0)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return Prefix(start: best.1, data: data)
    }

    /// Loads a unified `[0 ..< N]` cached prefix along with total file length so `FastCencOpener`
    /// can rebuild `CencStreamMap` locally with zero network RTT.
    public func loadRawHeader(key: String) -> (data: Data, totalLength: Int64)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names {
            guard let parsed = Self.parseFilename(name, key: key), parsed.start == 0, let total = parsed.totalLength else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { continue }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return (data, total)
        }
        return nil
    }

    public func contains(key: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).contains { Self.parseFilename($0, key: key) != nil }
    }

    /// Lightweight metadata check returning the exclusive end offset of any cached prefix file
    /// without opening its contents or modifying its mtime.
    func cachedEndOffset(key: String) -> Int64? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var bestEnd: Int64?
        for name in names {
            guard let parsed = Self.parseFilename(name, key: key) else { continue }
            let path = directory.appendingPathComponent(name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else { continue }
            let end = parsed.start + size
            if bestEnd == nil || end > bestEnd! { bestEnd = end }
        }
        return bestEnd
    }

    /// Validates an HTTP 206 Range response before appending its bytes to a disk prefix file,
    /// ensuring start offset, total file length, inclusive end, and actual byte count all match.
    public static func validatePrefetchRangeResponse(
        statusCode: Int,
        contentRange: String?,
        expectedStart: Int64,
        expectedTotal: Int64,
        expectedMaxEnd: Int64,
        dataCount: Int
    ) -> Bool {
        guard statusCode == 206, dataCount > 0, let contentRange else { return false }
        let trimmed = contentRange.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return false }
        let spec = trimmed.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let total = Int64(parts[1]), total == expectedTotal else { return false }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let rangeStart = Int64(bounds[0]),
              let rangeEnd = Int64(bounds[1]),
              rangeStart == expectedStart,
              rangeEnd >= rangeStart,
              rangeEnd <= expectedMaxEnd,
              rangeEnd < expectedTotal else { return false }
        return Int64(dataCount) == (rangeEnd - rangeStart + 1)
    }

    public func store(key: String, start: Int64, data: Data) {
        guard !data.isEmpty else { return }
        try? data.write(to: file(key, start: start), options: [.atomic])
        trim()
    }

    /// Stores a unified `[0 ..< N]` raw encrypted prefix with its known total length, replacing
    /// any older file for the same key.
    public func storeUnified(key: String, totalLength: Int64, data: Data) {
        guard !data.isEmpty, totalLength > 0 else { return }
        let destination = unifiedFile(key, totalLength: totalLength)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where Self.parseFilename(name, key: key) != nil && name != destination.lastPathComponent {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        try? data.write(to: destination, options: [.atomic])
        trim()
    }

    /// Removes the least recently used files until the total fits the limit.
    public func trim() {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = urls.compactMap { url -> (URL, Date, Int64)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        entries.sort { $0.1 < $1.1 }
        while total > limitBytes, let oldest = entries.first {
            try? manager.removeItem(at: oldest.0)
            total -= oldest.2
            entries.removeFirst()
        }
    }

    private func claim(_ key: String) -> Bool {
        lock.withLock {
            guard !inflight.contains(key) else { return false }
            if let existing = loadRawHeader(key: key),
               existing.data.count >= min(Int(existing.totalLength), Self.prefixBytes) {
                return false
            }
            if contains(key: key), loadRawHeader(key: key) == nil {
                return false
            }
            inflight.insert(key)
            return true
        }
    }

    private func release(_ key: String) {
        lock.withLock { _ = inflight.remove(key) }
    }

    /// Downloads the unified `[0 ..< min(total, 5 MiB)]` opening of a prepared, encrypted episode.
    /// Continues directly after `prepared.rawPrefixData` so bytes fetched by `FastCencOpener`
    /// (`moov` + opening `mdat`) are never downloaded twice, and `moov` is persisted for 0 ms
    /// header opening on future starts.
    public func prefetch(_ prepared: PreparedEpisode) async {
        guard let map = prepared.map, map.inputLength > 0 else { return }
        let info = prepared.info
        let key = Self.key(for: info)
        guard claim(key) else { return }
        defer { release(key) }

        let targetLength = min(map.inputLength, Int64(Self.prefixBytes))
        let existing = prepared.rawPrefixData ?? loadRawHeader(key: key)?.data ?? Data()
        let start = Int64(existing.count)
        if start >= targetLength {
            storeUnified(key: key, totalLength: map.inputLength, data: existing)
            return
        }
        let end = targetLength - 1
        var options = HTTPClient.Options()
        options.headers = info.httpHeaders.merging(["Range": "bytes=\(start)-\(end)"]) { _, new in new }
        options.timeout = 20
        options.maxBytes = Int(targetLength - start) + 64 * 1024
        options.acceptStatus = 206...206

        let candidates = prepared.mediaURLs.isEmpty
            ? PlayBackupURLs.shared.allCandidates(startingWith: info.url)
            : prepared.mediaURLs
        for url in candidates {
            guard !Task.isCancelled else { return }
            if let response = try? await HTTPClient.shared.get(url, options: options), !Task.isCancelled {
                guard Self.validatePrefetchRangeResponse(
                    statusCode: response.status,
                    contentRange: response.header("Content-Range"),
                    expectedStart: start,
                    expectedTotal: map.inputLength,
                    expectedMaxEnd: end,
                    dataCount: response.data.count
                ) else { continue }
                var combined = existing
                combined.append(response.data)
                storeUnified(key: key, totalLength: map.inputLength, data: combined)
                return
            }
        }
    }
}

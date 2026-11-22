#if canImport(UIKit)
import AppLogic
import SwiftUI
import UIKit

/// Two-tier (L1 `NSCache` + L2 disk) cover image loader with normalized cache keys
/// (ignoring rotating CDN signature parameters), in-flight deduplication, off-main
/// HEIC/JPEG decoding (`byPreparingForDisplay`), and bounded batch prefetching.
public final class CoverImageCache: @unchecked Sendable {
    public static let shared = CoverImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let diskDirectory: URL
    private let coordinator = LoadCoordinator()
    private let maxDiskBytes: Int64 = 120 * 1024 * 1024

    private init() {
        memory.countLimit = 240
        memory.totalCostLimit = 80 * 1024 * 1024

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 12
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        session = URLSession(configuration: config)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        diskDirectory = caches.appendingPathComponent("CoverImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    public static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        else if text.lowercased().hasPrefix("http://") { text = "https://" + text.dropFirst(7) }
        guard let parsed = URL(string: text), parsed.scheme?.lowercased() == "https" else { return nil }
        return parsed
    }

    /// Synchronous L1 memory lookup so scrolling cells back into view render on frame 0
    /// without flashing a placeholder.
    public func memoryImage(for urlString: String) -> UIImage? {
        guard let parsed = Self.normalizedURL(urlString) else { return nil }
        let key = CoverCacheKey.normalizedKey(for: parsed.absoluteString)
        return memory.object(forKey: key as NSString)
    }

    /// Loads an image from memory, disk, or network (deduplicated per normalized image key).
    public func load(_ urlString: String) async -> UIImage? {
        guard let parsed = Self.normalizedURL(urlString) else {
            return nil
        }
        let key = CoverCacheKey.normalizedKey(for: parsed.absoluteString)
        if let hit = memory.object(forKey: key as NSString) {
            return hit
        }
        let task = await coordinator.task(for: key) { [self] in
            await self.fetchAndDecode(url: parsed, urlString: parsed.absoluteString, normalizedKey: key)
        }
        return await task.value
    }

    /// Warms up to `maxCount` upcoming covers at `.utility` priority with bounded concurrency
    /// so scrolling into grids feels instant without competing with video streams.
    public func prefetch(_ urls: [String], maxCount: Int = 18) {
        var unique: [String] = []
        var seen = Set<String>()
        for raw in urls {
            guard let parsed = Self.normalizedURL(raw) else { continue }
            let normalized = parsed.absoluteString
            let key = CoverCacheKey.normalizedKey(for: normalized)
            guard seen.insert(key).inserted else { continue }
            if memory.object(forKey: key as NSString) != nil { continue }
            unique.append(normalized)
            if unique.count >= maxCount { break }
        }
        guard !unique.isEmpty else { return }
        Task.detached(priority: .utility) { [self] in
            await withTaskGroup(of: Void.self) { group in
                let maxConcurrent = 6
                var iterator = unique.makeIterator()
                for _ in 0..<min(maxConcurrent, unique.count) {
                    if let next = iterator.next() {
                        group.addTask { _ = await self.load(next) }
                    }
                }
                while await group.next() != nil {
                    if let next = iterator.next() {
                        group.addTask { _ = await self.load(next) }
                    }
                }
            }
        }
    }

    private func fetchAndDecode(url: URL, urlString: String, normalizedKey: String) async -> UIImage? {
        let filename = CoverCacheKey.diskFilename(for: urlString)
        let fileURL = diskDirectory.appendingPathComponent(filename, isDirectory: false)

        // L2 disk hit — touch mtime so trimDiskCache evicts by LRU instead of FIFO.
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty,
           let decoded = await Self.decodeForDisplay(data) {
            var mutableURL = fileURL
            var values = URLResourceValues()
            values.contentModificationDate = Date()
            try? mutableURL.setResourceValues(values)
            storeInMemory(decoded, key: normalizedKey)
            return decoded
        }

        // Network fetch
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              let decoded = await Self.decodeForDisplay(data) else {
            return nil
        }

        storeInMemory(decoded, key: normalizedKey)
        try? data.write(to: fileURL, options: .atomic)
        let shouldTrim = await coordinator.recordDiskWrite()
        if shouldTrim {
            Task.detached(priority: .background) { [diskDirectory, maxDiskBytes] in
                Self.trimDiskCache(directory: diskDirectory, maxBytes: maxDiskBytes)
            }
        }
        return decoded
    }

    private func storeInMemory(_ image: UIImage, key: String) {
        let cost = Self.bitmapCost(image)
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    private static func decodeForDisplay(_ data: Data) async -> UIImage? {
        guard let raw = UIImage(data: data) else { return nil }
        return await raw.byPreparingForDisplay() ?? raw
    }

    private static func bitmapCost(_ image: UIImage) -> Int {
        if let cg = image.cgImage { return max(1, cg.bytesPerRow * cg.height) }
        let pxW = Int(image.size.width * image.scale)
        let pxH = Int(image.size.height * image.scale)
        return max(1, pxW * pxH * 4)
    }

    private static func trimDiskCache(directory: URL, maxBytes: Int64) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        var entries: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0
        for url in urls {
            guard let vals = try? url.resourceValues(forKeys: keys), vals.isRegularFile == true else { continue }
            let size = Int64(vals.fileSize ?? 0)
            total += size
            entries.append((url, vals.contentModificationDate ?? .distantPast, size))
        }
        guard total > maxBytes else { return }
        let target = Int64(Double(maxBytes) * 0.75)
        entries.sort { $0.date < $1.date }
        for entry in entries where total > target {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private actor LoadCoordinator {
        private var inflight: [String: Task<UIImage?, Never>] = [:]
        private var writesSinceTrim = 0

        func task(for key: String, start: @escaping @Sendable () async -> UIImage?) -> Task<UIImage?, Never> {
            if let existing = inflight[key] { return existing }
            let created = Task.detached(priority: .userInitiated) {
                let image = await start()
                await self.clear(key: key)
                return image
            }
            inflight[key] = created
            return created
        }

        private func clear(key: String) {
            inflight[key] = nil
        }

        func recordDiskWrite() -> Bool {
            writesSinceTrim += 1
            if writesSinceTrim >= 40 {
                writesSinceTrim = 0
                return true
            }
            return false
        }
    }
}

/// A cached cover image from an https URL, or a neutral placeholder (offline sample rows have no cover).
public struct CoverImage: View {
    public init(url: String, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    public let url: String
    public var contentMode: ContentMode = .fill

    @State private var loaded: UIImage?
    @State private var loadedURL = ""

    public var body: some View {
        let current = (loadedURL == url ? loaded : nil) ?? CoverImageCache.shared.memoryImage(for: url)
        Color.clear.overlay {
            if let image = current {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .clipped()
        .task(id: url) {
            guard !url.isEmpty else { return }
            if let hit = CoverImageCache.shared.memoryImage(for: url) {
                loaded = hit
                loadedURL = url
                return
            }
            let image = await CoverImageCache.shared.load(url)
            guard !Task.isCancelled else { return }
            if let image {
                loaded = image
                loadedURL = url
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
    }
}
#endif

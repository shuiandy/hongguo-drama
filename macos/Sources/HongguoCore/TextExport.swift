import Foundation

/// Saves danmaku, episode comments and series reviews as JSON files next to downloaded videos
/// (port of src/native/text-export.js). `<video>.danmaku.json` and `<video>.comments.json` sit
/// beside each `.mp4`; reviews go to a file the caller chooses. A complete earlier file is kept;
/// a partial one is fetched again and only replaced when the new fetch succeeds. A file that
/// changes while fetching is never overwritten.
public enum TextExport {
    public struct Kinds: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let danmaku = Kinds(rawValue: 1)
        public static let comments = Kinds(rawValue: 2)
        public static let reviews = Kinds(rawValue: 4)
    }

    public struct Tally: Equatable, Sendable {
        public var ok = 0, fail = 0, skipped = 0, partial = 0, items = 0, empty = 0, unavailable = 0
    }

    public struct Summary: Equatable, Sendable {
        public var danmaku = Tally(), comments = Tally(), reviews = Tally()
        public var files: [URL] = []
    }

    /// One downloaded episode.
    public struct Target: Equatable, Sendable {
        public var vid: String
        public var episodeIndex: Int
        public var videoFile: URL
        public init(vid: String, episodeIndex: Int, videoFile: URL) {
            self.vid = vid; self.episodeIndex = episodeIndex; self.videoFile = videoFile
        }
    }

    public struct Fetchers: Sendable {
        public var danmaku: @Sendable (_ seriesId: String, _ vid: String, _ fresh: Bool) async -> DanmakuResult
        public var comments: @Sendable (_ seriesId: String, _ vid: String) async throws -> EpisodeComments
        public var details: @Sendable (_ seriesId: String) async throws -> PublicDetails

        public init(danmaku: @escaping @Sendable (String, String, Bool) async -> DanmakuResult,
                    comments: @escaping @Sendable (String, String) async throws -> EpisodeComments,
                    details: @escaping @Sendable (String) async throws -> PublicDetails) {
            self.danmaku = danmaku; self.comments = comments; self.details = details
        }

        public static func live(danmaku: DanmakuService, comments: EpisodeCommentService = EpisodeCommentService(),
                                series: SeriesService = SeriesService()) -> Fetchers {
            Fetchers(danmaku: { await danmaku.fetch(seriesId: $0, vid: $1, fresh: $2) },
                     comments: { try await comments.comments(seriesId: $0, vid: $1) },
                     details: { try await series.publicDetails(seriesId: $0) })
        }
    }

    /// Completed downloads of one series whose video is still on disk.
    public static func targets(seriesId: String, tasks: [DownloadTask]) -> [Target] {
        tasks.filter { $0.seriesId == seriesId && $0.status == .completed && FileManager.default.fileExists(atPath: $0.savePath) }
            .sorted { $0.episodeIndex < $1.episodeIndex }
            .map { Target(vid: $0.vid, episodeIndex: $0.episodeIndex, videoFile: $0.fileURL) }
    }

    /// `<stem>.danmaku.json` / `<stem>.comments.json` for an `.mp4`; nil for anything else.
    static func sidecar(_ video: URL, _ suffix: String) -> URL? {
        guard video.path.hasPrefix("/"), video.pathExtension.lowercased() == "mp4" else { return nil }
        return video.deletingPathExtension().appendingPathExtension(suffix).appendingPathExtension("json")
    }

    public static func export(seriesId: String, seriesTitle: String, targets: [Target], kinds: Kinds,
                              reviewsFile: URL? = nil, reviewsLimit: Int = 1000, concurrency: Int = 4,
                              fetchers: Fetchers, now: @escaping @Sendable () -> Date = { Date() }) async -> Summary {
        var out = Summary()
        guard !kinds.isEmpty else { return out }
        guard seriesId.matchesDigits(min: 6, max: 30) else {
            if kinds.contains(.danmaku) { out.danmaku.skipped = targets.count }
            if kinds.contains(.comments) { out.comments.skipped = targets.count }
            if kinds.contains(.reviews) { out.reviews.skipped = 1 }
            return out
        }
        func record(_ kind: WritableKeyPath<Summary, Tally>, _ result: WriteResult) {
            switch result.status {
            case .ok: out[keyPath: kind].ok += 1
            case .fail: out[keyPath: kind].fail += 1
            case .skipped: out[keyPath: kind].skipped += 1
            case .unavailable: out[keyPath: kind].unavailable += 1
            }
            if let count = result.itemCount {
                out[keyPath: kind].items += count
                if count == 0 { out[keyPath: kind].empty += 1 }
            }
            if result.status == .ok, let file = result.file {
                if result.partial { out[keyPath: kind].partial += 1 }
                if !out.files.contains(file) { out.files.append(file) }
            }
        }

        if kinds.contains(.reviews) {
            record(\.reviews, await writeOne(reviewsFile) { _ in
                guard let details = try? await fetchers.details(seriesId) else { return .failed }
                let items = details.reviews.prefix(reviewsLimit)
                let partial = (details.reviewTotal ?? 0) > items.count
                let doc: [String: Any] = [
                    "kind": "reviews", "series_id": seriesId, "series_title": seriesTitle, "fetched_at": millis(now()),
                    "total": details.reviewTotal.map { $0 as Any } ?? NSNull(), "partial": partial,
                    "items": items.map { review -> [String: Any] in
                        ["author": review.author, "avatar": review.avatar, "content": review.content,
                         "created_at": review.createdAt.map { millis($0) as Any } ?? NSNull(),
                         "likes": review.likes.map { $0 as Any } ?? NSNull(), "rating": review.rating.map { $0 as Any } ?? NSNull()]
                    }]
                return .document(doc, partial: partial, items: items.count)
            })
        }

        guard kinds.contains(.danmaku) || kinds.contains(.comments), !targets.isEmpty else { return out }
        let results = await withTaskGroup(of: (Int, WriteResult?, WriteResult?).self) { group in
            var iterator = targets.enumerated().makeIterator()
            func add(_ next: (offset: Int, element: Target)) {
                group.addTask {
                    let target = next.element
                    var danmaku: WriteResult?, comments: WriteResult?
                    if kinds.contains(.danmaku) {
                        danmaku = await writeOne(sidecar(target.videoFile, "danmaku")) { fresh in
                            let data = await fetchers.danmaku(seriesId, target.vid, fresh)
                            // A failed retry keeps the earlier partial file, even if it returned some items.
                            guard data.success || (!fresh && data.partial) else { return .failed }
                            let partial = data.partial || data.truncated
                            let doc: [String: Any] = [
                                "kind": "danmaku", "series_id": seriesId, "episode_id": target.vid,
                                "episode_index": target.episodeIndex, "series_title": seriesTitle, "source": "official",
                                "fetched_at": millis(now()), "truncated": data.truncated, "partial": partial, "notice": data.notice,
                                "items": data.items.map { ["time": $0.time, "text": $0.text, "color": $0.color, "mode": $0.mode.rawValue] as [String: Any] }]
                            return .document(doc, partial: partial, items: data.items.count)
                        }
                    }
                    if kinds.contains(.comments) {
                        comments = await writeOne(sidecar(target.videoFile, "comments")) { _ in
                            let data: EpisodeComments
                            do { data = try await fetchers.comments(seriesId, target.vid) } catch let error as HongguoError where error.kind == .unavailable {
                                return .unavailable
                            } catch { return .failed }
                            // The website only shows a preview, so comments always count as partial (as in Electron).
                            let doc: [String: Any] = [
                                "kind": "comments", "series_id": seriesId, "episode_id": target.vid,
                                "episode_index": target.episodeIndex, "series_title": seriesTitle, "fetched_at": millis(now()),
                                "total": data.total.map { $0 as Any } ?? NSNull(), "source_limited": true, "partial": true,
                                "notice": data.notice, "items": data.items.map { ["id": $0.id, "content": $0.content] }]
                            return .document(doc, partial: true, items: data.items.count)
                        }
                    }
                    return (next.offset, danmaku, comments)
                }
            }
            for _ in 0..<max(1, min(concurrency, targets.count)) { if let next = iterator.next() { add(next) } }
            var collected: [(Int, WriteResult?, WriteResult?)] = []
            while let result = await group.next() {
                collected.append(result)
                if let next = iterator.next() { add(next) }
            }
            return collected.sorted { $0.0 < $1.0 }
        }
        for (_, danmaku, comments) in results {
            if let danmaku { record(\.danmaku, danmaku) }
            if let comments { record(\.comments, comments) }
        }
        return out
    }

    // MARK: Writing

    enum Fetched {
        case document([String: Any], partial: Bool, items: Int)
        case failed
        case unavailable
    }

    struct WriteResult: Sendable {
        enum Status: Sendable { case ok, fail, skipped, unavailable }
        var status: Status
        var partial = false
        var itemCount: Int?
        var file: URL?
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Identity of the file at `url` (nil when missing); a change means someone else wrote it.
    struct Stamp: Equatable {
        var exists: Bool
        var inode: UInt64? = nil, size: UInt64? = nil, modified: Date? = nil
        var regular: Bool
    }

    static func stamp(_ url: URL) -> Stamp {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return Stamp(exists: FileManager.default.fileExists(atPath: url.path), regular: false)
        }
        return Stamp(exists: true, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                     size: (attributes[.size] as? NSNumber)?.uint64Value, modified: attributes[.modificationDate] as? Date,
                     regular: attributes[.type] as? FileAttributeType == .typeRegular)
    }

    static func writeOne(_ target: URL?, fetch: @Sendable (_ retry: Bool) async -> Fetched) async -> WriteResult {
        guard let target = target?.standardizedFileURL, target.path.hasPrefix("/") else { return WriteResult(status: .fail) }
        var retry = false
        let initial = stamp(target)
        if initial.exists {
            // A complete earlier export stays; a partial one is fetched again.
            guard initial.regular, let data = try? Data(contentsOf: target),
                  let previous = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return WriteResult(status: .fail) }
            if previous["partial"] as? Bool != true {
                return WriteResult(status: .skipped, itemCount: (previous["items"] as? [Any])?.count)
            }
            retry = true
        }
        switch await fetch(retry) {
        case .failed: return WriteResult(status: .fail)
        case .unavailable: return WriteResult(status: .unavailable)
        case let .document(doc, partial, items):
            do {
                try writeAtomically(doc, to: target, expecting: initial)
                return WriteResult(status: .ok, partial: partial, itemCount: items, file: target)
            } catch { return WriteResult(status: .fail) }
        }
    }

    static func writeAtomically(_ doc: [String: Any], to target: URL, expecting initial: Stamp) throws {
        let changed = HongguoError(.input, "导出目标已变化，未覆盖")
        guard stamp(target) == initial else { throw changed }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        // A random temporary name, created exclusively, so a planted link is never followed.
        let temporary = directory.appendingPathComponent(".hg-json-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HongguoError(.input, "无法写入导出文件")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard stamp(target) == initial else { throw changed }
            guard rename(temporary.path, target.path) == 0 else { throw HongguoError(.input, "无法写入导出文件") }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

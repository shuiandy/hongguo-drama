import AVFoundation
import Foundation

/// 合并导出 (port of the Electron "一键合并"): joins the downloaded episodes of one series, in
/// episode order, into a single MP4 with AVFoundation, so no FFmpeg is needed.
/// `.fast` copies the streams (no quality loss, seconds); `.compatible` re-encodes to H.264 for
/// players without HEVC. When a fast merge is refused because the episodes differ in format, it
/// retries as compatible.
public actor MergeExporter {
    public static let shared = MergeExporter()

    public enum Mode: String, Sendable, CaseIterable { case fast, compatible }

    public struct Job: Identifiable, Equatable, Sendable {
        public enum Status: Equatable, Sendable { case running, completed, failed(String), cancelled }
        public var id: String { seriesId }
        public var seriesId: String
        public var seriesTitle: String
        public var episodes: Int
        public var progress: Double
        public var status: Status
        public var output: URL?
        public var mode: Mode
    }

    public private(set) var jobs: [String: Job] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]

    public func updates() -> AsyncStream<[Job]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Job]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(Array(jobs.values))
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func changed() { for continuation in observers.values { continuation.yield(Array(jobs.values)) } }

    /// Output path next to the episodes: `<剧名> 全集.mp4` (or `全N集` when not complete), never
    /// overwriting an existing file.
    public static func outputURL(directory: URL, seriesTitle: String, count: Int, total: Int?) -> URL {
        let clean = DownloadNaming.sanitizeFolderName(seriesTitle).isEmpty ? "红果短剧" : DownloadNaming.sanitizeFolderName(seriesTitle)
        let label = (total.map { $0 == count } ?? false) ? "全集" : "合并\(count)集"
        var url = directory.appendingPathComponent("\(clean) \(label).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(clean) \(label) (\(n)).mp4")
            n += 1
        }
        return url
    }

    /// Starts merging `files` (episode index -> file). Refused while the same series is merging.
    public func start(seriesId: String, seriesTitle: String, files: [Int: URL], total: Int?, mode: Mode) throws -> URL {
        guard running[seriesId] == nil else { throw HongguoError(.input, "这部剧正在合并，请等待完成") }
        let ordered = files.sorted { $0.key < $1.key }.map(\.value)
        guard ordered.count >= 2 else { throw HongguoError(.input, "至少需要已下载 2 集才能合并") }
        let output = Self.outputURL(directory: ordered[0].deletingLastPathComponent(), seriesTitle: seriesTitle,
                                    count: ordered.count, total: total)
        jobs[seriesId] = Job(seriesId: seriesId, seriesTitle: seriesTitle, episodes: ordered.count, progress: 0,
                             status: .running, output: output, mode: mode)
        changed()
        running[seriesId] = Task {
            do {
                try await Self.merge(ordered, to: output, mode: mode) { value in
                    Task { await self.report(seriesId, progress: value) }
                }
                self.finish(seriesId, .completed)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
                self.finish(seriesId, .cancelled)
            } catch {
                try? FileManager.default.removeItem(at: output)
                self.finish(seriesId, .failed((error as? HongguoError)?.message ?? "合并失败：\(error.localizedDescription)"))
            }
        }
        return output
    }

    public func cancel(_ seriesId: String) { running[seriesId]?.cancel() }

    public func dismiss(_ seriesId: String) {
        guard running[seriesId] == nil else { return }
        jobs[seriesId] = nil
        changed()
    }

    private func report(_ seriesId: String, progress: Double) {
        guard jobs[seriesId]?.status == .running else { return }
        jobs[seriesId]?.progress = progress
        changed()
    }

    private func finish(_ seriesId: String, _ status: Job.Status) {
        running[seriesId] = nil
        jobs[seriesId]?.status = status
        if status == .completed { jobs[seriesId]?.progress = 1 }
        changed()
    }

    // MARK: AVFoundation

    static func merge(_ files: [URL], to output: URL, mode: Mode, progress: @escaping @Sendable (Double) -> Void) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw HongguoError(.format, "无法创建合并视频轨")
        }
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var transform: CGAffineTransform?
        for file in files {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0, let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw HongguoError(.format, "《\(file.lastPathComponent)》不是完整的视频文件，请重新下载这一集")
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(range, of: video, at: cursor)
            if transform == nil { transform = try await video.load(.preferredTransform) }
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audioTrack?.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = cursor + duration
        }
        if let transform { videoTrack.preferredTransform = transform }

        let attempts: [String] = mode == .fast ? [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
                                               : [AVAssetExportPresetHighestQuality]
        var lastError: Error = HongguoError(.format, "合并失败")
        for preset in attempts {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: output)
            guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            session.outputURL = output
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            let poller = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            await withTaskCancellationHandler {
                await session.export()
            } onCancel: {
                session.cancelExport()
            }
            poller.cancel()
            try Task.checkCancellation()
            switch session.status {
            case .completed:
                return
            case .cancelled:
                throw CancellationError()
            default:
                lastError = session.error.map { HongguoError(.format, "合并失败：\($0.localizedDescription)") }
                    ?? HongguoError(.format, "合并失败")
            }
        }
        throw lastError
    }
}

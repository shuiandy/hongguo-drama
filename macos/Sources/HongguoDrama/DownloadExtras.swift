import AppKit
import HongguoCore

/// 整剧资料 and 下载到 NAS (ports of the metadata and NAS parts of the Electron download flow).
extension AppModel {
    /// Cover, intro and tvshow.nfo next to a series' downloads. Failures never block the download.
    nonisolated static func saveSeriesMetadata(seriesId: String, title: String, cover: String, into directory: URL) async {
        let details = try? await SourceRouter.series.publicDetails(seriesId: seriesId)
        let series = SeriesMetadata.Series(seriesId: seriesId, title: title, description: details?.description ?? "",
                                           cover: cover.isEmpty ? (details?.cover ?? "") : cover)
        _ = try? await SeriesMetadata.writeSeries(series, into: directory)
    }

    /// 下载到 NAS: asks for a mounted share folder, writes the series files and episode NFOs,
    /// copies episodes that are already downloaded, and queues the rest straight into the share.
    /// Returns a status line, or nil when the user cancelled the folder panel.
    func downloadToNAS(_ list: SeriesEpisodes, cover: String) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "保存到此目录"
        panel.message = settings.nasCreateFolder ? "选择 NAS 保存位置，将自动创建剧名文件夹" : "选择已挂载的 NAS 共享文件夹（直接存入所选文件夹）"
        if let last = settings.nasRoot, FileManager.default.fileExists(atPath: last) { panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true) }
        else { panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true) }
        guard panel.runModal() == .OK, let root = panel.url else { return nil }
        settings.nasRoot = root.path

        let layout = NASLayout(root: root, seriesTitle: list.title, createFolder: settings.nasCreateFolder)
        let wanted = list.episodes.filter { $0.locked != true }
        let locked = list.episodes.count - wanted.count
        var warnings: [String] = []
        do {
            let details = try? await series.publicDetails(seriesId: list.seriesId)
            let meta = SeriesMetadata.Series(seriesId: list.seriesId, title: list.title, description: details?.description ?? "",
                                             cover: cover.isEmpty ? (details?.cover ?? "") : cover)
            warnings += try await SeriesMetadata.writeSeries(meta, into: layout.directory)
            try FileManager.default.createDirectory(at: layout.seasonDirectory, withIntermediateDirectories: true)
        } catch {
            return "NAS 目录不可用：\(describe(error))"
        }
        if locked > 0 { warnings.append("\(locked) 集已锁定，需在来源平台解锁后再下载") }

        // Episode NFOs, and copies of what is already on this Mac.
        let local = localFiles
        let title = list.title
        let copied: Int = await Task.detached(priority: .utility) {
            var count = 0
            for episode in wanted {
                let nfo = layout.nfoURL(for: episode)
                if !FileManager.default.fileExists(atPath: nfo.path) {
                    try? Data(SeriesMetadata.episodeNFO(seriesTitle: title, episode: episode, season: layout.season).utf8).write(to: nfo, options: [.atomic])
                }
                let target = layout.videoURL(for: episode)
                guard let source = local[episode.vid], source != target, !FileManager.default.fileExists(atPath: target.path) else { continue }
                let staging = target.appendingPathExtension("copying")
                try? FileManager.default.removeItem(at: staging)
                do {
                    try FileManager.default.copyItem(at: source, to: staging)
                    try FileManager.default.moveItem(at: staging, to: target)
                    count += 1
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                }
            }
            return count
        }.value

        let remaining = wanted.filter { local[$0.vid] == nil && !FileManager.default.fileExists(atPath: layout.videoURL(for: $0).path) }
        var queued = 0
        if !remaining.isEmpty {
            do {
                queued = try await downloads.enqueue(seriesId: list.seriesId, seriesTitle: list.title, cover: cover, episodes: remaining,
                                                     destination: { layout.videoURL(for: $0) })
            } catch {
                return "NAS 下载提交失败：\(describe(error))"
            }
        }
        var parts: [String] = []
        if copied > 0 { parts.append("已复制 \(copied) 集") }
        if queued > 0 { parts.append("\(queued) 集加入下载队列") }
        if parts.isEmpty { parts.append("这部剧已经都在 NAS 文件夹里了") }
        let message = parts.joined(separator: "，") + "。位置：\(layout.directory.path)"
        return warnings.isEmpty ? message : message + "（\(warnings.joined(separator: "；"))）"
    }
}

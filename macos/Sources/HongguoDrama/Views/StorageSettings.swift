import AppKit
import UniformTypeIdentifiers
import SwiftUI
import HongguoCore

/// Disk use per downloaded series with delete actions. Embedded in a Form (settings) or a sheet.
struct StorageSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var usage: [DownloadManager.SeriesUsage] = []
    @State private var confirmSeries: DownloadManager.SeriesUsage?
    @State private var confirmAll = false
    @State private var message = ""

    private var total: Int64 { usage.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Section {
            if usage.isEmpty {
                Text("还没有已下载的文件").foregroundStyle(.secondary)
            }
            ForEach(usage) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.seriesTitle).lineLimit(1)
                        Text("\(item.files) 个文件").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button(role: .destructive) { confirmSeries = item } label: { Image(systemName: "trash") }
                        .help("删除这部剧的全部下载文件")
                }
            }
            if !usage.isEmpty {
                HStack {
                    Button("打开下载文件夹") { NSWorkspace.shared.open(AppModel.downloadConfiguration(model.settings).root) }
                    Spacer()
                    Button("删除全部已下载", role: .destructive) { confirmAll = true }
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text(usage.isEmpty ? "存储空间" : "存储空间 · 共 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
        }
        .task(id: model.downloadTasks.map(\.id)) { await refresh() }
        .confirmationDialog("删除《\(confirmSeries?.seriesTitle ?? "")》的全部下载？", isPresented: Binding(
            get: { confirmSeries != nil }, set: { if !$0 { confirmSeries = nil } })) {
            Button("删除", role: .destructive) {
                if let item = confirmSeries { delete(item) }
            }
        } message: {
            Text("会删除这部剧已下载的视频、未完成的部分和导出的弹幕评论文件，无法恢复。")
        }
        .confirmationDialog("删除全部已下载的文件？", isPresented: $confirmAll) {
            Button("全部删除", role: .destructive) { deleteAll() }
        } message: {
            Text("正在下载的剧会跳过。删除后无法恢复。")
        }
    }

    private func refresh() async {
        usage = await model.downloads.seriesUsage()
    }

    private func delete(_ item: DownloadManager.SeriesUsage) {
        Task {
            do {
                let result = try await model.downloads.deleteSeries(item.seriesId)
                message = "已删除 \(result.count) 集，释放 \(ByteCountFormatter.string(fromByteCount: result.freed, countStyle: .file))"
            } catch {
                message = (error as? HongguoError)?.message ?? describe(error)
            }
            await refresh()
        }
    }

    private func deleteAll() {
        Task {
            let result = await model.downloads.deleteAllDownloaded()
            var text = "已删除 \(result.count) 集，释放 \(ByteCountFormatter.string(fromByteCount: result.freed, countStyle: .file))"
            if result.skipped > 0 { text += "，\(result.skipped) 部正在下载已跳过" }
            if result.failed > 0 { text += "，\(result.failed) 部删除失败" }
            message = text
            await refresh()
        }
    }
}

/// Sheet version for the downloads page.
struct StorageSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form { StorageSettingsSection() }.formStyle(.grouped)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(14)
        }
        .frame(width: 520, height: 460)
    }
}

/// Saves danmaku and episode comments next to the downloaded videos of one series, or the
/// series reviews to a chosen file.
@MainActor
enum TextExportActions {
    static func exportSidecars(seriesId: String, seriesTitle: String) async -> String {
        let model = AppModel.shared
        let targets = TextExport.targets(seriesId: seriesId, tasks: model.downloadTasks)
        guard !targets.isEmpty else { return "这部剧还没有已下载完成的集" }
        let summary = await TextExport.export(seriesId: seriesId, seriesTitle: seriesTitle, targets: targets,
                                              kinds: [.danmaku, .comments], fetchers: fetchers)
        var parts = ["弹幕 \(summary.danmaku.ok) 集", "本集评论 \(summary.comments.ok) 集"]
        let skipped = summary.danmaku.skipped + summary.comments.skipped
        let failed = summary.danmaku.fail + summary.comments.fail
        if skipped > 0 { parts.append("\(skipped) 个已存在跳过") }
        if summary.comments.unavailable > 0 { parts.append("\(summary.comments.unavailable) 集官网无公开评论") }
        if failed > 0 { parts.append("\(failed) 个失败") }
        return "已导出：" + parts.joined(separator: "，") + "。文件保存在视频旁边。"
    }

    static func exportReviews(seriesId: String, seriesTitle: String) async -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(DownloadNaming.sanitizeFolderName(seriesTitle).isEmpty ? "红果短剧" : DownloadNaming.sanitizeFolderName(seriesTitle)) 评论.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // A complete earlier file is kept by TextExport, so an explicit save replaces it.
        try? FileManager.default.removeItem(at: url)
        let summary = await TextExport.export(seriesId: seriesId, seriesTitle: seriesTitle, targets: [], kinds: [.reviews],
                                              reviewsFile: url, fetchers: fetchers)
        if summary.reviews.ok > 0 {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "已导出 \(summary.reviews.items) 条评论" + (summary.reviews.partial > 0 ? "（官网只提供部分评论）" : "")
        }
        return "评论导出失败，请稍后重试"
    }

    private static var fetchers: TextExport.Fetchers {
        .live(danmaku: DanmakuService.shared, series: AppModel.shared.series)
    }
}

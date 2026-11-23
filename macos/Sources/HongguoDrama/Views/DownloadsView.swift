import AppKit
import SwiftUI
import HongguoCore

/// Download manager: queue status, per-series groups with per-episode progress and actions.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var storage: Int64 = 0
    @State private var showStorage = false
    /// Inside 我的: no page title, the page's own tab bar names it.
    var embedded = false

    enum Filter: Hashable, Sendable { case all, active, completed, failed }

    private var tasks: [DownloadTask] {
        model.downloadTasks.filter { task in
            switch filter {
            case .all: return true
            case .active: return task.isActive || task.status == .paused
            case .completed: return task.status == .completed
            case .failed: return task.status == .failed
            }
        }
    }

    /// Series groups in the order they were first queued.
    private var groups: [(seriesId: String, tasks: [DownloadTask])] {
        var order: [String] = []
        var map: [String: [DownloadTask]] = [:]
        for task in tasks.sorted(by: { $0.createdAt < $1.createdAt }) {
            if map[task.seriesId] == nil { order.append(task.seriesId) }
            map[task.seriesId, default: []].append(task)
        }
        return order.reversed().map { ($0, map[$0]!.sorted { $0.episodeIndex < $1.episodeIndex }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: embedded ? "" : "下载", subtitle: subtitle) {
                    Button { Task { _ = await model.downloads.resumeAll() } } label: { Label("全部继续", systemImage: "play.fill") }
                        .buttonStyle(GlassButtonStyle())
                    Button { Task { _ = await model.downloads.pauseAll() } } label: { Label("全部暂停", systemImage: "pause.fill") }
                        .buttonStyle(GlassButtonStyle())
                    Button { showStorage = true } label: { Label("存储空间", systemImage: "internaldrive") }
                        .buttonStyle(GlassButtonStyle())
                        .help("按剧查看和清理下载占用的空间")
                    Button { NSWorkspace.shared.open(AppModel.downloadConfiguration(model.settings).root) } label: { Image(systemName: "folder") }
                        .buttonStyle(GlassIconButtonStyle(diameter: 38))
                        .help("打开下载文件夹")
                }
                GlassSegments(options: [GlassOption(label: "全部 \(model.downloadTasks.count)", value: Filter.all),
                                        GlassOption(label: "进行中 \(count { $0.isActive || $0.status == .paused })", value: Filter.active),
                                        GlassOption(label: "已完成 \(count { $0.status == .completed })", value: Filter.completed),
                                        GlassOption(label: "失败 \(count { $0.status == .failed })", value: Filter.failed)],
                              selection: $filter)
                if groups.isEmpty {
                    ContentUnavailableView(filter == .all ? "还没有下载任务" : "这里没有任务", systemImage: "arrow.down.circle",
                                           description: Text("在剧集详情页点“下载”即可离线观看，已下载的集会直接从本地播放。"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ForEach(groups, id: \.seriesId) { group in
                        DownloadGroupCard(tasks: group.tasks)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .navigationTitle(embedded ? "我的" : "下载")
        .transparentToolbar()
        .sheet(isPresented: $showStorage) { StorageSheet().environment(model) }
        .task(id: model.downloadTasks.filter { $0.status == .completed }.count) {
            storage = await model.downloads.storageUsage()
        }
    }

    private func count(_ predicate: (DownloadTask) -> Bool) -> Int { model.downloadTasks.filter(predicate).count }

    private var subtitle: String {
        let active = count { $0.status == .downloading }
        let pending = count { $0.status == .pending }
        var parts = ["已占用 \(ByteCountFormatter.string(fromByteCount: storage, countStyle: .file))"]
        if active > 0 { parts.insert("\(active) 个下载中", at: 0) }
        if pending > 0 { parts.insert("\(pending) 个排队", at: active > 0 ? 1 : 0) }
        return parts.joined(separator: " · ")
    }
}

/// One series: header with overall progress, then a row per episode.
struct DownloadGroupCard: View {
    let tasks: [DownloadTask]
    @Environment(AppModel.self) private var model
    @State private var expanded = true
    @State private var busy = false
    @State private var notice: String?
    @State private var confirmDelete = false

    private var first: DownloadTask { tasks[0] }
    private var completed: Int { tasks.filter { $0.status == .completed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                CoverImage(url: first.cover, cornerRadius: 10).frame(width: 48, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(first.seriesTitle).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text("已完成 \(completed) / \(tasks.count) 集").font(.system(size: 12)).foregroundStyle(.secondary)
                    ProgressView(value: Double(completed), total: Double(max(1, tasks.count)))
                        .tint(.hongguoRed)
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                }
                Spacer(minLength: 0)
                if completed > 0 {
                    Button { play(tasks.first { $0.status == .completed }!) } label: { Label("播放", systemImage: "play.fill") }
                        .buttonStyle(GlassButtonStyle(prominent: true, size: .small))
                }
                Menu {
                    Button("导出弹幕和本集评论") { run { await TextExportActions.exportSidecars(seriesId: first.seriesId, seriesTitle: first.seriesTitle) } }
                        .disabled(completed == 0)
                    Button("导出全剧评论…") { run { await TextExportActions.exportReviews(seriesId: first.seriesId, seriesTitle: first.seriesTitle) } }
                    Divider()
                    Button("合并已下载的集（快速，不重新编码）") {
                        run { await model.startMerge(seriesId: first.seriesId, title: first.seriesTitle, mode: .fast) }
                    }
                    .disabled(completed < 2 || mergeJob?.status == .running)
                    Button("合并为兼容格式（H.264，较慢）") {
                        run { await model.startMerge(seriesId: first.seriesId, title: first.seriesTitle, mode: .compatible) }
                    }
                    .disabled(completed < 2 || mergeJob?.status == .running)
                    Button("下载到 NAS…") { run { await sendToNAS() } }
                    Divider()
                    Button("重新扫描本地文件") { run { await rescan() } }
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([first.fileURL.deletingLastPathComponent()]) }
                    Divider()
                    Button("删除这部剧的全部下载…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: busy ? "hourglass" : "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(GlassIconButtonStyle(diameter: 32))
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(busy)
                .help("导出、扫描和删除")
                Button { withAnimation { expanded.toggle() } } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(GlassIconButtonStyle(diameter: 32))
                    .help(expanded ? "收起" : "展开")
            }
            if let job = mergeJob { mergeRow(job) }
            if let notice {
                Label(notice, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(8))
                        self.notice = nil
                    }
            }
            if expanded {
                VStack(spacing: 2) {
                    ForEach(tasks) { task in
                        DownloadTaskRow(task: task) { play(task) }
                    }
                }
            }
        }
        .padding(16)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contextMenu {
            Button("删除这部剧的全部任务（保留文件）") { remove(deleteFile: false) }
            Button("删除任务和已下载文件", role: .destructive) { remove(deleteFile: true) }
        }
        .confirmationDialog("删除《\(first.seriesTitle)》的全部下载？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { deleteSeries() }
        } message: {
            Text("会删除已下载的视频、未完成的部分和导出的弹幕评论文件。正在下载时不能删除。")
        }
    }

    private var mergeJob: MergeExporter.Job? { model.mergeJobs.first { $0.seriesId == first.seriesId } }

    @ViewBuilder
    private func mergeRow(_ job: MergeExporter.Job) -> some View {
        HStack(spacing: 10) {
            switch job.status {
            case .running:
                ProgressView(value: job.progress).tint(.hongguoRed).controlSize(.small).frame(maxWidth: 220)
                Text("正在合并 \(job.episodes) 集\(job.mode == .compatible ? "（兼容格式）" : "") \(Int(job.progress * 100))%")
                Button("取消") { Task { await MergeExporter.shared.cancel(job.seriesId) } }.buttonStyle(.link)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("合并完成：\(job.output?.lastPathComponent ?? "")").lineLimit(1)
                Button("在访达中显示") { if let url = job.output { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.buttonStyle(.link)
                Button("知道了") { Task { await MergeExporter.shared.dismiss(job.seriesId) } }.buttonStyle(.link)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
                Button("知道了") { Task { await MergeExporter.shared.dismiss(job.seriesId) } }.buttonStyle(.link)
            case .cancelled:
                Text("已取消合并")
                Button("知道了") { Task { await MergeExporter.shared.dismiss(job.seriesId) } }.buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func sendToNAS() async -> String? {
        do {
            let list = try await AppModel.seriesService.episodes(seriesId: first.seriesId)
            return await model.downloadToNAS(list, cover: first.cover)
        } catch {
            return "读取分集失败：\(describe(error))"
        }
    }

    private func run(_ body: @escaping () async -> String?) {
        busy = true
        Task {
            let text = await body()
            busy = false
            if let text { notice = text }
        }
    }

    private func rescan() async -> String {
        do {
            let list = try await AppModel.seriesService.episodes(seriesId: first.seriesId)
            let added = try await model.downloads.rescan(seriesId: first.seriesId, seriesTitle: first.seriesTitle,
                                                         cover: first.cover, episodes: list.episodes)
            return added > 0 ? "找到 \(added) 个本地文件，已加入下载列表" : "没有找到新的本地文件"
        } catch {
            return (error as? HongguoError)?.message ?? describe(error)
        }
    }

    private func deleteSeries() {
        run {
            do {
                let result = try await model.downloads.deleteSeries(first.seriesId)
                return "已删除 \(result.count) 集，释放 \(ByteCountFormatter.string(fromByteCount: result.freed, countStyle: .file))"
            } catch {
                return (error as? HongguoError)?.message ?? describe(error)
            }
        }
    }

    private func remove(deleteFile: Bool) {
        let ids = tasks.map(\.id)
        Task { try? await model.downloads.remove(ids, deleteFile: deleteFile) }
    }

    private func play(_ task: DownloadTask) {
        Task {
            await PlayerController.shared.open(seriesId: task.seriesId, title: task.seriesTitle, cover: task.cover, index: task.episodeIndex)
        }
    }
}

struct DownloadTaskRow: View {
    let task: DownloadTask
    var play: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text("第 \(task.episodeIndex) 集")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 72, alignment: .leading)
            statusIcon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                if task.status == .downloading || task.status == .paused || task.status == .pending {
                    ProgressView(value: task.progress).tint(.hongguoRed).controlSize(.small)
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(task.status == .failed ? AnyShapeStyle(Color.hongguoRed) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
            Spacer(minLength: 8)
            actions.opacity(hovering || task.status == .failed ? 1 : 0.55)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(hovering ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if task.status == .completed { play() } }
    }

    @ViewBuilder private var statusIcon: some View {
        switch task.status {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.hongguoRed)
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hongguoGold)
        }
    }

    private var detail: String {
        let bytes = { (v: Int64) in ByteCountFormatter.string(fromByteCount: v, countStyle: .file) }
        switch task.status {
        case .completed: return task.totalBytes > 0 ? "已完成 · \(bytes(task.totalBytes))" : "已完成"
        case .downloading:
            let phase = task.phase.map { phaseName($0) } ?? "下载中"
            return task.totalBytes > 0 ? "\(phase) · \(bytes(task.receivedBytes)) / \(bytes(task.totalBytes))" : phase
        case .pending: return "排队中"
        case .paused: return task.error ?? "已暂停"
        case .failed: return task.error ?? "下载失败"
        }
    }

    private func phaseName(_ phase: DownloadPhase) -> String {
        switch phase {
        case .resolving: return "解析片源"
        case .transferring: return "下载中"
        case .decrypting: return "解密中"
        case .converting: return "ByteVC2 转换中"
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            switch task.status {
            case .downloading, .pending:
                iconButton("pause.fill", "暂停") { await model.downloads.pause(task.id) }
            case .paused:
                iconButton("play.fill", "继续") { await model.downloads.resume(task.id) }
            case .failed:
                iconButton("arrow.clockwise", "重试") { await model.downloads.restart(task.id) }
            case .completed:
                Button(action: play) { Image(systemName: "play.fill") }
                    .buttonStyle(BarIconButtonStyle(size: 28))
                    .help("播放")
                Button { NSWorkspace.shared.activateFileViewerSelecting([task.fileURL]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(BarIconButtonStyle(size: 28))
                    .help("在访达中显示")
            }
            iconButton("xmark", task.status == .completed ? "删除任务和文件" : "取消") {
                try? await model.downloads.remove([task.id], deleteFile: task.status == .completed)
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Image(systemName: symbol) }
            .buttonStyle(BarIconButtonStyle(size: 28))
            .help(help)
    }
}

import AppKit
import SwiftUI
import HongguoCore

/// Download manager: queue status, per-series groups with per-episode progress and actions.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var storage: Int64 = 0

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
                PageHeader(title: "下载", subtitle: subtitle) {
                    Button { Task { _ = await model.downloads.resumeAll() } } label: { Label("全部继续", systemImage: "play.fill") }
                        .buttonStyle(GlassButtonStyle())
                    Button { Task { _ = await model.downloads.pauseAll() } } label: { Label("全部暂停", systemImage: "pause.fill") }
                        .buttonStyle(GlassButtonStyle())
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
                                           description: Text("在剧集详情页点"下载"即可离线观看，已下载的集会直接从本地播放。"))
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
        .navigationTitle("下载")
        .transparentToolbar()
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
                Button { withAnimation { expanded.toggle() } } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(GlassIconButtonStyle(diameter: 32))
                    .help(expanded ? "收起" : "展开")
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

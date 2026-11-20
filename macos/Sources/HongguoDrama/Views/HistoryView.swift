import SwiftUI
import HongguoCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    /// Inside 我的: no page title, the page's own tab bar names it.
    var embedded = false

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("还没有观看记录", systemImage: "clock", description: Text("播放过的短剧会出现在这里。"))
            } else {
                ScrollView {
                    PageHeader(title: embedded ? "" : "观看记录", subtitle: subtitle) {
                        if !embedded, AccountState.shared.profile != nil {
                            Button { Task { await model.syncCloudHistory(force: true, manual: true) } } label: {
                                Label(model.cloudSyncing ? "同步中…" : "同步云端", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(GlassButtonStyle())
                            .disabled(model.cloudSyncing)
                        }
                        if model.settings.watchUpdatesEnabled {
                            Button { Task { await checkUpdates() } } label: {
                                Label(model.watchChecking ? "检查中…" : "检查更新", systemImage: "bell.badge")
                            }
                            .buttonStyle(GlassButtonStyle())
                            .disabled(model.watchChecking)
                            .help("检查已看剧集有没有新集和续作")
                        }
                        Button(role: .destructive) { confirmClear = true } label: { Label("清空", systemImage: "trash") }
                            .buttonStyle(GlassButtonStyle())
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                        ForEach(model.history) { record in
                            HistoryRow(record: record) { resume(record) }
                                .contextMenu {
                                    Button("继续播放") { resume(record) }
                                    Button("查看详情") { openDetail(record) }
                                    if let sequels = record.sequels, !sequels.isEmpty {
                                        Menu("续作") {
                                            ForEach(sequels, id: \.seriesId) { ref in
                                                Button(ref.title) {
                                                    model.acknowledgeUpdates(record.seriesId)
                                                    model.open(SeriesSummary(seriesId: ref.seriesId, title: ref.title))
                                                }
                                            }
                                        }
                                    }
                                    if record.hasUpdates {
                                        Button("标记更新为已读") { model.acknowledgeUpdates(record.seriesId) }
                                    }
                                    Divider()
                                    Button("删除记录", role: .destructive) {
                                        AccountSync.shared.historyRemoved(record)
                                        model.store.removeHistory(record.seriesId)
                                        model.refreshHistory()
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .padding(.top, 8)
                }
                .background(alignment: .top) {
                    if !embedded, let cover = model.history.first?.cover, !cover.isEmpty {
                        AmbientBackdrop(url: cover, opacity: 0.4)
                            .frame(height: 420)
                            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                            .extendsUnderChrome()
                            .ignoresSafeArea()
                    }
                }
            }
        }
        .navigationTitle(embedded ? "我的" : "观看记录")
        .transparentToolbar()
        .confirmationDialog("清空全部观看记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                model.store.clearHistory()
                model.refreshHistory()
            }
        }
        .onAppear { model.refreshHistory() }
        .task { await model.syncCloudHistory() }
    }

    @State private var checkMessage = ""

    private func checkUpdates() async {
        checkMessage = ""
        guard let summary = await model.checkWatchUpdates(force: true) else { return }
        var text = "检查了 \(summary.checked) 部"
        if summary.withUpdates > 0 { text += "，\(summary.withUpdates) 部有更新" } else { text += "，暂无更新" }
        if summary.failed > 0 { text += "，\(summary.failed) 部检查失败" }
        checkMessage = text
    }

    private var subtitle: String {
        var text = "\(model.history.count) 部"
        if AccountState.shared.profile != nil { text += " · 已与云端合并" }
        if !model.cloudSyncMessage.isEmpty { text += " · \(model.cloudSyncMessage)" }
        if !checkMessage.isEmpty { text += " · \(checkMessage)" }
        return text
    }

    private func resume(_ record: WatchRecord) {
        model.acknowledgeUpdates(record.seriesId)
        Task {
            await PlayerController.shared.resume(seriesId: record.seriesId, title: record.title, cover: record.cover)
        }
    }

    private func openDetail(_ record: WatchRecord) {
        model.open(SeriesSummary(seriesId: record.seriesId, title: record.title, cover: record.cover, episodeCount: record.total))
    }
}

struct HistoryRow: View {
    let record: WatchRecord
    var resume: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            CoverImage(url: record.cover, cornerRadius: 12).frame(width: 66, height: 88)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(record.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    if record.unreadEpisodes > 0 {
                        Text("更新 \(record.unreadEpisodes) 集")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color.hongguoRed, in: Capsule())
                    } else if !record.unreadSequelIds.isEmpty {
                        Text("有续作")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color.hongguoGold, in: Capsule())
                    }
                }
                Text(progressText).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(record.updatedAt, style: .relative).font(.system(size: 11)).foregroundStyle(.tertiary)
                if record.total > 0 {
                    ProgressView(value: Double(min(record.completedEpisode, record.total)), total: Double(record.total))
                        .tint(.hongguoRed)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button(action: resume) { Image(systemName: "play.fill").offset(x: 1) }
                .buttonStyle(GlassIconButtonStyle(diameter: 40))
                .help(record.isFinished ? "重看" : "继续播放")
        }
        .padding(12)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(count: 2, perform: resume)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var progressText: String {
        var text = "看到第 \(record.episodeIndex) 集"
        if record.total > 0 { text += " / 共 \(record.total) 集" }
        let time = formatTime(record.position)
        if !time.isEmpty { text += " · \(time)" }
        if record.isFinished { text = "已看完 · 共 \(record.total) 集" }
        return text
    }
}

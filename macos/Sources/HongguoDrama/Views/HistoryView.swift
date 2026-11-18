import SwiftUI
import HongguoCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("还没有观看记录", systemImage: "clock", description: Text("播放过的短剧会出现在这里。"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                        ForEach(model.history) { record in
                            HistoryRow(record: record) { resume(record) }
                                .contextMenu {
                                    Button("继续播放") { resume(record) }
                                    Button("查看详情") { openDetail(record) }
                                    Divider()
                                    Button("删除记录", role: .destructive) {
                                        model.store.removeHistory(record.seriesId)
                                        model.refreshHistory()
                                    }
                                }
                        }
                    }
                    .padding(24)
                }
                .background(alignment: .top) {
                    if let cover = model.history.first?.cover, !cover.isEmpty {
                        AmbientBackdrop(url: cover, opacity: 0.4)
                            .frame(height: 420)
                            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                            .extendsUnderChrome()
                            .ignoresSafeArea()
                    }
                }
            }
        }
        .navigationTitle("观看记录")
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) { confirmClear = true } label: { Label("清空", systemImage: "trash") }
                    .disabled(model.history.isEmpty)
            }
        }
        .confirmationDialog("清空全部观看记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                model.store.clearHistory()
                model.refreshHistory()
            }
        }
        .onAppear { model.refreshHistory() }
    }

    private func resume(_ record: WatchRecord) {
        Task {
            await PlayerController.shared.open(seriesId: record.seriesId, title: record.title, cover: record.cover,
                                               index: record.episodeIndex, startAt: record.position)
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
                Text(record.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
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

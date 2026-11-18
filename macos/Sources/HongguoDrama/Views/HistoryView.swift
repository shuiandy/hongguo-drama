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
                List {
                    ForEach(model.history) { record in
                        HistoryRow(record: record)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { resume(record) }
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
                .listStyle(.inset)
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

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: record.cover, cornerRadius: 6).frame(width: 54, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.headline)
                Text(progressText).font(.callout).foregroundStyle(.secondary)
                Text(record.updatedAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if record.total > 0 {
                ProgressView(value: Double(min(record.completedEpisode, record.total)), total: Double(record.total))
                    .frame(width: 90)
            }
        }
        .padding(.vertical, 4)
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

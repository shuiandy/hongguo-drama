import SwiftUI
import HongguoCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("发现") {
                    ForEach(CatalogKind.categories) { kind in
                        Label(kind.label, systemImage: SidebarItem.category(kind).symbol).tag(SidebarItem.category(kind))
                    }
                }
                Section("榜单") {
                    ForEach(CatalogKind.rankings) { kind in
                        Label(kind.label, systemImage: rankingSymbol(kind)).tag(SidebarItem.ranking(kind))
                    }
                }
                Section("我的") {
                    Label("搜索", systemImage: "magnifyingglass").tag(SidebarItem.search)
                    Label("观看记录", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let record = model.history.first {
                    ContinueWatchingCard(record: record)
                        .padding(10)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 260)
        } detail: {
            if let item = model.selection {
                NavigationStack(path: model.path(for: item)) {
                    root(for: item)
                        .navigationDestination(for: SeriesSummary.self) { summary in
                            SeriesDetailView(summary: summary)
                        }
                }
                .id(item)
            } else {
                ContentUnavailableView("选择一个栏目", systemImage: "play.rectangle")
            }
        }
        .tint(.hongguoRed)
    }

    private func rankingSymbol(_ kind: CatalogKind) -> String {
        switch kind {
        case .hotDrama: return "flame"
        case .hotRealDrama: return "person.2"
        case .hotComicDrama: return "paintpalette"
        default: return "chart.bar"
        }
    }

    @ViewBuilder
    private func root(for item: SidebarItem) -> some View {
        switch item {
        case .category(let kind): CatalogView(kind: kind)
        case .ranking(let kind): CatalogView(kind: kind)
        case .search: SearchView()
        case .history: HistoryView()
        }
    }
}

/// Sidebar footer: resume the most recent series in one click.
struct ContinueWatchingCard: View {
    let record: WatchRecord

    var body: some View {
        Button {
            Task {
                await PlayerController.shared.open(seriesId: record.seriesId, title: record.title, cover: record.cover,
                                                   index: record.episodeIndex, startAt: record.position)
            }
        } label: {
            HStack(spacing: 10) {
                CoverImage(url: record.cover, cornerRadius: 8)
                    .frame(width: 34, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("继续观看 · \(record.title)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if record.total > 0 {
                        ProgressView(value: Double(min(record.episodeIndex, record.total)), total: Double(record.total))
                            .progressViewStyle(.linear)
                            .tint(.hongguoRed)
                            .controlSize(.mini)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .glassSurface(.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .help("继续播放 \(record.title)")
    }

    private var subtitle: String {
        var text = "第 \(record.episodeIndex) 集"
        let time = formatTime(record.position)
        if !time.isEmpty { text += " · \(time)" }
        return text
    }
}

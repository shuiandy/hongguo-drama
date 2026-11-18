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
                        Label(kind.label, systemImage: "flame").tag(SidebarItem.ranking(kind))
                    }
                }
                Section("我的") {
                    Label("搜索", systemImage: "magnifyingglass").tag(SidebarItem.search)
                    Label("观看记录", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
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

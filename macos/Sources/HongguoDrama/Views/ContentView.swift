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
                        SidebarRow(title: kind.label, style: SidebarStyle.of(.category(kind))).tag(SidebarItem.category(kind))
                    }
                }
                Section("榜单") {
                    ForEach(CatalogKind.rankings) { kind in
                        SidebarRow(title: kind.label, style: SidebarStyle.of(.ranking(kind))).tag(SidebarItem.ranking(kind))
                    }
                }
                Section("我的") {
                    SidebarRow(title: "观看记录", style: SidebarStyle.of(.history),
                               badge: model.history.isEmpty ? nil : "\(model.history.count)").tag(SidebarItem.history)
                    SidebarRow(title: "我的剧库", style: SidebarStyle.of(.library),
                               badge: model.favorites.isEmpty ? nil : "\(model.favorites.count)").tag(SidebarItem.library)
                    SidebarRow(title: "下载", style: SidebarStyle.of(.downloads), badge: downloadBadge).tag(SidebarItem.downloads)
                    SidebarRow(title: "账号", style: SidebarStyle.of(.account), badge: AccountState.shared.profile?.nickname ?? "未登录")
                        .tag(SidebarItem.account)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { BrandHeader() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let record = model.history.first {
                    ContinueWatchingCard(record: record).padding(10)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
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
        .task { await AccountState.shared.restore() }
        .background {
            // ⌘K jumps to search from anywhere in the main window. Search has no sidebar row:
            // the header search field on 发现 and 剧库 opens the same results page.
            Button("搜索") { model.selection = .search }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func root(for item: SidebarItem) -> some View {
        switch item {
        case .category(let kind): CatalogView(kind: kind)
        case .ranking(let kind): CatalogView(kind: kind)
        case .search: SearchView()
        case .history: HistoryView()
        case .library: LibraryView()
        case .downloads: DownloadsView()
        case .account: AccountView()
        }
    }

    private var downloadBadge: String? {
        let active = model.downloadTasks.filter(\.isActive).count
        return active > 0 ? "\(active)" : nil
    }
}

// MARK: Sidebar

struct SidebarStyle {
    let symbol: String
    let colors: [Color]

    static func of(_ item: SidebarItem) -> SidebarStyle {
        switch item {
        case .category(.realDrama): return SidebarStyle(symbol: "person.2.fill", colors: [Color(red: 1, green: 0.42, blue: 0.48), .hongguoRedDeep])
        case .category(.comicDrama): return SidebarStyle(symbol: "paintpalette.fill", colors: [Color(red: 0.65, green: 0.55, blue: 0.98), Color(red: 0.49, green: 0.23, blue: 0.93)])
        case .category: return SidebarStyle(symbol: "sparkles", colors: [Color(red: 0.22, green: 0.74, blue: 0.97), Color(red: 0.01, green: 0.41, blue: 0.63)])
        case .ranking(.hotDrama): return SidebarStyle(symbol: "flame.fill", colors: [Color(red: 0.98, green: 0.57, blue: 0.24), Color(red: 0.92, green: 0.35, blue: 0.05)])
        case .ranking(.hotRealDrama): return SidebarStyle(symbol: "chart.bar.fill", colors: [Color(red: 0.96, green: 0.45, blue: 0.71), Color(red: 0.75, green: 0.09, blue: 0.36)])
        case .ranking(.hotComicDrama): return SidebarStyle(symbol: "chart.bar.fill", colors: [Color(red: 0.75, green: 0.52, blue: 0.99), Color(red: 0.58, green: 0.2, blue: 0.92)])
        case .ranking: return SidebarStyle(symbol: "chart.bar.fill", colors: [Color(red: 0.38, green: 0.65, blue: 0.98), Color(red: 0.11, green: 0.31, blue: 0.85)])
        case .search: return SidebarStyle(symbol: "magnifyingglass", colors: [Color(red: 0.58, green: 0.64, blue: 0.72), Color(red: 0.28, green: 0.33, blue: 0.41)])
        case .history: return SidebarStyle(symbol: "clock.fill", colors: [Color(red: 0.2, green: 0.83, blue: 0.6), Color(red: 0.02, green: 0.47, blue: 0.34)])
        case .library: return SidebarStyle(symbol: "heart.fill", colors: [Color(red: 1, green: 0.45, blue: 0.55), Color(red: 0.86, green: 0.15, blue: 0.35)])
        case .downloads: return SidebarStyle(symbol: "arrow.down.circle.fill", colors: [Color(red: 0.35, green: 0.6, blue: 1), Color(red: 0.15, green: 0.35, blue: 0.9)])
        case .account: return SidebarStyle(symbol: "person.crop.circle.fill", colors: [Color(red: 0.99, green: 0.72, blue: 0.3), Color(red: 0.9, green: 0.45, blue: 0.08)])
        }
    }
}

/// 15 pt sidebar row with a colour icon tile, like System Settings.
struct SidebarRow: View {
    let title: String
    let style: SidebarStyle
    var badge: String?

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: style.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(LinearGradient(colors: style.colors, startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(.system(size: 15, weight: .medium))
            Spacer(minLength: 0)
            if let badge {
                Text(badge).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// App mark and name at the top of the sidebar.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: .hongguoRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("红果短剧").font(.system(size: 18, weight: .heavy))
                Text("Mac 原生版").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 10)
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
            HStack(spacing: 12) {
                CoverImage(url: record.cover, cornerRadius: 9)
                    .frame(width: 42, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("继续观看").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(record.title)
                        .font(.system(size: 13, weight: .bold))
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
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .glassSurface(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
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

// MARK: Page chrome

/// Large page title row inside the content, on the same leading edge as everything below it.
/// The window toolbar stays transparent so there is no separate band or hairline.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 28, weight: .heavy)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
    }
}

/// Compact glass search field for page headers: submitting jumps to the search page with the query.
struct HeaderSearchField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            TextField("搜索剧名，或粘贴分享链接", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { return }
                    model.pendingSearch = query
                    text = ""
                    model.selection = .search
                }
            Text("⌘K")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: 290, height: 38)
        .glassSurface(in: Capsule(), interactive: true)
    }
}

extension View {
    /// Transparent window toolbar: content and the ambient backdrop run up to the traffic lights,
    /// and the page draws its own aligned header.
    @ViewBuilder
    func transparentToolbar() -> some View {
        let base = self.toolbarBackground(.hidden, for: .windowToolbar)
        if #available(macOS 15.0, *) {
            base.toolbar(removing: .title)
        } else {
            base
        }
    }
}

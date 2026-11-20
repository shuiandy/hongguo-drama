import SwiftUI
import AppKit
import HongguoCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            mainSidebar
        } detail: {
            Group {
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
            .mainToolbar(model)
            .sheet(isPresented: $model.showingSettings) {
                SettingsPanel().environment(model)
            }
        }
        .tint(.hongguoRed)
        .task {
            // Test builds: HONGGUO_OPEN_SETTINGS=<pane> opens settings at launch for screenshots.
            if let raw = ProcessInfo.processInfo.environment["HONGGUO_OPEN_SETTINGS"] {
                model.showSettings(SettingsPane(rawValue: raw))
            }
            model.startBackgroundChecks()
            await AccountState.shared.restore()
            await model.syncCloudHistory(force: true)
        }
        .sheet(item: $model.announcement) { item in
            AnnouncementSheet(announcement: item)
        }
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

    private var mainSidebar: some View {
        @Bindable var model = model
        return List(selection: $model.selection) {
                Section("发现") {
                    SidebarRow(title: "热播推荐", style: SidebarStyle.of(.feed)).tag(SidebarItem.feed)
                    ForEach(CatalogKind.categories) { kind in
                        SidebarRow(title: kind.label, style: SidebarStyle.of(.category(kind))).tag(SidebarItem.category(kind))
                    }
                    SidebarRow(title: "上新日历", style: SidebarStyle.of(.calendar)).tag(SidebarItem.calendar)
                }
                Section("榜单") {
                    ForEach(CatalogKind.rankings) { kind in
                        SidebarRow(title: kind.label, style: SidebarStyle.of(.ranking(kind))).tag(SidebarItem.ranking(kind))
                    }
                }
                Section("我的") {
                    SidebarRow(title: "我的", style: SidebarStyle.of(.me), badge: downloadBadge,
                               dot: model.history.contains(where: \.hasUpdates)).tag(SidebarItem.me)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { BrandHeader() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let release = model.availableRelease {
                        UpdateAvailableCard(release: release).padding(.horizontal, 10).padding(.top, 10)
                    }
                    if let record = model.history.first {
                        ContinueWatchingCard(record: record).padding(.horizontal, 10).padding(.top, 10)
                    }
                }
                .padding(.bottom, 10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    }

    @ViewBuilder
    private func root(for item: SidebarItem) -> some View {
        switch item {
        case .category(let kind): CatalogView(kind: kind)
        case .ranking(let kind): CatalogView(kind: kind)
        case .search: SearchView()
        case .feed: FeedView()
        case .calendar: ReleaseCalendarView()
        case .me: MeView()
        case .history: HistoryView()
        case .library: LibraryView()
        case .downloads: DownloadsView()
        case .account: AccountView()
        case .source(let id): SourceCatalogView(sourceId: id).id(id)
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
        case .feed: return SidebarStyle(symbol: "dice.fill", colors: [Color(red: 1, green: 0.55, blue: 0.35), Color(red: 0.93, green: 0.25, blue: 0.3)])
        case .calendar: return SidebarStyle(symbol: "calendar", colors: [Color(red: 0.4, green: 0.8, blue: 0.75), Color(red: 0.05, green: 0.5, blue: 0.55)])
        case .search: return SidebarStyle(symbol: "magnifyingglass", colors: [Color(red: 0.58, green: 0.64, blue: 0.72), Color(red: 0.28, green: 0.33, blue: 0.41)])
        case .me: return SidebarStyle(symbol: "person.crop.circle.fill", colors: [Color(red: 1, green: 0.45, blue: 0.55), Color(red: 0.86, green: 0.15, blue: 0.35)])
        case .history: return SidebarStyle(symbol: "clock.fill", colors: [Color(red: 0.2, green: 0.83, blue: 0.6), Color(red: 0.02, green: 0.47, blue: 0.34)])
        case .library: return SidebarStyle(symbol: "heart.fill", colors: [Color(red: 1, green: 0.45, blue: 0.55), Color(red: 0.86, green: 0.15, blue: 0.35)])
        case .downloads: return SidebarStyle(symbol: "arrow.down.circle.fill", colors: [Color(red: 0.35, green: 0.6, blue: 1), Color(red: 0.15, green: 0.35, blue: 0.9)])
        case .source(let id) where id.hasPrefix("custom:"):
            return SidebarStyle(symbol: "link", colors: [Color(red: 0.6, green: 0.65, blue: 0.72), Color(red: 0.32, green: 0.36, blue: 0.43)])
        case .source(let id) where id == "reelshort" || id == "dramabox":
            return SidebarStyle(symbol: "globe", colors: [Color(red: 0.3, green: 0.8, blue: 0.85), Color(red: 0.05, green: 0.5, blue: 0.6)])
        case .source:
            return SidebarStyle(symbol: "film.stack.fill", colors: [Color(red: 0.98, green: 0.75, blue: 0.35), Color(red: 0.85, green: 0.5, blue: 0.1)])
        case .account: return SidebarStyle(symbol: "person.crop.circle.fill", colors: [Color(red: 0.99, green: 0.72, blue: 0.3), Color(red: 0.9, green: 0.45, blue: 0.08)])
        }
    }
}

/// 15 pt sidebar row with a colour icon tile, like System Settings.
struct SidebarRow: View {
    let title: String
    let style: SidebarStyle
    var badge: String?
    /// Red dot for unread updates (new episodes or sequels).
    var dot = false

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
            if dot {
                Circle().fill(Color.hongguoRed).frame(width: 7, height: 7).help("有剧集更新")
            }
            if let badge {
                Text(badge).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// App mark and name at the top of the sidebar.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            AppIconMark(size: 46)
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
                if !title.isEmpty { Text(title).font(.system(size: 28, weight: .heavy)).lineLimit(1) }
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

// MARK: Update and announcements

/// Sidebar card shown when GitHub has a newer release: download and install in the app when the
/// release has an archive, otherwise open the release page.
struct UpdateAvailableCard: View {
    let release: AvailableRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.app.fill").font(.system(size: 18)).foregroundStyle(Color.hongguoRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新版本 \(release.version)").font(.system(size: 13, weight: .semibold))
                    Button("查看更新说明") { NSWorkspace.shared.open(release.url) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                Spacer(minLength: 0)
            }
            UpdateControls(release: release, compact: true)
        }
        .padding(10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Remote announcement. Emergency ones stay until acknowledged; normal ones can be muted.
struct AnnouncementSheet: View {
    let announcement: Announcement
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: announcement.urgent ? "exclamationmark.triangle.fill" : "megaphone.fill")
                    .foregroundStyle(announcement.urgent ? Color.orange : Color.hongguoRed)
                Text(announcement.urgent ? "紧急公告" : "公告").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(announcement.title).font(.system(size: 18, weight: .bold))
            ScrollView {
                Text(announcement.body).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack {
                if announcement.urgent {
                    Spacer()
                    Button("我知道了") { act { try await AppModel.shared.announcements.acknowledge(announcement.id) } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("今天不再提醒") { act { try await AppModel.shared.announcements.mute(.day) } }
                    Button("此版本不再提醒") { act { try await AppModel.shared.announcements.mute(.version) } }
                    Spacer()
                    Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .interactiveDismissDisabled(announcement.urgent)
    }

    private func act(_ body: @escaping () async throws -> Void) {
        Task {
            do { try await body(); dismiss() } catch { self.error = (error as? HongguoError)?.message ?? "保存失败" }
        }
    }
}

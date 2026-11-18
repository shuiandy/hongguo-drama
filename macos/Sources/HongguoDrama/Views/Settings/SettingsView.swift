import SwiftUI
import HongguoCore

/// Categories of the settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, playback, danmaku, shortcuts, downloads, sources, account, notifications, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .playback: return "播放"
        case .danmaku: return "弹幕"
        case .shortcuts: return "快捷键"
        case .downloads: return "下载"
        case .sources: return "片源"
        case .account: return "账号"
        case .notifications: return "追更与通知"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "外观、缓存和从旧版导入"
        case .playback: return "连播、画质、画面模式和速度"
        case .danmaku: return "样式、区域和屏蔽词"
        case .shortcuts: return "播放器和全局快捷键"
        case .downloads: return "位置、命名和存储空间"
        case .sources: return "内置片源和自定义接口"
        case .account: return "红果账号和云端观看记录"
        case .notifications: return "更新提醒、续作和公告"
        case .about: return "版本、更新和项目信息"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .playback: return "play.fill"
        case .danmaku: return "text.bubble.fill"
        case .shortcuts: return "keyboard.fill"
        case .downloads: return "arrow.down"
        case .sources: return "film.stack.fill"
        case .account: return "person.fill"
        case .notifications: return "bell.fill"
        case .about: return "info"
        }
    }

    /// Tile gradient, the same colour language as the main sidebar.
    var tile: [Color] {
        switch self {
        case .general: return [Color(white: 0.62), Color(white: 0.32)]
        case .playback: return [Color(red: 1, green: 0.42, blue: 0.48), .hongguoRedDeep]
        case .danmaku: return [Color(red: 0.22, green: 0.74, blue: 0.97), Color(red: 0.01, green: 0.41, blue: 0.63)]
        case .shortcuts: return [Color(red: 0.58, green: 0.64, blue: 0.72), Color(red: 0.2, green: 0.25, blue: 0.33)]
        case .downloads: return [Color(red: 0.2, green: 0.83, blue: 0.6), Color(red: 0.02, green: 0.47, blue: 0.34)]
        case .sources: return [Color(red: 0.98, green: 0.57, blue: 0.24), Color(red: 0.92, green: 0.35, blue: 0.05)]
        case .account: return [Color(red: 0.65, green: 0.55, blue: 0.98), Color(red: 0.49, green: 0.23, blue: 0.93)]
        case .notifications: return [Color(red: 0.96, green: 0.45, blue: 0.71), Color(red: 0.75, green: 0.09, blue: 0.36)]
        case .about: return [Color(red: 0.38, green: 0.65, blue: 0.98), Color(red: 0.11, green: 0.31, blue: 0.85)]
        }
    }

    /// Words the sidebar search matches besides the title.
    var keywords: [String] {
        switch self {
        case .general: return ["外观", "主题", "深色", "浅色", "启动", "打开时", "缓存", "清理", "导入", "旧版", "Electron"]
        case .playback: return ["连播", "下一集", "预先", "画质", "1080", "720", "画面", "适应", "速度", "倍速", "空格", "音量"]
        case .danmaku: return ["弹幕", "透明", "字号", "速度", "区域", "密度", "屏蔽", "敏感词"]
        case .shortcuts: return ["快捷键", "键盘", "空格", "全屏", "小窗"]
        case .downloads: return ["下载", "位置", "文件夹", "命名", "同时", "删除", "导出", "评论", "存储", "空间"]
        case .sources: return ["片源", "西饭", "河马", "ReelShort", "DramaBox", "接口", "CMS", "搜索"]
        case .account: return ["账号", "登录", "扫码", "退出", "云端", "同步", "观看记录"]
        case .notifications: return ["追更", "更新", "续作", "频率", "通知", "公告"]
        case .about: return ["关于", "版本", "检查更新", "GitHub", "许可", "主页"]
        }
    }

    func matches(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return ([title, subtitle] + keywords).contains { $0.localizedCaseInsensitiveContains(text) }
    }

    static let groups: [(String, [SettingsPane])] = [
        ("偏好", [.general, .playback, .danmaku, .shortcuts]),
        ("内容", [.downloads, .sources]),
        ("账号", [.account, .notifications]),
        ("", [.about]),
    ]
}

/// Sidebar shown in place of the main sidebar while settings are open: a back row, a search
/// field and the categories, as native List rows in the same style as the main sidebar.
struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<SettingsPane?>(get: { model.settingsPane }, set: { if let pane = $0 { model.settingsPane = pane } })) {
            ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { _, group in
                let panes = group.1.filter { $0.matches(query) }
                if !panes.isEmpty {
                    Section(group.0) {
                        ForEach(panes) { pane in
                            SidebarRow(title: pane.title, style: SidebarStyle(symbol: pane.symbol, colors: pane.tile)).tag(pane)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "搜索设置")
        .onSubmit(of: .search) {
            if let first = SettingsPane.allCases.first(where: { $0.matches(query) }) { model.settingsPane = first }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.closeSettings() } label: {
                    Label("返回", systemImage: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(GlassButtonStyle(size: .small))
                .keyboardShortcut(.cancelAction)
                .help("返回主界面（esc）")
                Text("设置").font(.system(size: 18, weight: .heavy))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }
}

/// Detail column while settings are open: page header plus the selected category's form.
struct SettingsDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: model.settingsPane.title, subtitle: model.settingsPane.subtitle) { EmptyView() }
                .padding(.horizontal, 28)
                .padding(.top, 6)
            pane
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .toggleStyle(.switch)
                .tint(.hongguoRed)
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 12)
                .id(model.settingsPane)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("设置 · \(model.settingsPane.title)")
        .transparentToolbar()
    }

    @ViewBuilder
    private var pane: some View {
        switch model.settingsPane {
        case .general: SettingsGeneralPane()
        case .playback: SettingsPlaybackPane()
        case .danmaku: SettingsDanmakuPane()
        case .shortcuts: SettingsShortcutsPane()
        case .downloads: SettingsDownloadsPane()
        case .sources: SettingsSourcesPane()
        case .account: SettingsAccountPane()
        case .notifications: SettingsNotificationsPane()
        case .about: SettingsAboutPane()
        }
    }
}

/// Footer row of the main sidebar that opens settings.
struct SettingsEntryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.showSettings() } label: {
            SidebarRow(title: "设置", style: SidebarStyle(symbol: "gearshape.fill", colors: SettingsPane.general.tile))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("设置（⌘,）")
    }
}

// MARK: Shared pieces

/// Two-line label for a toggle or row: title plus a secondary explanation.
struct SettingLabel: View {
    let title: String
    var note: String = ""

    init(_ title: String, note: String = "") {
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Keycap for the shortcuts list.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 24)
            .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.primary.opacity(0.15)))
    }
}

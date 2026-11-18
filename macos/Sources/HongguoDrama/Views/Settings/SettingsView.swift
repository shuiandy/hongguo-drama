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

/// ⌘, window: floating glass sidebar on the left, the selected category on the right.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.settingsPane.title).font(.system(size: 26, weight: .heavy))
                    Text(model.settingsPane.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 30)
                .padding(.top, 30)
                .padding(.bottom, 2)
                pane
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .toggleStyle(.switch)
                    .tint(.hongguoRed)
                    .padding(.horizontal, 10)
                    .id(model.settingsPane)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 880, height: 660)
        .background { ambient }
        .ignoresSafeArea(.container, edges: .top)
        .settingsWindowChrome()
    }

    private var sidebar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("搜索设置", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassSurface(.clear, in: Capsule())
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { _, group in
                        let panes = group.1.filter { $0.matches(query) }
                        if !panes.isEmpty {
                            if !group.0.isEmpty {
                                Text(group.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                            } else {
                                Spacer().frame(height: 12)
                            }
                            ForEach(panes) { pane in row(pane) }
                        }
                    }
                    if SettingsPane.allCases.allSatisfy({ !$0.matches(query) }) {
                        Text("没有匹配的设置").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 10)
        .padding(.top, 44) // traffic lights
        .padding(.bottom, 12)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(10)
        .onSubmit {
            if let first = SettingsPane.allCases.first(where: { $0.matches(query) }) { model.settingsPane = first }
        }
    }

    private func row(_ pane: SettingsPane) -> some View {
        let selected = model.settingsPane == pane
        return Button { model.settingsPane = pane } label: {
            HStack(spacing: 11) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(LinearGradient(colors: pane.tile, startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(pane.title).font(.system(size: 14, weight: selected ? .bold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.12)))
                }
            }
        }
        .buttonStyle(.plain)
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

    /// Soft brand light behind the glass, like the search page.
    private var ambient: some View {
        ZStack {
            Rectangle().fill(.background)
            Circle().fill(Color.hongguoRed.opacity(0.28)).frame(width: 520).offset(x: -320, y: -260)
            Circle().fill(Color.purple.opacity(0.22)).frame(width: 480).offset(x: 300, y: 260)
        }
        .blur(radius: 110)
        .ignoresSafeArea()
    }
}

private extension View {
    /// Hides the window title and lets the content run under the title bar where the OS allows it.
    @ViewBuilder
    func settingsWindowChrome() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbar(removing: .title).toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            self // macOS 14: the title bar keeps its title; .title removal needs macOS 15.
        }
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

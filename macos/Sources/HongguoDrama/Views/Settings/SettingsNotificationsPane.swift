import SwiftUI
import UserNotifications
import HongguoCore

/// 追更与通知: new-episode and sequel checks, how often, system notifications, announcements.
struct SettingsNotificationsPane: View {
    @Environment(AppModel.self) private var model
    @State private var announcementPrefs = AnnouncementService.State()
    @State private var announcementNote = ""
    @State private var checkNote = ""
    @State private var notificationNote = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("追更") {
                Toggle(isOn: $model.settings.watchUpdatesEnabled) {
                    SettingLabel("检查已看剧集的更新", note: "没看完的剧有新集时，在观看记录里标出。")
                }
                Toggle(isOn: $model.settings.watchSequelsEnabled) {
                    SettingLabel("检查续作", note: "看过的剧出了第二部、第三部时提醒。")
                }
                .disabled(!model.settings.watchUpdatesEnabled)
                Picker("检查频率", selection: $model.settings.watchCheckHours) {
                    ForEach(AppSettings.watchCheckChoices, id: \.self) { hours in
                        Text(hours == 24 ? "每天" : "每 \(hours) 小时").tag(hours)
                    }
                }
                .disabled(!model.settings.watchUpdatesEnabled)
                Toggle(isOn: Binding(get: { model.settings.watchNotifications }, set: { setNotifications($0) })) {
                    SettingLabel("发送系统通知", note: notificationNote.isEmpty ? "有更新时在通知中心提醒。只在 App 打开时检查。" : notificationNote)
                }
                .disabled(!model.settings.watchUpdatesEnabled)
                LabeledContent {
                    Button(model.watchChecking ? "检查中…" : "立即检查") { checkNow() }
                        .disabled(model.watchChecking || !model.settings.watchUpdatesEnabled)
                } label: {
                    SettingLabel("现在检查全部", note: checkNote)
                }
            }

            Section("公告") {
                Toggle("显示普通公告", isOn: Binding(get: { announcementPrefs.normalEnabled },
                                                 set: { setAnnouncements(normal: $0) }))
                Toggle(isOn: Binding(get: { announcementPrefs.emergencyEnabled }, set: { setAnnouncements(emergency: $0) })) {
                    SettingLabel("显示紧急公告", note: "例如接口失效、需要更新的提醒。")
                }
                LabeledContent {
                    Button("查看") {
                        Task { announcementNote = await model.showCurrentAnnouncement() ? "" : "目前没有公告" }
                    }
                } label: {
                    SettingLabel("当前公告", note: announcementNote)
                }
            }
        }
        .task { announcementPrefs = await model.announcements.preferences }
    }

    private func setNotifications(_ on: Bool) {
        guard on else {
            model.settings.watchNotifications = false
            notificationNote = ""
            return
        }
        Task {
            let granted = await AppModel.requestNotificationPermission()
            model.settings.watchNotifications = granted
            notificationNote = granted ? "" : "通知权限被关闭了，请在“系统设置 › 通知 › 红果短剧”里打开。"
        }
    }

    private func checkNow() {
        checkNote = ""
        Task {
            guard let summary = await model.checkWatchUpdates(force: true) else { return }
            var text = "检查了 \(summary.checked) 部"
            text += summary.withUpdates > 0 ? "，\(summary.withUpdates) 部有更新" : "，都没有新内容"
            if summary.failed > 0 { text += "，\(summary.failed) 部失败" }
            checkNote = text
        }
    }

    private func setAnnouncements(normal: Bool? = nil, emergency: Bool? = nil) {
        Task {
            do {
                try await model.announcements.setPreferences(normalEnabled: normal, emergencyEnabled: emergency)
                announcementNote = ""
            } catch {
                announcementNote = (error as? HongguoError)?.message ?? "保存失败"
            }
            announcementPrefs = await model.announcements.preferences
        }
    }
}

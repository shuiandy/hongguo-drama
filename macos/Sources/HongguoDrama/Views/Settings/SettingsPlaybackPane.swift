import SwiftUI
import HongguoCore

/// 播放: auto-next, next-episode preparation, quality, picture mode, speed and volume.
struct SettingsPlaybackPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("连播") {
                Toggle(isOn: $model.settings.autoNext) {
                    SettingLabel("自动播放下一集", note: "播放器里按 A 也可以临时切换。")
                }
                Toggle(isOn: $model.settings.cacheNextEpisode) {
                    SettingLabel("预先准备下一集", note: "播放时在后台下载并解密下一集，切集不用等待。")
                }
            }

            Section("画面") {
                LabeledContent {
                    Picker("画质偏好", selection: Binding(get: { model.settings.preferredQuality },
                                                       set: { setQuality($0) })) {
                        Text("自动").tag(Int?.none)
                        Text("1080P").tag(Int?.some(1080))
                        Text("720P").tag(Int?.some(720))
                        Text("540P").tag(Int?.some(540))
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } label: {
                    SettingLabel("画质偏好", note: "没有该画质时自动选最接近的。下载也按这个画质。")
                }
                LabeledContent {
                    Picker("默认画面模式", selection: $model.settings.defaultPictureMode) {
                        ForEach(PictureMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } label: {
                    SettingLabel("默认画面模式", note: "新剧使用这个模式。在播放器里改过的剧会单独记住。")
                }
                if !model.settings.pictureModes.isEmpty {
                    LabeledContent {
                        Button("全部恢复默认") { model.settings.pictureModes = [:] }
                    } label: {
                        SettingLabel("单独记住的剧", note: "\(model.settings.pictureModes.count) 部剧用了自己的画面模式。")
                    }
                }
            }

            Section("速度与声音") {
                Toggle("记住播放速度", isOn: $model.settings.rememberSpeed)
                Toggle("长按空格临时 2 倍速", isOn: $model.settings.holdToSpeedUp)
                LabeledContent("S / D 调速步长") {
                    Picker("S / D 调速步长", selection: $model.settings.speedStep) {
                        ForEach(PlaybackRate.speedSteps, id: \.self) { Text(PlaybackRate.label($0)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Picker(selection: $model.settings.startVolume) {
                    Text("上次的音量").tag(Int?.none)
                    ForEach(AppSettings.startVolumes, id: \.self) { Text("\($0)%").tag(Int?.some($0)) }
                } label: {
                    SettingLabel("打开播放器时的音量", note: "选“上次的音量”会延续上次关闭时的设置。")
                }
            }
        }
    }

    /// Goes through the player so the episode that is playing switches tier too.
    private func setQuality(_ value: Int?) {
        PlayerController.shared.preferredQuality = value
        model.settings.preferredQuality = value
    }
}

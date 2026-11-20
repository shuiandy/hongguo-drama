import SwiftUI
import HongguoCore

/// 片源: built-in switches and custom endpoints (SourcesSettingsSection), plus search behaviour.
struct SettingsSourcesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            SourcesSettingsSection()
            Section("搜索") {
                Toggle(isOn: $model.settings.searchOtherSources) {
                    SettingLabel("搜索时同时查找其他片源", note: "在红果结果下面按片源分组显示，只查已开启的片源。")
                }
            }
        }
    }
}

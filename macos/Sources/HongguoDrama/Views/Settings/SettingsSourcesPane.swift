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
                Toggle(isOn: $model.settings.searchAppFirst) {
                    SettingLabel("红果 App 搜索优先", note: "先用红果 App 搜索，结果不对题或失败时自动改用官网搜索。官网没有完全同名的剧时，还会从 App 近 7 天上新补搜。")
                }
            }
        }
    }
}

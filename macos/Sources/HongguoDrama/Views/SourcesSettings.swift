import SwiftUI
import HongguoCore
import MediaSources

/// 片源 settings: built-in source switches and custom Apple CMS endpoints. Embedded in a Form.
struct SourcesSettingsSection: View {
    @Environment(AppModel.self) private var model
    private var sources = SourceSettingsStore.shared
    @State private var editing: CustomSourceConfig?
    @State private var message = ""

    var body: some View {
        Section {
            ForEach(MediaSources.builtin, id: \.id) { entry in
                if entry.id == "hongguo" {
                    LabeledContent(entry.label, value: "始终开启")
                } else {
                    Toggle(entry.label, isOn: Binding(get: { isOn(entry) }, set: { setBuiltin(entry.id, $0) }))
                }
            }
        } header: {
            Text("内置片源")
        } footer: {
            Text("开启的片源会出现在侧边栏「其他片源」里，可以浏览、搜索和播放。海外片源默认关闭，内容为英文。")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            if sources.value.customSources.isEmpty {
                Text("还没有自定义接口").foregroundStyle(.secondary)
            }
            ForEach(sources.value.customSources) { source in
                HStack {
                    Toggle(isOn: Binding(get: { source.enabled }, set: { value in
                        var copy = source
                        copy.enabled = value
                        save(copy)
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            Text(source.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Button("编辑") { editing = source }
                    Button(role: .destructive) { remove(source) } label: { Image(systemName: "trash") }
                        .help("删除这个接口")
                }
            }
            Button { editing = CustomSourceConfig(name: "", url: "https://") } label: { Label("添加接口…", systemImage: "plus") }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("自定义接口")
        } footer: {
            Text("支持苹果 CMS 格式的公开接口（/api.php/provide/vod/），只接受 HTTPS 公网地址。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { draft in
            CustomSourceEditor(draft: draft) { saved in save(saved) }
        }
    }

    private func isOn(_ entry: MediaSources.Entry) -> Bool {
        let value = sources.value.builtinSources[entry.id]
        return entry.optIn ? value == true : value != false
    }

    private func setBuiltin(_ id: String, _ enabled: Bool) {
        do {
            try sources.value.setBuiltinSource(id, enabled: enabled)
            message = ""
        } catch {
            message = (error as? HongguoError)?.message ?? describe(error)
        }
    }

    private func save(_ source: CustomSourceConfig) {
        do {
            try sources.value.saveCustomSource(source)
            message = ""
        } catch {
            message = (error as? HongguoError)?.message ?? describe(error)
        }
    }

    private func remove(_ source: CustomSourceConfig) {
        do {
            try sources.value.removeCustomSource(id: source.id)
            if model.selection == .source("custom:\(source.id)") { model.selection = .category(.realDrama) }
            message = ""
        } catch {
            message = (error as? HongguoError)?.message ?? describe(error)
        }
    }
}

/// Add or edit one custom endpoint, with a connection test before saving.
struct CustomSourceEditor: View {
    @State var draft: CustomSourceConfig
    let onSave: (CustomSourceConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var result = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.id.isEmpty ? "添加自定义接口" : "编辑自定义接口").font(.headline)
            Form {
                TextField("名称", text: $draft.name)
                TextField("接口地址", text: $draft.url)
                Toggle("启用", isOn: $draft.enabled)
            }
            .formStyle(.grouped)
            if !result.isEmpty { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
            HStack {
                Button(testing ? "测试中…" : "测试连接") { test() }.disabled(testing)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        _ = try CustomSource.validate(draft)
                        onSave(draft)
                        dismiss()
                    } catch {
                        self.error = (error as? HongguoError)?.message ?? describe(error)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func test() {
        testing = true
        result = ""
        error = ""
        let value = draft
        Task {
            defer { testing = false }
            do {
                let outcome = try await CustomSource.test(value)
                result = "连接成功：第一页 \(outcome.count) 部，\(outcome.genres.count) 个分类"
            } catch {
                self.error = (error as? HongguoError)?.message ?? describe(error)
            }
        }
    }
}

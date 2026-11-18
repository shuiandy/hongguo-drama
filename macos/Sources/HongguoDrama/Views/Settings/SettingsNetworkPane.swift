import SwiftUI
import HongguoCore

/// 网络: direct connection (default), system proxy, or a manual HTTP / SOCKS5 proxy, with a
/// connection test. Changes apply when saved; the password is kept in the keychain.
struct SettingsNetworkPane: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ProxySettings()
    @State private var portText = ""
    @State private var password = ""
    @State private var passwordEdited = false
    @State private var status = ""
    @State private var statusIsError = false
    @State private var testing = false
    @State private var loaded = false

    var body: some View {
        Form {
            if let error = model.proxyStartupError {
                Section {
                    Label("已保存的代理无法使用，本次启动改为直连：\(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("网络代理") {
                Picker(selection: $draft.mode) {
                    Text("直连（默认）").tag(ProxySettings.Mode.direct)
                    Text("跟随系统代理").tag(ProxySettings.Mode.system)
                    Text("手动设置").tag(ProxySettings.Mode.custom)
                } label: {
                    SettingLabel("连接方式", note: modeNote)
                }
                if draft.mode == .custom {
                    Picker("代理类型", selection: $draft.kind) {
                        Text("HTTP").tag(ProxySettings.Kind.http)
                        Text("SOCKS5").tag(ProxySettings.Kind.socks5)
                    }
                    .pickerStyle(.segmented)
                    TextField("地址", text: $draft.host, prompt: Text("127.0.0.1"))
                    TextField("端口", text: $portText, prompt: Text("7890"))
                        .onChange(of: portText) { _, value in draft.port = Int(value.filter(\.isNumber)) ?? 0 }
                    TextField("用户名（可选）", text: $draft.username)
                    SecureField("密码（可选，保存在钥匙串）", text: $password)
                        .onChange(of: password) { _, _ in passwordEdited = true }
                }
            }
            Section {
                HStack(spacing: 10) {
                    Button(testing ? "正在测试…" : "测试连接") { Task { await test() } }
                        .disabled(testing)
                    Button("保存并应用") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!changed)
                    Spacer()
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(statusIsError ? Color.red : Color.secondary)
                }
                Text("当前生效：\(NetworkProxy.shared.settings.summary)。代理只影响本应用的网络请求，正在进行的下载会在下一次请求时切换。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = model.settings.proxy
            portText = String(draft.port)
            password = ProxyKeychain.load() ?? ""
            passwordEdited = false
        }
    }

    private var modeNote: String {
        switch draft.mode {
        case .direct: return "所有请求直接连接。和 Surge、Clash 等的增强 / TUN 模式一起用时选这个即可。"
        case .system: return "使用系统设置 > 网络里配置的代理。"
        case .custom: return "填写代理软件提供的本机端口，例如 Clash 的 7890。"
        }
    }

    private var changed: Bool { draft != model.settings.proxy || passwordEdited }

    private func test() async {
        testing = true
        defer { testing = false }
        status = ""
        do {
            let seconds = try await NetworkProxy.test(draft, password: password)
            statusIsError = false
            status = String(format: "连接成功，红果官网响应用时 %.0f 毫秒", seconds * 1000)
        } catch {
            statusIsError = true
            status = describe(error)
        }
    }

    private func save() {
        do {
            try model.applyProxy(draft, password: passwordEdited ? password : nil)
            passwordEdited = false
            statusIsError = false
            status = "已保存，当前生效：\(draft.summary)"
        } catch {
            statusIsError = true
            status = "未保存：\(describe(error))"
        }
    }
}

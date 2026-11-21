import HongguoCore
import HongguoModels
import SwiftUI
import UIKit

/// 扫码登录: a large QR code for the 红果 App on a phone, the shared LoginModel's state line
/// (waiting, expired and swapping in a new code, signed in), 换一个二维码 and 跳过. The model polls
/// every two seconds and swaps an expired code by itself; leaving gives the code up.
struct LoginPage: View {
    @Environment(TVAppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var login: LoginModel?

    var body: some View {
        ZStack {
            AmbientBackground(tint: Theme.accent.opacity(0.6))
            HStack(spacing: 100) {
                code
                VStack(alignment: .leading, spacing: 28) {
                    Text("登录红果账号").font(.title.weight(.bold))
                    Text("用手机上已登录的红果 App 扫这个二维码，并在手机上确认。").foregroundStyle(.secondary)
                    if app.account.canSignIn {
                        Text((login?.phase ?? .loading).text).font(.headline)
                        Button("换一个二维码", systemImage: "arrow.clockwise") { login?.requestNewCode() }
                            .disabled(login?.phase == .loading || login?.phase == .done)
                    }
                    Button("跳过") { app.showsLogin = false }
                    Text("二维码几分钟后过期，过期会自动换一个。").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 700, alignment: .leading)
                .focusSection()
            }
        }
        .background(Color.black)
        .onExitCommand { app.showsLogin = false }
        .onAppear { if login == nil { login = LoginModel(client: app.account) } }
        .onDisappear { login?.abandon() }
        .task(id: "\(login?.round ?? -1)|\(scenePhase == .active)") {
            guard app.account.canSignIn, scenePhase == .active, let login else { return }
            await login.run { app.showsLogin = false }
        }
    }

    @ViewBuilder private var code: some View {
        if !app.account.canSignIn {
            VStack(spacing: 20) {
                Image(systemName: "wifi.slash").font(.system(size: 80)).foregroundStyle(.secondary)
                Text("示例数据下不能登录").font(.headline)
                Text("登录要连官方网站。去掉离线示例参数后再试。").foregroundStyle(.secondary)
            }
            .frame(width: 560, height: 560)
        } else if let qr = login?.qr, let image = UIImage(data: qr.image) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 520, height: 520)
                .padding(20)
                .background(.white, in: .rect(cornerRadius: 24))
                .opacity(login?.phase == .waiting ? 1 : 0.3)
                .accessibilityLabel("登录二维码")
        } else {
            ProgressView().controlSize(.large).frame(width: 560, height: 560)
        }
    }
}

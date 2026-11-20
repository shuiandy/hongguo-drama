import SwiftUI
import AppKit
import HongguoCore

/// Signed-in account shared by the sidebar badge and the account page.
@MainActor
@Observable
final class AccountState {
    static let shared = AccountState()

    var profile: AccountProfile? {
        didSet {
            guard profile?.id != oldValue?.id else { return }
            avatar = ""
            guard let id = profile?.id else { return }
            // Last known nickname and picture at once; the App profile refreshes them.
            if let cached = UserDefaults.standard.stringArray(forKey: Self.cacheKey(id)), cached.count == 2 {
                avatar = cached[1]
                if !cached[0].isEmpty, profile?.nickname != cached[0] { profile?.nickname = cached[0] }
            }
            Task { await loadAvatar() }
        }
    }
    /// The account's avatar address from the App profile ("" until known), cached per account.
    var avatar = ""
    @ObservationIgnored private var loadingAvatar = false

    private static func cacheKey(_ id: String) -> String { "account.display.\(id)" }
    var restoring = true
    var message = ""
    private var restoreStarted = false

    /// Restores the saved login once (the Keychain profile shows at once, the cookie is checked in the background).
    func restore() async {
        guard !restoreStarted else { return }
        restoreStarted = true
        // The background cookie check (or any later one) may find the login expired and drop it.
        NotificationCenter.default.addObserver(forName: AccountService.sessionExpiredNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sessionExpired() }
        }
        let status = await AccountService.shared.status()
        profile = status.profile
        message = status.error
        restoring = false
    }

    private func sessionExpired() {
        guard profile != nil else { return }
        profile = nil
        message = "登录已过期，请重新扫码登录"
    }

    /// Reads the App profile for the avatar (read only); a failure keeps the initial-letter circle.
    func loadAvatar() async {
        guard let id = profile?.id, !loadingAvatar else { return }
        loadingAvatar = true
        defer { loadingAvatar = false }
        // Right after launch the first signed request can fail while the device registers: retry a little.
        var found: AccountDataAccess.Profile?
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 3)) }
            if let details = try? await AccountDataAccess.profile() { found = details; break }
        }
        guard let details = found, profile?.id == id else { return }
        if !details.avatar.isEmpty { avatar = details.avatar }
        UserDefaults.standard.set([details.name, details.avatar], forKey: Self.cacheKey(id))
        // The saved nickname is often the placeholder "用户 <number>"; the App profile has the real one.
        let name = details.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != profile?.nickname { profile = AccountProfile(id: id, nickname: name) }
    }
}

/// The signed-in account's avatar, or the initial letter on a gradient when there is none.
struct AccountAvatar: View {
    var account: AccountState
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.54, blue: 0.58), .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            if let name = account.profile?.nickname, let first = name.first {
                Text(String(first)).font(.system(size: size * 0.42, weight: .heavy)).foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
            }
            if account.profile != nil, let url = URL(string: account.avatar), url.scheme == "https" {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }
}

/// 账号: QR login with the 红果短剧 App, the account's cloud watch history, sign out.
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var account = AccountState.shared
    @State private var qr: AccountLoginQR?
    @State private var qrState = ""
    @State private var loginTask: Task<Void, Never>?
    @State private var loginToken = UUID()
    @State private var history: [AccountHistoryItem] = []
    @State private var loadingHistory = false
    @State private var historyError = ""

    var body: some View {
        ScrollView {
            PageHeader(title: "账号", subtitle: account.profile.map { "已登录：\($0.nickname)" } ?? "未登录") {
                if account.profile != nil {
                    AccountAvatar(account: account, size: 34)
                    Button { Task { await loadHistory(refresh: true) } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .buttonStyle(GlassButtonStyle())
                        .disabled(loadingHistory)
                    Button(role: .destructive) { logout() } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)

            Group {
                if account.restoring {
                    ProgressView("正在恢复登录…").padding(.top, 60)
                } else if account.profile == nil {
                    loginCard
                } else {
                    historySection
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .navigationTitle("账号")
        .transparentToolbar()
        .task {
            await account.restore()
            if account.profile != nil { await loadHistory(refresh: false) }
        }
        .onDisappear { cancelLogin() }
    }

    // MARK: Login

    private var loginCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 34, weight: .semibold)).foregroundStyle(Color.hongguoRed)
            Text("用红果短剧 App 扫码登录").font(.system(size: 20, weight: .bold))
            Text("登录后可以看到你在手机上的云端观看记录。登录信息只保存在这台 Mac 的钥匙串里。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if let qr, let image = NSImage(data: qr.image) {
                Image(nsImage: image)
                    .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(qrState.isEmpty ? "打开红果短剧 App，用扫一扫扫描二维码，并在手机上确认" : qrState)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                HStack {
                    Button("刷新二维码") { startLogin() }.buttonStyle(GlassButtonStyle())
                    Button("取消") { cancelLogin(); self.qr = nil; qrState = "" }.buttonStyle(GlassButtonStyle())
                }
            } else {
                if !qrState.isEmpty { Text(qrState).font(.system(size: 13)).foregroundStyle(.secondary) }
                Button { startLogin() } label: { Label("获取登录二维码", systemImage: "qrcode") }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(loginTask != nil)
            }
            if !account.message.isEmpty {
                Text(account.message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 12)
    }

    private func startLogin() {
        cancelLogin()
        qrState = "正在获取二维码…"
        let token = UUID()
        loginToken = token
        loginTask = Task {
            defer { if loginToken == token { loginTask = nil } }
            do {
                let code = try await AccountService.shared.startLogin()
                guard !Task.isCancelled else { return }
                qr = code
                qrState = ""
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    switch try await AccountService.shared.pollLogin(code.loginId) {
                    case .pending: continue
                    case .expired:
                        qr = nil
                        qrState = "二维码已过期，请重新获取"
                        return
                    case .cancelled: return
                    case .signedIn(let profile, let warning):
                        qr = nil
                        qrState = ""
                        account.profile = profile
                        account.message = warning
                        await loadHistory(refresh: true)
                        await AccountSync.shared.pull()
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                qr = nil
                qrState = (error as? HongguoError)?.message ?? "登录失败，请稍后重试"
            }
        }
    }

    private func cancelLogin() {
        guard let task = loginTask else { return }
        task.cancel()
        loginTask = nil
        Task { await AccountService.shared.cancelLogin(qr?.loginId) }
    }

    private func logout() {
        cancelLogin()
        Task {
            let warning = await AccountService.shared.logout()
            AccountSync.shared.signedOut()
            account.profile = nil
            account.message = warning
            history = []
            historyError = ""
        }
    }

    // MARK: Cloud history

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("云端观看记录").font(.system(size: 17, weight: .bold)).padding(.top, 8)
            if loadingHistory && history.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else if !historyError.isEmpty && history.isEmpty {
                Text(historyError).foregroundStyle(.secondary).padding(.top, 20)
            } else if history.isEmpty {
                Text("这个账号还没有观看记录。").foregroundStyle(.secondary).padding(.top, 20)
            } else {
                if !historyError.isEmpty { Text(historyError).font(.system(size: 12)).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                    ForEach(history) { item in
                        CloudHistoryRow(item: item) { resume(item) }
                            .contextMenu {
                                Button("继续播放") { resume(item) }
                                Button("查看详情") {
                                    model.open(SeriesSummary(seriesId: item.seriesId, title: item.seriesTitle, cover: item.cover, episodeCount: item.total))
                                }
                            }
                    }
                }
            }
        }
    }

    private func loadHistory(refresh: Bool) async {
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            history = try await AccountService.shared.history(refresh: refresh)
            historyError = ""
            model.store.mergeCloudHistory(history)
            model.refreshHistory()
            // The background check may have dropped an expired login.
            let status = await AccountService.shared.status()
            if status.profile == nil { account.profile = nil; history = [] }
        } catch {
            historyError = (error as? HongguoError)?.message ?? "云端观看记录加载失败，请稍后重试"
        }
    }

    private func resume(_ item: AccountHistoryItem) {
        Task {
            await PlayerController.shared.resume(seriesId: item.seriesId, title: item.seriesTitle, cover: item.cover)
        }
    }
}

struct CloudHistoryRow: View {
    let item: AccountHistoryItem
    var resume: () -> Void = {}

    var body: some View {
        Button(action: resume) {
            HStack(spacing: 14) {
                CoverImage(url: item.cover, cornerRadius: 12).frame(width: 66, height: 88)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.seriesTitle).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Text(item.updatedAt, format: .relative(presentation: .named))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    if item.total > 0 {
                        ProgressView(value: Double(min(max(item.episodeIndex, 0), item.total)), total: Double(item.total))
                            .progressViewStyle(.linear).tint(.hongguoRed).controlSize(.mini)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(Color.hongguoRed)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .help("继续播放 \(item.seriesTitle)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if item.episodeIndex > 0 { parts.append("看到第 \(item.episodeIndex) 集" + (item.total > 0 ? " / 共 \(item.total) 集" : "")) }
        let time = formatTime(item.position)
        if !time.isEmpty { parts.append(time) }
        return parts.isEmpty ? "云端记录" : parts.joined(separator: " · ")
    }
}

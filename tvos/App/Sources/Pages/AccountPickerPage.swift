import HongguoCore
import HongguoModels
import SwiftUI

/// 选择账号: the accounts signed in on this Apple TV in a row of round pictures with their names,
/// like the system's own user picker (the focused one grows); the most recently used takes the
/// focus. 添加账号 opens the QR sign-in, 不登录使用 carries on signed out. Choosing one switches
/// the shared account (AccountRoster) and goes to 推荐. A long press removes an account from this
/// Apple TV only.
struct AccountPickerPage: View {
    @Environment(TVAppModel.self) private var app
    @FocusState private var focused: String?
    @State private var switching: String?

    private static let addId = "__add__"

    var body: some View {
        ZStack {
            AmbientBackground(tint: Theme.accent.opacity(0.5))
            VStack(spacing: 70) {
                Text("选择账号").font(.title.weight(.bold))
                HStack(spacing: 70) {
                    ForEach(app.roster.entries) { entry in
                        Button { choose(entry) } label: {
                            AvatarLabel(name: entry.nickname, avatar: entry.avatar, isCurrent: entry.id == app.roster.currentId,
                                        isBusy: switching == entry.id)
                        }
                        .buttonStyle(AvatarButtonStyle())
                        .focused($focused, equals: entry.id)
                        .contextMenu {
                            Button("从这台 Apple TV 移除", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                                Task { await app.roster.remove(entry, account: app.account) }
                            }
                        }
                    }
                    Button { app.showsLogin = true } label: {
                        AvatarLabel(name: "添加账号", systemImage: "plus")
                    }
                    .buttonStyle(AvatarButtonStyle())
                    .focused($focused, equals: Self.addId)
                }
                .focusSection()
                // A full-width section, so down from any picture reaches it.
                HStack {
                    Button("不登录使用") {
                        Task {
                            await app.roster.continueSignedOut(account: app.account)
                            app.finishAccountChoice()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .focusSection()
            }
        }
        .background(Color.black)
        .onAppear {
            // The account used last is the one most people want.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = app.roster.mostRecent?.id ?? Self.addId }
        }
        .onExitCommand { if app.account.isSignedIn || app.roster.currentId == nil { app.finishAccountChoice() } }
    }

    private func choose(_ entry: AccountRoster.Entry) {
        guard switching == nil else { return }
        if entry.id == app.roster.currentId, app.account.profile?.id == entry.id {
            app.finishAccountChoice()
            return
        }
        switching = entry.id
        Task {
            let ok = await app.roster.switchTo(entry, account: app.account)
            switching = nil
            if ok {
                app.finishAccountChoice()
            } else {
                // Its login is gone: sign in again for it.
                app.showsLogin = true
            }
        }
    }
}

/// A round picture (or a symbol) with a name under it.
private struct AvatarLabel: View {
    var name: String
    var avatar: String = ""
    var systemImage: String?
    var isCurrent = false
    var isBusy = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle().fill(PlaceholderTint.color(for: name).gradient)
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 80, weight: .medium)).foregroundStyle(.white)
                } else if let url = URL(string: avatar), !avatar.isEmpty {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { initial }
                        .clipShape(Circle())
                } else {
                    initial
                }
                if isBusy { ProgressView().controlSize(.large) }
            }
            .frame(width: 220, height: 220)
            .overlay { Circle().strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 6) }
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 20, y: 12)
            Text(name).font(.headline).lineLimit(1).frame(maxWidth: 260)
            Text(isCurrent ? "当前" : " ").font(.caption).foregroundStyle(.secondary)
        }
        .scaleEffect(isFocused ? 1.15 : 1)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }

    private var initial: some View {
        Text(String(name.prefix(1))).font(.system(size: 90, weight: .bold)).foregroundStyle(.white)
    }
}

/// No platter: the picture itself grows when focused.
private struct AvatarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

import SwiftUI
import HongguoCore

/// An actor's page: picture, name, the role in the series it was opened from and their
/// introduction (all from the series detail's cast), then their works from the App's actor works
/// read (one batch, as the official app shows it, with the total). A work opens its detail page.
struct CelebrityView: View {
    let member: EpisodeSocial.CastMember
    @Environment(AppModel.self) private var model

    @State private var works: [SeriesSummary] = []
    @State private var total: Int?
    @State private var loaded = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("作品").font(.system(size: 20, weight: .heavy))
                        if let total, total > 0 { Text("共 \(total) 部").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    if works.isEmpty {
                        if loaded {
                            ContentUnavailableView("暂无作品信息", systemImage: "film")
                        } else {
                            LoadStateView(error: error, isLoading: isLoading) { Task { await load() } }
                        }
                    } else {
                        PosterGrid(items: works)
                        if let total, total > works.count {
                            Text("红果只返回了其中 \(works.count) 部").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(alignment: .top) {
            if !member.avatar.isEmpty {
                AmbientBackdrop(url: member.avatar, blur: 80, opacity: 0.5)
                    .frame(height: 520)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
            }
        }
        .navigationTitle(member.name)
        .transparentToolbar()
        .task(id: member.id) { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            CoverImage(url: member.avatar, cornerRadius: 70)
                .frame(width: 140, height: 140)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
            VStack(alignment: .leading, spacing: 10) {
                Text(member.name)
                    .font(.system(size: 36, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                if !member.role.isEmpty { GlassTag(text: member.role, systemImage: "theatermasks") }
                if !member.intro.isEmpty {
                    Text(member.intro)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 4)
                        .frame(maxWidth: 760, alignment: .leading)
                        .textSelection(.enabled)
                        .onTapGesture { withAnimation { expanded.toggle() } }
                        .help(expanded ? "收起" : "展开全部")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await CelebrityService.works(of: member)
            works = result.items
            total = result.total
            loaded = true
        } catch {
            self.error = describe(error)
        }
    }
}

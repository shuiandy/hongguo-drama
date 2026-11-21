import SwiftUI
import HongguoCore

/// An actor's page, the official actor home page: picture, name, the role in the series it was
/// opened from and their introduction (from the series detail's cast), then the works tab (作品) of the
/// actor's 红果 account (`ActorHomeService`) with the server's sub tabs (全部, 剧作, 预约, 合集), opening
/// on the server's highlight (剧作) like the official app, sorted
/// 最新 (the server's order) or 最热 (by heat). Cards carry the heat on the cover and genre · N集
/// under the title. Clicking a released work plays it, as in the official app; a series not out yet
/// opens its detail page.
struct CelebrityView: View {
    let member: EpisodeSocial.CastMember
    @Environment(AppModel.self) private var model

    enum Order: String, CaseIterable, Identifiable {
        case latest = "最新", hottest = "最热"
        var id: String { rawValue }
    }

    @State private var home: ActorHome?
    @State private var subTab: Int?
    @State private var pages: [Int: ActorWorksPage] = [:]
    @State private var isLoading = false
    @State private var error: String?
    @State private var expanded = false
    @State private var order: Order = .latest

    private var worksTab: ActorHome.Tab? { home?.worksTab }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                worksSection
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
        .task(id: member.id) { await loadHome() }
        .task(id: subTab) { await loadPage() }
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

    private var worksSection: some View {
        let page = subTab.flatMap { pages[$0] }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(worksTab?.name ?? "作品").font(.system(size: 20, weight: .heavy))
                Spacer(minLength: 0)
                if let items = page?.items, items.count > 1 {
                    Picker("排序", selection: $order) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let subs = home?.worksSubTabs, subs.count > 1 { subTabBar(subs) }
            if let page {
                if !page.upcomingNote.isEmpty, let upcoming = home?.worksSubTabs.first(where: { $0.name == "预约" }), upcoming.type != subTab {
                    Button { subTab = upcoming.type } label: {
                        GlassTag(text: page.upcomingNote, systemImage: "calendar", trailingSystemImage: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
                if page.items.isEmpty {
                    ContentUnavailableView("暂无作品信息", systemImage: "film")
                } else {
                    // Series not out yet (预约) cannot play, so their cards open the detail page.
                    PosterGrid(items: order == .hottest ? ActorHomeService.hottestFirst(page.items) : page.items,
                               clickPlays: page.upcomingIds.isEmpty, heatOnCover: true) {
                        Task { await loadMore() }
                    }
                }
            } else if member.profileUserId.isEmpty {
                ContentUnavailableView("暂无作品信息", systemImage: "film")
            } else {
                LoadStateView(error: error, isLoading: isLoading) {
                    Task { if home == nil { await loadHome() } else { await loadPage() } }
                }
            }
        }
    }

    /// The server's sub tabs (全部, 预约, …) as chips, the selected one filled.
    private func subTabBar(_ subs: [ActorHome.Tab]) -> some View {
        HStack(spacing: 8) {
            ForEach(subs) { sub in
                let selected = sub.type == subTab
                Button { subTab = sub.type } label: {
                    Text(sub.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.hongguoRed : .secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(selected ? Color.hongguoRed.opacity(0.15) : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loadHome() async {
        guard home == nil, !member.profileUserId.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await ActorHomeService.home(userId: member.profileUserId)
            home = loaded
            guard let tab = loaded.worksTab else { error = "这位演员的主页没有作品"; return }
            subTab = (loaded.defaultSubTab ?? tab.subTabs.first)?.type ?? 0
        } catch {
            self.error = describe(error)
        }
    }

    /// The selected sub tab's first page, once; switching back shows what was read.
    private func loadPage() async {
        guard let tab = worksTab, let sub = subTab, pages[sub] == nil else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            pages[sub] = try await ActorHomeService.works(userId: member.profileUserId, tab: tab.type, subTab: sub)
        } catch {
            if subTab == sub { self.error = describe(error) }
        }
    }

    private func loadMore() async {
        guard let tab = worksTab, let sub = subTab, let page = pages[sub], page.hasMore, !page.cursor.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let next = try? await ActorHomeService.works(userId: member.profileUserId, tab: tab.type, subTab: sub, cursor: page.cursor) else { return }
        var merged = page
        let known = Set(page.items.map(\.seriesId))
        merged.items += next.items.filter { !known.contains($0.seriesId) }
        merged.cursor = next.cursor
        merged.hasMore = next.hasMore && !next.items.isEmpty
        pages[sub] = merged
    }
}

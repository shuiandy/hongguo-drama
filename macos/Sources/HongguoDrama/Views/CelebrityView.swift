import SwiftUI
import HongguoCore

/// An actor's page, laid out like the official actor panel: a row with the series' whole cast on
/// top (click to switch actor), then the selected actor's picture, name, role in the series and
/// introduction (all from the series detail's cast), then their works from the App's actor works
/// read (one batch, with the total). Clicking a work plays it, as in the official app; its context
/// menu opens the detail page.
struct CelebrityView: View {
    let member: EpisodeSocial.CastMember
    /// The series' cast the page was opened from; the switcher row shows when it has two or more.
    var cast: [EpisodeSocial.CastMember] = []
    @Environment(AppModel.self) private var model

    @State private var selectedId: String?
    @State private var works: [String: CelebrityWorks] = [:]
    @State private var loadingId: String?
    @State private var errors: [String: String] = [:]
    @State private var expanded = false

    private var selected: EpisodeSocial.CastMember {
        cast.first { $0.id == selectedId } ?? member
    }

    var body: some View {
        let current = selected
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if cast.count > 1 { castRow(current) }
                header(current)
                worksSection(current)
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(alignment: .top) {
            if !current.avatar.isEmpty {
                AmbientBackdrop(url: current.avatar, blur: 80, opacity: 0.5)
                    .frame(height: 520)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
            }
        }
        .navigationTitle(current.name)
        .transparentToolbar()
        .task(id: current.id) { await load(current) }
    }

    /// The series' cast, as the official panel's tag row: picture and name, the selected one ringed.
    private func castRow(_ current: EpisodeSocial.CastMember) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(cast) { person in
                        let isSelected = person.id == current.id
                        Button {
                            guard !isSelected else { return }
                            expanded = false
                            withAnimation(.easeInOut(duration: 0.2)) { selectedId = person.id }
                        } label: {
                            VStack(spacing: 6) {
                                CoverImage(url: person.avatar, cornerRadius: 26)
                                    .frame(width: 52, height: 52)
                                    .overlay {
                                        Circle().strokeBorder(isSelected ? Color.hongguoRed : .white.opacity(0.1), lineWidth: isSelected ? 2.5 : 1)
                                    }
                                Text(person.name)
                                    .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 68)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(person.id)
                        .help(person.role.isEmpty ? person.name : "\(person.name) · \(person.role)")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .onAppear { proxy.scrollTo(current.id, anchor: .center) }
        }
    }

    private func header(_ current: EpisodeSocial.CastMember) -> some View {
        HStack(alignment: .center, spacing: 24) {
            CoverImage(url: current.avatar, cornerRadius: 70)
                .frame(width: 140, height: 140)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
            VStack(alignment: .leading, spacing: 10) {
                Text(current.name)
                    .font(.system(size: 36, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                if !current.role.isEmpty { GlassTag(text: current.role, systemImage: "theatermasks") }
                if !current.intro.isEmpty {
                    Text(current.intro)
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

    @ViewBuilder
    private func worksSection(_ current: EpisodeSocial.CastMember) -> some View {
        let result = works[current.id]
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("作品").font(.system(size: 20, weight: .heavy))
                if let total = result?.total, total > 0 { Text("共 \(total) 部").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if let result {
                if result.items.isEmpty {
                    ContentUnavailableView("暂无作品信息", systemImage: "film")
                } else {
                    PosterGrid(items: result.items, clickPlays: true)
                    if let total = result.total, total > result.items.count {
                        Text("红果只返回了其中 \(result.items.count) 部").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            } else {
                LoadStateView(error: errors[current.id], isLoading: loadingId == current.id) { Task { await load(current) } }
            }
        }
    }

    /// One read per actor; switching back to an actor shows what was already read.
    private func load(_ person: EpisodeSocial.CastMember) async {
        guard works[person.id] == nil, loadingId != person.id else { return }
        loadingId = person.id
        errors[person.id] = nil
        defer { if loadingId == person.id { loadingId = nil } }
        do {
            works[person.id] = try await CelebrityService.works(of: person)
        } catch {
            errors[person.id] = describe(error)
        }
    }
}

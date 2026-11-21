import HongguoCore
import HongguoModels
import SwiftUI

/// An actor's page over the series page: picture, name, role and introduction, then the works tab
/// of the actor's home page (the shared CelebrityModel: the server's sub tabs, one list each, more
/// as the focus nears the end). A work out already plays; one not out yet opens its series page.
/// Back closes it. Offline there is no home page.
struct CelebrityPage: View {
    @Environment(TVAppModel.self) private var app
    let member: EpisodeSocial.CastMember
    var tint: Color
    let close: () -> Void
    @State private var model: CelebrityModel

    init(member: EpisodeSocial.CastMember, tint: Color, close: @escaping () -> Void) {
        self.member = member
        self.tint = tint
        self.close = close
        _model = State(initialValue: CelebrityModel(member: member))
    }

    private static let columns = Array(repeating: GridItem(.fixed(PosterMetrics.width), spacing: 40, alignment: .top), count: 6)

    var body: some View {
        ZStack {
            AmbientBackground(tint: tint)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 36) {
                    HStack(spacing: 40) {
                        AsyncImage(url: URL(string: member.avatar)) { $0.resizable().scaledToFill() } placeholder: {
                            Image(systemName: "person.fill").font(.system(size: 70)).foregroundStyle(.secondary)
                        }
                        .frame(width: 180, height: 180)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 12) {
                            Text(member.name).font(.title.weight(.bold))
                            if !member.role.isEmpty { Text(member.role).foregroundStyle(.secondary) }
                            if !member.intro.isEmpty { Text(member.intro).font(.callout).foregroundStyle(.secondary).lineLimit(4) }
                        }
                    }
                    works
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
            }
            .scrollClipDisabled()
        }
        .background(Color.black)
        .onExitCommand(perform: close)
        .task(id: member.id) { await model.loadHome(using: app.backend) }
        .task(id: model.listKey) { if let key = model.listKey { await model.loadList(key, using: app.backend) } }
    }

    @ViewBuilder private var works: some View {
        if app.backend.isOffline || member.profileUserId.isEmpty {
            Text("暂无作品信息").foregroundStyle(.secondary)
        } else if model.home == nil {
            if let error = model.homeError {
                LoadStateView(state: .failed(error)) { Task { await model.loadHome(using: app.backend, retry: true) } }.frame(height: 400)
            } else {
                LoadStateView(state: .loading).frame(height: 400)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                if model.subTabs.count > 1 {
                    HStack(spacing: 20) {
                        ForEach(model.subTabs) { tab in
                            Button(tab.name) { model.selectedSub = tab.type }
                                .font(.callout.weight(tab.type == model.selectedSub ? .bold : .regular))
                        }
                    }
                    .focusSection()
                }
                if let key = model.listKey {
                    if let page = model.pages[key] {
                        let items = page.items
                        if items.isEmpty {
                            Text("暂无作品信息").foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 40) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, series in
                                    PosterCard(series: series, onFocus: {
                                        if index >= items.count - 6, page.hasMore {
                                            Task { await model.loadMore(key, using: app.backend) }
                                        }
                                    }) {
                                        if page.upcomingIds.contains(series.seriesId) { app.openDetail(series) } else { app.openPlayer(series) }
                                    }
                                }
                            }
                        }
                    } else if let error = model.errors[key] {
                        LoadStateView(state: .failed(error)) { Task { await model.loadList(key, using: app.backend, retry: true) } }
                            .frame(height: 400)
                    } else {
                        LoadStateView(state: .loading).frame(height: 400)
                    }
                }
            }
        }
    }
}

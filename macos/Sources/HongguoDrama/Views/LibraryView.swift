import SwiftUI
import HongguoCore

/// 我的剧库: favorited series first, then everything opened recently.
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "我的剧库", subtitle: subtitle) {
                    HeaderSearchField()
                }
                if model.favorites.isEmpty && model.recentSeries.isEmpty {
                    ContentUnavailableView("剧库还是空的", systemImage: "heart",
                                           description: Text("在详情页点"收藏"，喜欢的剧会出现在这里；打开过的剧也会自动记下。"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    if !model.favorites.isEmpty {
                        section("收藏", detail: "\(model.favorites.count) 部", items: model.favorites)
                    }
                    let recent = model.recentSeries.filter { !$0.favorite }
                    if !recent.isEmpty {
                        section("最近打开", detail: "按打开时间", items: recent)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(alignment: .top) {
            if let cover = (model.favorites.first ?? model.recentSeries.first)?.cover, !cover.isEmpty {
                AmbientBackdrop(url: cover, opacity: 0.45)
                    .frame(height: 520)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .extendsUnderChrome()
                    .ignoresSafeArea()
            }
        }
        .navigationTitle("我的剧库")
        .transparentToolbar()
        .onAppear { model.refreshLibrary() }
    }

    private var subtitle: String {
        "收藏 \(model.favorites.count) 部 · 最近打开 \(model.recentSeries.count) 部"
    }

    private func section(_ title: String, detail: String, items: [LibrarySeries]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 20, weight: .heavy))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 18)], alignment: .leading, spacing: 24) {
                ForEach(items) { item in
                    PosterCell(item: item.summary)
                }
            }
        }
    }
}

extension LibrarySeries {
    var summary: SeriesSummary {
        SeriesSummary(seriesId: seriesId, title: title, cover: cover, episodeCount: episodeCount, publishedAt: publishedAt)
    }
}

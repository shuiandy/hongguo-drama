import HongguoCore
import SwiftUI

// Placeholder pages for the six tabs. They show the shared parts (poster card, shelf, ambient
// background, load states) with offline sample rows; each page gets its real model as the
// shared models land in HongguoKit.

/// Offline sample rows in the same shape as the iOS app's FixtureBackend, until that backend
/// moves into the shared package.
enum TVSamples {
    static let titles = ["重生之我在豪门当保姆", "闪婚后发现老公是总裁", "离婚后她惊艳了全世界", "我的师父是剑仙",
                         "千金归来", "逆袭从退婚开始", "深宫谋", "都市最强赘婿", "她的秘密花园", "龙王殿",
                         "萌宝助攻：爹地快追妈咪", "星辰大海与你"]
    static let tags = [["逆袭", "都市"], ["甜宠", "闪婚"], ["大女主", "虐恋"], ["玄幻", "热血"], ["豪门", "复仇"], ["古装", "权谋"]]

    static func row(_ prefix: String, count: Int = 12) -> [SeriesSummary] {
        (1...count).map { index in
            let n = (index - 1) % titles.count
            return SeriesSummary(seriesId: "\(prefix)-\(index)", title: titles[n], episodeCount: 60 + n * 5,
                                 tags: tags[n % tags.count], rank: index,
                                 heat: "\(980 - n * 37).\(n % 10)万热度", episodeLabel: "全\(60 + n * 5)集",
                                 completionStatus: .completed)
        }
    }
}

private struct SampleShelves: View {
    let shelves: [(String, [SeriesSummary])]
    var showsRank = false
    @State private var focusedTint = Color.gray

    var body: some View {
        ZStack {
            AmbientBackground(tint: focusedTint)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    ForEach(shelves, id: \.0) { title, items in
                        Shelf(title: title, items: items, showsRank: showsRank)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
        }
        .onAppear { focusedTint = PlaceholderTint.color(for: shelves.first?.1.first?.seriesId ?? "") }
    }
}

struct RecommendPage: View {
    @Environment(TVAppModel.self) private var app

    var body: some View {
        if app.launch.offlineFixtures {
            let first = TVSamples.row("recommend", count: 1)[0]
            ZStack {
                AmbientBackground(tint: PlaceholderTint.color(for: first.seriesId))
                HStack(spacing: 80) {
                    // Where the 9:16 player goes: full height, centred, never cropped.
                    PosterImage(series: first)
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .frame(maxHeight: 760)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(first.title).font(.title2.weight(.bold))
                        Text("\(first.episodeLabel) · \(first.heat)").foregroundStyle(.secondary)
                        Text("离线样例，没有视频画面").font(.callout).foregroundStyle(.tertiary)
                        Button("观看完整剧集", systemImage: "play.fill") {}
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                }
            }
        } else {
            LoadStateView(state: .empty("推荐刷剧即将上线"))
        }
    }
}

struct TheaterPage: View {
    @Environment(TVAppModel.self) private var app

    var body: some View {
        if app.launch.offlineFixtures {
            SampleShelves(shelves: [("热播", TVSamples.row("hot")), ("新剧", TVSamples.row("new")),
                                    ("完结", TVSamples.row("done"))])
        } else {
            LoadStateView(state: .empty("剧场即将上线"))
        }
    }
}

struct RankingPage: View {
    @Environment(TVAppModel.self) private var app

    var body: some View {
        if app.launch.offlineFixtures {
            SampleShelves(shelves: [("热播榜", TVSamples.row("rank-hot")), ("新剧榜", TVSamples.row("rank-new"))],
                          showsRank: true)
        } else {
            LoadStateView(state: .empty("排行即将上线"))
        }
    }
}

struct FollowingPage: View {
    var body: some View {
        LoadStateView(state: .empty("还没有在追的剧"))
    }
}

struct SearchPage: View {
    var body: some View {
        LoadStateView(state: .loading)
    }
}

struct MePage: View {
    var body: some View {
        LoadStateView(state: .failed("我的页面即将上线：扫码登录、观看历史和设置"), retry: {})
    }
}

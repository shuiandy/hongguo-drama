import HongguoCore
import HongguoModels
import SwiftUI

/// 新剧推荐 and 追剧日历, opened from 剧场: the shared NewDramaModel and CalendarModel (the iOS
/// pages' models). 新剧 is a poster grid by gender; 日历 is the days around today, a content
/// filter and the day's series, each with 预约 (the shared library's reservation, kept on this
/// device and, signed in, queued for the account). Back closes it.
struct NewReleasesPage: View {
    enum Tab: Hashable { case recommended, calendar }

    @Environment(TVAppModel.self) private var app
    @State var tab: Tab
    let close: () -> Void
    @State private var news: NewDramaModel?
    @State private var calendar: CalendarModel?
    @FocusState private var focusedTab: Tab?

    private static let columns = Array(repeating: GridItem(.fixed(PosterMetrics.width), spacing: 40, alignment: .top), count: 6)

    var body: some View {
        ZStack {
            AmbientBackground(tint: Theme.accent.opacity(0.4))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 30) {
                        Button { tab = .recommended } label: { Text("新剧推荐").fontWeight(tab == .recommended ? .bold : .regular) }
                            .focused($focusedTab, equals: .recommended)
                        Button { tab = .calendar } label: { Text("追剧日历").fontWeight(tab == .calendar ? .bold : .regular) }
                            .focused($focusedTab, equals: .calendar)
                    }
                    .focusSection()
                    if tab == .recommended, let news { recommended(news) }
                    if tab == .calendar, let calendar { calendarView(calendar) }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 50)
            }
            .scrollClipDisabled()
        }
        .background(Color.black)
        .onExitCommand(perform: close)
        .onAppear {
            if news == nil { news = NewDramaModel(backend: app.backend) }
            if calendar == nil { calendar = CalendarModel(backend: app.backend) }
            // Over 剧场, nothing hands the focus over by itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focusedTab = tab }
        }
    }

    // MARK: 新剧推荐

    @ViewBuilder private func recommended(_ news: NewDramaModel) -> some View {
        Group {
            switch news.phase {
            case .failed(let message) where news.items.isEmpty:
                LoadStateView(state: .failed(message)) { Task { await news.load() } }.frame(height: 500)
            case .loading where news.items.isEmpty, .idle:
                LoadStateView(state: .loading).frame(height: 500)
            default:
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 40) {
                    ForEach(Array(news.items.enumerated()), id: \.element.seriesId) { index, item in
                        let series = SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover,
                                                   episodeCount: item.episodeCount, heat: item.heatText, episodeLabel: item.subtitle)
                        PosterCard(series: series, onFocus: {
                            if index >= news.items.count - 6, news.hasMore { Task { await news.loadMore() } }
                        }) { app.openDetail(series) }
                    }
                }
            }
        }
        .task(id: news.gender) { await news.load() }
    }

    // MARK: 追剧日历

    @ViewBuilder private func calendarView(_ calendar: CalendarModel) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(calendar.days) { day in
                        Button { calendar.selectedDate = day.targetDate } label: {
                            VStack(spacing: 4) {
                                Text(day.isToday ? "今天" : day.subtitle).font(.caption)
                                Text(day.monthDay).font(.headline.weight(day.targetDate == calendar.selectedDate ? .bold : .regular))
                            }
                            .frame(width: 110)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollClipDisabled()
            .focusSection()
            HStack(spacing: 20) {
                ForEach(CalendarContentFilter.allCases, id: \.self) { filter in
                    Button(filter.label) { calendar.filter = filter }
                        .font(.callout.weight(filter == calendar.filter ? .bold : .regular))
                }
            }
            .focusSection()
            let rows = calendar.filtered
            switch calendar.phase {
            case .failed(let message) where rows.isEmpty:
                LoadStateView(state: .failed(message)) { Task { await calendar.load() } }.frame(height: 400)
            case .loading where rows.isEmpty, .idle:
                LoadStateView(state: .loading).frame(height: 400)
            default:
                if rows.isEmpty {
                    LoadStateView(state: .empty("这一天没有上新")).frame(height: 400)
                } else {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 40) {
                        ForEach(Array(rows.enumerated()), id: \.element.seriesId) { index, item in
                            calendarCard(item, isLast: index >= rows.count - 6, calendar: calendar)
                        }
                    }
                }
            }
        }
        .task(id: calendar.selectedDate) { await calendar.load() }
    }

    private func calendarCard(_ item: DiscoveryAccess.CalendarItem, isLast: Bool, calendar: CalendarModel) -> some View {
        let series = SeriesSummary(seriesId: item.seriesId, title: item.title, cover: item.cover, episodeCount: item.episodeCount,
                                   heat: item.heatText,
                                   episodeLabel: item.isOnline ? "已上线" : SeriesDetailModel.upcomingLabel)
        let reserved = app.library.isReserved(item.seriesId)
        return VStack(alignment: .leading, spacing: 12) {
            PosterCard(series: series, onFocus: {
                if isLast, calendar.hasMore { Task { await calendar.loadMore() } }
            }) {
                if item.isOnline { app.openPlayer(series) } else { app.openDetail(series) }
            }
            if !item.isOnline {
                Button {
                    app.library.toggleReservation(seriesId: item.seriesId, title: item.title, cover: item.cover)
                } label: {
                    Label(reserved ? "已预约" : "预约", systemImage: reserved ? "bell.fill" : "bell").font(.caption)
                }
            }
        }
    }
}

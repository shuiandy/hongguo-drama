import HongguoCore
import SwiftUI

/// A titled horizontal row of posters. The scroll view does not clip, so a focused card can
/// grow past the row's edges.
struct Shelf: View {
    let title: String
    let items: [SeriesSummary]
    var showsRank = false
    /// Watched share per series, for 追剧.
    var progress: [String: Double] = [:]
    /// Opens the series page unless given something else.
    var onSelect: ((SeriesSummary) -> Void)? = nil
    /// A card took the focus.
    var onFocus: ((SeriesSummary) -> Void)? = nil
    /// The focus reached one of the last cards: time to load more.
    var onNearEnd: (() -> Void)? = nil
    @Environment(TVAppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !title.isEmpty {
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: PosterMetrics.spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, series in
                        PosterCard(series: series, rank: showsRank ? (series.rank ?? offset + 1) : nil,
                                   progress: progress[series.seriesId],
                                   onFocus: {
                                       onFocus?(series)
                                       if offset >= items.count - 4 { onNearEnd?() }
                                   }) {
                            if let onSelect { onSelect(series) } else { app.openDetail(series) }
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

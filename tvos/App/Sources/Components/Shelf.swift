import HongguoCore
import SwiftUI

/// A titled horizontal row of posters. The scroll view does not clip, so a focused card can
/// grow past the row's edges.
struct Shelf: View {
    let title: String
    let items: [SeriesSummary]
    var showsRank = false
    /// Opens the series page unless given something else.
    var onSelect: ((SeriesSummary) -> Void)? = nil
    @Environment(TVAppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: PosterMetrics.spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, series in
                        PosterCard(series: series, rank: showsRank ? (series.rank ?? offset + 1) : nil) {
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

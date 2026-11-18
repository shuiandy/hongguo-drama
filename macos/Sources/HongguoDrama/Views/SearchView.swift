import SwiftUI
import HongguoCore

/// Keyword search. A pasted share link, `series_id=...` text or a bare id opens the series directly.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var submitted = ""
    @State private var items: [SeriesSummary] = []
    @State private var page = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if submitted.isEmpty {
                    if !model.settings.searchHistory.isEmpty {
                        HStack {
                            Text("最近搜索").font(.headline)
                            Spacer()
                            Button("清空") { model.settings.searchHistory = [] }.buttonStyle(.link)
                        }
                        FlowLayout(spacing: 6) {
                            ForEach(model.settings.searchHistory, id: \.self) { keyword in
                                Button(keyword) { query = keyword; Task { await submit() } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    Text("输入剧名搜索，或粘贴红果分享链接、剧集编号直接打开。")
                        .foregroundStyle(.secondary)
                } else if items.isEmpty {
                    if isLoading || error != nil {
                        LoadStateView(error: error, isLoading: isLoading) { Task { await submit() } }
                    } else {
                        ContentUnavailableView.search(text: submitted)
                    }
                } else {
                    PosterGrid(items: items) { Task { await loadMore() } }
                    if isLoading { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .padding(20)
        }
        .navigationTitle(submitted.isEmpty ? "搜索" : "“\(submitted)”")
        .searchable(text: $query, placement: .toolbar, prompt: "剧名、分享链接或剧集编号")
        .onSubmit(of: .search) { Task { await submit() } }
    }

    private func looksLikeLink(_ text: String) -> Bool {
        text.range(of: "https?://|series_id", options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: "^\\d{6,30}$", options: .regularExpression) != nil
    }

    private func submit() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        error = nil
        if looksLikeLink(text) {
            isLoading = true
            submitted = text
            defer { isLoading = false }
            do {
                let id = try await model.series.resolveSeriesId(text)
                model.open(SeriesSummary(seriesId: id, title: "剧集 \(id)"))
                submitted = ""
            } catch {
                self.error = describe(error)
            }
            return
        }
        submitted = SearchService.normalizeKeyword(text)
        model.rememberSearch(submitted)
        items = []
        page = 0
        hasMore = false
        await load(page: 1)
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        await load(page: page + 1)
    }

    private func load(page target: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await model.search.search(submitted, page: target)
            let known = Set(items.map(\.id))
            items += result.results.filter { !known.contains($0.id) }
            page = result.page
            hasMore = result.hasMore || (result.totalPages > result.page)
        } catch {
            self.error = describe(error)
        }
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

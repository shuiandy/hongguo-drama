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

    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                PageHeader(title: "搜索", subtitle: "剧名、演员，或粘贴红果分享链接、剧集编号") { EmptyView() }
                searchField
                    .frame(maxWidth: 680)
                    .padding(.top, 8)

                if submitted.isEmpty {
                    idleContent.frame(maxWidth: 680, alignment: .leading)
                } else if items.isEmpty {
                    if isLoading || error != nil {
                        LoadStateView(error: error, isLoading: isLoading) { Task { await submit() } }
                    } else {
                        ContentUnavailableView.search(text: submitted)
                    }
                } else {
                    results
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) {
            // Soft coloured light so the glass field has something to refract.
            // Full width and tall enough that the blur fades out inside the view's own bounds;
            // backgroundExtensionEffect rasterizes to those bounds, so a smaller box shows hard edges.
            ZStack {
                Circle().fill(Color.hongguoRed.opacity(0.35)).frame(width: 520).offset(x: -220, y: -160)
                Circle().fill(Color.purple.opacity(0.3)).frame(width: 480).offset(x: 260, y: -120)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 680, alignment: .top)
            .blur(radius: 120)
            .extendsUnderChrome()
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .navigationTitle(submitted.isEmpty ? "搜索" : "“\(submitted)”")
        .transparentToolbar()
        .onAppear {
            fieldFocused = true
            if let pending = model.pendingSearch {
                model.pendingSearch = nil
                query = pending
                Task { await submit() }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold))
            TextField("剧名、分享链接或剧集编号", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .medium))
                .focused($fieldFocused)
                .onSubmit { Task { await submit() } }
            if query.isEmpty {
                Text("回车搜索 · 粘贴分享链接直接打开").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button { query = ""; fieldFocused = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(GlassIconButtonStyle(diameter: 34, variant: .clear))
                    .help("清除")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: 56)
        .glassSurface(in: Capsule(), interactive: true)
    }

    @ViewBuilder
    private var idleContent: some View {
        if !model.settings.searchHistory.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近搜索").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空") { model.settings.searchHistory = [] }.buttonStyle(.link)
                }
                FlowLayout(spacing: 8) {
                    ForEach(model.settings.searchHistory, id: \.self) { keyword in
                        Button(keyword) { query = keyword; Task { await submit() } }
                            .buttonStyle(GlassButtonStyle(size: .small))
                    }
                }
            }
        } else {
            Text("输入剧名搜索，或粘贴红果分享链接、剧集编号直接打开。")
                .foregroundStyle(.secondary)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("“\(submitted)”的结果").font(.system(size: 18, weight: .bold))
                Text("\(items.count) 部\(hasMore ? "+" : "")").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                ForEach(items) { item in
                    SearchResultCard(item: item, keyword: submitted)
                        .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            if isLoading { ProgressView().frame(maxWidth: .infinity) }
        }
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

/// Horizontal glass result card with the keyword highlighted.
struct SearchResultCard: View {
    let item: SeriesSummary
    let keyword: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.open(item) } label: {
            HStack(alignment: .top, spacing: 14) {
                CoverImage(url: item.cover, cornerRadius: 14).frame(width: 96, height: 128)
                VStack(alignment: .leading, spacing: 6) {
                    Text(highlighted).font(.system(size: 15, weight: .bold)).lineLimit(2)
                    Text(meta).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if !item.description.isEmpty {
                        Text(item.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await PlayerController.shared.open(seriesId: item.seriesId, title: item.title, cover: item.cover) }
                    } label: { Label("播放", systemImage: "play.fill") }
                        .buttonStyle(GlassButtonStyle(prominent: true, size: .small))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("在官网打开") { NSWorkspace.shared.open(Site.detailURL(item.seriesId)) }
        }
    }

    private var highlighted: AttributedString {
        var text = AttributedString(item.title)
        if !keyword.isEmpty, let range = text.range(of: keyword) {
            text[range].foregroundColor = .hongguoRed
        }
        return text
    }

    private var meta: String {
        var parts = Array(item.tags.prefix(2))
        if !item.episodeLabel.isEmpty {
            parts.append(item.episodeLabel)
        } else if item.episodeCount > 0 {
            parts.append("\(item.episodeCount) 集")
        }
        if !item.heat.isEmpty { parts.append(item.heat) }
        return parts.joined(separator: " · ")
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

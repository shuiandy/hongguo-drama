import HongguoCore
import HongguoModels
import HongguoPlayerKit
import SwiftUI

/// 评论 in the player, read only: the episode's public comments from the shared CommentListModel
/// (the iOS comment list's model: first batch with the total, more by cursor), each with its
/// author, date and likes. The TV does not post.
struct CommentsSidePanel: View {
    @Environment(TVAppModel.self) private var app
    let seriesId: String
    let vid: String
    /// Back closes the panel (the rows inside take the focus, so the panel answers Back itself).
    var close: () -> Void = {}
    @State private var model = CommentListModel()
    @State private var total: Int?
    @FocusState private var focusedComment: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(total.map { "\(CountText.short($0))条评论" } ?? "评论").font(.title3.weight(.semibold))
                Spacer()
                BackHint()
            }
            switch model.phase {
            case .loading, .idle:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            case .loaded where model.comments.isEmpty:
                Text("这一集暂无评论").foregroundStyle(.secondary)
            case .loaded:
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(model.comments) { comment in
                            // Focusable rows, so the remote can scroll through them.
                            Button {} label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(comment.author).font(.callout.weight(.semibold))
                                        Spacer()
                                        Label(CountText.short(comment.likes), systemImage: "heart").font(.caption)
                                    }
                                    EmoticonCatalog.shared.richText(comment.content, fontSize: 28)
                                    if let date = comment.createdAt {
                                        Text(CountText.day(date)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .focused($focusedComment, equals: comment.id)
                        }
                        if model.hasMore {
                            Button(model.retryPage ? "重试加载更多评论" : "加载更多评论") { Task { await model.loadMore() } }
                                .disabled(model.pages.loadingMore)
                        }
                    }
                }
                .scrollClipDisabled()
            }
            Spacer(minLength: 0)
        }
        .padding(48)
        .frame(width: 760)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .focusSection()
        .onExitCommand(perform: close)
        .task(id: vid) {
            total = await model.load(seriesId: seriesId, vid: vid, using: app.backend)
            // Into the panel, so Back and the remote reach it.
            try? await Task.sleep(for: .milliseconds(150))
            focusedComment = model.comments.first?.id
        }
    }
}

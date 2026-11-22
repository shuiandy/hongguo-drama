import SwiftUI

/// What a page shows instead of its content: loading, a failure with a retry button that takes
/// focus, or an empty list.
enum LoadState: Equatable {
    case loading
    case failed(String)
    case empty(String)
}

struct LoadStateView: View {
    let state: LoadState
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 28) {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                Text("正在加载")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                if let retry {
                    Button("重试", systemImage: "arrow.clockwise", action: retry)
                }
            case .empty(let message):
                Image(systemName: "tray")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }
}

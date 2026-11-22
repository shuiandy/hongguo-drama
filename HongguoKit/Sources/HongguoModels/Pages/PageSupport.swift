import AppLogic
import Foundation

/// Where a page's list stands (moved from the iOS app).
public enum LoadPhase: Equatable, Sendable {
    case idle, loading, loaded, failed(String)

    public init<Key, Item, Cursor>(_ phase: TabPages<Key, Item, Cursor>.Phase) {
        switch phase {
        case .idle: self = .idle
        case .loading: self = .loading
        case .loaded: self = .loaded
        case .failed(let message): self = .failed(message)
        }
    }
}

/// Starts downloading covers a page has just received. The apps point it at their cover cache at
/// launch (it is UIKit, outside this module); until then it does nothing.
@MainActor
public enum CoverPrefetch {
    public static var handler: (([String]) -> Void)?

    public static func prefetch(_ urls: [String]) { handler?(urls) }
}

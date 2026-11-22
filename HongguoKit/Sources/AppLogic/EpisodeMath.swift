import Foundation

/// 历史 list: filter tabs and the "3集/135集" progress text.
public enum HistoryProgress {
    public enum Filter: String, CaseIterable, Sendable {
        case all, finished, unfinished

        public var label: String {
            switch self {
            case .all: return "全部"
            case .finished: return "已看完"
            case .unfinished: return "未看完"
            }
        }
    }

    public static func isFinished(completedEpisode: Int, total: Int) -> Bool {
        total > 0 && completedEpisode >= total
    }

    public static func matches(_ filter: Filter, completedEpisode: Int, total: Int) -> Bool {
        switch filter {
        case .all: return true
        case .finished: return isFinished(completedEpisode: completedEpisode, total: total)
        case .unfinished: return !isFinished(completedEpisode: completedEpisode, total: total)
        }
    }

    /// The episode being watched over the series length; the length is left out when unknown.
    public static func label(episodeIndex: Int, total: Int) -> String {
        total > 0 ? "\(min(max(1, episodeIndex), total))集/\(total)集" : "\(max(1, episodeIndex))集"
    }
}

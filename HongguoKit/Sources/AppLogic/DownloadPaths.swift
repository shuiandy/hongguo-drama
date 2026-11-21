import Foundation

/// Where a download's file is after the app's container moved (a reinstall, a TestFlight
/// update): the task list keeps absolute paths, and the part from the downloads folder's
/// 红果短剧 directory on is what stays the same.
public enum DownloadPaths {
    static let marker = "/Downloads/红果短剧/"

    /// `path` re-rooted under `root` (the current Downloads folder), or nil when the path is not
    /// one of the downloads folder's files.
    public static func rebased(_ path: String, root: URL) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        let rest = String(path[range.upperBound...])
        guard !rest.isEmpty, !rest.split(separator: "/").contains("..") else { return nil }
        return root.appendingPathComponent("红果短剧", isDirectory: true).path + "/" + rest
    }
}

import Foundation

/// Which file a request to the app's local stream server may read. Kept apart from the server
/// so the rule can be tested: it is the whole of what stands between a request and the disk.
public enum LocalStreamPath {
    /// The file a request path names, or nil for anything but `/<token>/<folder>/<file>` made
    /// of plain names that stays inside `root` once links are resolved.
    public static func file(forRequestPath path: String, token: String, root: URL) -> URL? {
        // The raw path, before any decoding: an encoded character has no business here.
        let raw = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == token else { return nil }
        for name in parts[2...] {
            guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
                  name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(parts[2]).appendingPathComponent(parts[3]).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return file
    }

}

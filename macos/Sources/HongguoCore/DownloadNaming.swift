import Foundation
import CryptoKit

/// File and folder naming for downloads. Ports of `sanitizeFolderName`, `renderName`,
/// `seriesDownloadDir` and `uniqueEpisodeFilename` in main.js, so files land where the Electron
/// app would have put them and an existing download folder is recognised.
public enum DownloadNaming {
    /// Default template. Variables: 剧名 / series_title, 集数 / vid_index (zero padded to 3), 标题 / ep_title.
    public static let defaultFormat = "剧名 集数"

    /// Removes characters that are illegal on Windows/macOS, trims, caps at 80 characters and
    /// prefixes Windows reserved names.
    public static func sanitizeFolderName(_ name: String) -> String {
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { scalar in
            !"<>:\"/\\|?*".unicodeScalars.contains(scalar) && scalar.value >= 0x20
        }))
        while cleaned.hasPrefix(" ") { cleaned.removeFirst() }
        if cleaned.unicodeScalars.count > 80 {
            cleaned = String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(80)))
        }
        while let last = cleaned.last, last == "." || last == " " { cleaned.removeLast() }
        let lower = cleaned.lowercased()
        let stem = lower.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lower
        let reserved = ["con", "prn", "aux", "nul"] + (1...9).flatMap { ["com\($0)", "lpt\($0)"] }
        if reserved.contains(stem) {
            cleaned = "_" + cleaned
            while let last = cleaned.last, last == "." || last == " " { cleaned.removeLast() }
        }
        return cleaned
    }

    /// Renders the naming template, or nil when it renders empty.
    public static func renderName(format: String, seriesTitle: String, index: Int, episodeTitle: String) -> String? {
        let fmt = format.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fmt.isEmpty else { return nil }
        let vars = [
            "series_title": seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            "vid_index": String(format: "%03d", index),
            "ep_title": episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        var name = fmt.replacingOccurrences(of: "剧名", with: "series_title")
            .replacingOccurrences(of: "集数", with: "vid_index")
            .replacingOccurrences(of: "标题", with: "ep_title")
        // Replace ASCII word tokens (letters joined by underscores) that are known variables.
        let regex = try! NSRegularExpression(pattern: "[A-Za-z]+(?:_[A-Za-z]+)*")
        let ns = name as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: name, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = ns.substring(with: match.range)
            result += vars[token] ?? token
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        name = String(String.UnicodeScalarView(result.unicodeScalars.map { scalar in
            "<>:\"/\\|?*".unicodeScalars.contains(scalar) || scalar.value < 0x20 ? "_" : scalar
        }))
        name = name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    public static func episodeFilename(format: String, seriesTitle: String, index: Int, episodeTitle: String) -> String {
        let rendered = renderName(format: format, seriesTitle: seriesTitle, index: index, episodeTitle: episodeTitle) ?? seriesTitle
        let hasIndex = format.contains("集数") || format.contains("vid_index")
        return rendered + (hasIndex ? "" : String(format: "_第%03d集", index)) + ".mp4"
    }

    static func sha256Prefix(_ text: String, _ count: Int) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(count))
    }

    /// `<root>/红果短剧/<title>-<sha256(seriesId)[0..<12]>`.
    public static func seriesDirectory(root: URL, seriesId: String, seriesTitle: String) -> URL {
        let title = sanitizeFolderName(seriesTitle).isEmpty ? "未命名短剧" : sanitizeFolderName(seriesTitle)
        return root.appendingPathComponent("红果短剧", isDirectory: true)
            .appendingPathComponent("\(title)-\(sha256Prefix(seriesId, 12))", isDirectory: true)
    }

    /// Suffix used when two episodes would otherwise share one path.
    static func conflictSuffixed(_ filename: String, vid: String) -> String {
        let suffix = sha256Prefix(vid, 8)
        return filename.hasSuffix(".mp4") ? String(filename.dropLast(4)) + "-\(suffix).mp4" : filename + "-\(suffix)"
    }
}

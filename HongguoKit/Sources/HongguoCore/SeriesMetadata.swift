import Foundation

/// Whole-series metadata files for media servers (port of the metadata part of
/// src/native/nas-export.js): `tvshow.nfo`, `简介.txt`, `poster.jpg|png|webp` and one
/// `<episode>.nfo` per episode. Files that already exist are kept; a `tvshow.nfo` of a different
/// series in the same folder stops the export instead of mixing two series.
public enum SeriesMetadata {
    public struct Series: Sendable {
        public var seriesId: String
        public var title: String
        public var description: String
        public var cover: String
        public init(seriesId: String, title: String, description: String = "", cover: String = "") {
            self.seriesId = seriesId; self.title = title; self.description = description; self.cover = cover
        }
    }

    static func xml(_ value: String) -> String {
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D)
        }))
        return cleaned.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    public static func tvshowNFO(_ series: Series) -> String {
        let plot = series.description.isEmpty ? "" : "\n  <plot>\(xml(series.description))</plot>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tvshow>\n  <title>\(xml(series.title))</title>\(plot)\n"
            + "  <uniqueid type=\"hongguo\" default=\"true\">\(xml(series.seriesId))</uniqueid>\n</tvshow>\n"
    }

    public static func episodeNFO(seriesTitle: String, episode: Episode, season: Int) -> String {
        let title = episode.title.isEmpty ? "第\(episode.index)集" : episode.title
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<episodedetails>\n  <title>\(xml(title))</title>\n"
            + "  <showtitle>\(xml(seriesTitle))</showtitle>\n  <season>\(season)</season>\n  <episode>\(episode.index)</episode>\n"
            + "  <uniqueid type=\"hongguo\" default=\"true\">\(xml(episode.vid))</uniqueid>\n</episodedetails>\n"
    }

    /// Whether `directory/tvshow.nfo` belongs to another series.
    static func belongsToOtherSeries(_ directory: URL, seriesId: String) -> Bool {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("tvshow.nfo"), encoding: .utf8) else { return false }
        guard let range = text.range(of: "<uniqueid type=\"hongguo\"[^>]*>([^<]*)</uniqueid>", options: .regularExpression) else { return false }
        let tag = String(text[range])
        guard let open = tag.firstIndex(of: ">"), let close = tag.range(of: "</uniqueid>") else { return false }
        return String(tag[tag.index(after: open)..<close.lowerBound]) != seriesId
    }

    static func writeIfMissing(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try data.write(to: url, options: [.atomic])
    }

    /// Writes the series files into `directory` (created if needed). Returns warnings for parts
    /// that could not be saved; the downloads go ahead either way.
    @discardableResult
    public static func writeSeries(_ series: Series, into directory: URL, http: HTTPClient = .shared) async throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if belongsToOtherSeries(directory, seriesId: series.seriesId) {
            throw HongguoError(.input, "这个文件夹已经存放了另一部剧的资料，请换一个文件夹")
        }
        var warnings: [String] = []
        try writeIfMissing(Data(tvshowNFO(series).utf8), to: directory.appendingPathComponent("tvshow.nfo"))
        if series.description.isEmpty {
            warnings.append("来源暂未提供剧情简介")
        } else {
            try writeIfMissing(Data("\(series.title)\n\n\(series.description)\n".utf8), to: directory.appendingPathComponent("简介.txt"))
        }
        let hasPoster = ["jpg", "png", "webp"].contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.\($0)").path) }
        if !hasPoster {
            if let url = URL(string: series.cover), url.scheme == "https" || url.scheme == "http" {
                do {
                    var options = HTTPClient.Options()
                    options.headers = ["User-Agent": UserAgents.web]
                    options.maxBytes = 10 * 1024 * 1024
                    options.timeout = 20
                    let response = try await http.get(url, options: options)
                    let ext = imageExtension(response.data)
                    if let ext { try writeIfMissing(response.data, to: directory.appendingPathComponent("poster.\(ext)")) }
                    else { warnings.append("封面不是可识别的图片格式") }
                } catch {
                    warnings.append("封面下载失败")
                }
            } else {
                warnings.append("来源没有提供封面")
            }
        }
        return warnings
    }

    /// jpg / png / webp from the file signature; nil for anything else.
    static func imageExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: bytes[8...11], as: UTF8.self)
            if ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand) { return "heic" }
        }
        return nil
    }
}

/// 下载到 NAS: a mounted share folder laid out for Jellyfin / Emby / Kodi / Infuse:
/// `<root>/<剧名>/Season 01/<剧名> S01E001.mp4` plus the series files. Port of the layout in
/// src/native/nas-export.js.
public struct NASLayout: Sendable, Equatable {
    public var directory: URL
    public var title: String
    public var season: Int

    public init(root: URL, seriesTitle: String, createFolder: Bool) {
        let parsed = WatchHistory.seasonTitle(seriesTitle)
        let clean = DownloadNaming.sanitizeFolderName(seriesTitle)
        title = clean.isEmpty ? "未命名短剧" : clean
        season = parsed.invalid ? 1 : max(1, parsed.season)
        directory = createFolder ? root.appendingPathComponent(title, isDirectory: true) : root
    }

    public var seasonDirectory: URL {
        directory.appendingPathComponent(String(format: "Season %02d", season), isDirectory: true)
    }

    public func videoURL(for episode: Episode) -> URL {
        seasonDirectory.appendingPathComponent("\(title) S\(String(format: "%02d", season))E\(String(format: "%03d", episode.index)).mp4")
    }

    public func nfoURL(for episode: Episode) -> URL {
        videoURL(for: episode).deletingPathExtension().appendingPathExtension("nfo")
    }
}

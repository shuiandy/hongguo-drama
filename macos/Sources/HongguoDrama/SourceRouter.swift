import Foundation
import HongguoCore

/// Routes series and episode requests to Hongguo's own services or to the other catalogues
/// (西饭, 河马, overseas, custom endpoints) by id prefix, under the current source settings.
enum SourceRouter {
    static let series = SeriesService()

    static func isHongguo(_ id: String) -> Bool { MediaSources.sourceId(of: id) == "hongguo" }

    static func source(for id: String) throws -> MediaSource? {
        try MediaSources.source(for: id, settings: { LibraryStore.shared.settings })
    }

    /// The catalogue for a source id from the switcher ("xifan", "custom:<uuid>").
    static func catalogue(_ sourceId: String) throws -> MediaSource? {
        try source(for: sourceId.hasPrefix("custom:") ? sourceId : sourceId + ":")
    }

    static func episodes(seriesId: String, force: Bool = false) async throws -> SeriesEpisodes {
        if let source = try source(for: seriesId) { return try await source.episodes(seriesId: seriesId) }
        return try await series.episodes(seriesId: seriesId, force: force)
    }

    static func playInfo(vid: String, seriesId: String, force: Bool = false) async throws -> PlayInfo {
        if let source = try source(for: seriesId) { return try await source.playInfo(vid: vid, seriesId: seriesId) }
        return try await series.playInfo(vid: vid, seriesId: seriesId, force: force)
    }

    /// Label of a source id ("xifan", "custom:<uuid>") for titles.
    static func label(_ sourceId: String) -> String {
        LibraryStore.shared.settings.mediaSources.first { $0.id == sourceId }?.label
            ?? MediaSources.builtin.first { $0.id == sourceId }?.label ?? "片源"
    }
}

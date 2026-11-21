import Foundation
import HongguoCore
import MediaSources

/// Routes series and episode requests to Hongguo's own services or to the other catalogues
/// (西饭, 河马, overseas, custom endpoints) by id prefix, under the current source settings.
enum SourceRouter {
    static let series = SeriesService()

    static func isHongguo(_ id: String) -> Bool { MediaSources.sourceId(of: id) == "hongguo" }

    static func source(for id: String) throws -> MediaSource? {
        try MediaSources.source(for: id, settings: { SourceSettingsStore.shared.value })
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

    /// One quiet try at the source of an episode the viewer has not asked for yet.
    static func prefetchedPlayInfo(vid: String, seriesId: String) async -> PlayInfo? {
        if isHongguo(seriesId) { return await series.prefetchedPlayInfo(vid: vid, seriesId: seriesId) }
        guard let source = try? source(for: seriesId) else { return nil }
        return try? await source.playInfo(vid: vid, seriesId: seriesId)
    }

    /// Asks for several Hongguo episodes' play models in one request (at most 6 are sent).
    /// Other catalogues have no such request and are left alone.
    static func prefetchPlayInfo(seriesId: String, vids: [String]) async {
        guard isHongguo(seriesId), !vids.isEmpty else { return }
        await series.prefetchPlayInfo(vids: vids)
    }

    /// Label of a source id ("xifan", "custom:<uuid>") for titles.
    static func label(_ sourceId: String) -> String {
        SourceSettingsStore.shared.value.mediaSources.first { $0.id == sourceId }?.label
            ?? MediaSources.builtin.first { $0.id == sourceId }?.label ?? "片源"
    }
}

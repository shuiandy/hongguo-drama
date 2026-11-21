#if canImport(UIKit)
import AVKit
import Foundation
import HongguoCore
import HongguoPlayback

/// What only some apps can do for the player, handed to `PlayerEngine.init` at launch: the iOS
/// app installs all four, the tvOS app none. A missing hook is the path the iOS app already takes
/// when the feature has nothing to give: no downloaded file, no converted stream (a ByteVC2-only
/// episode then shows 此剧集暂不支持 and moves on), no casting, no little window.
public struct PlayerHooks {
    /// 本地文件查找: downloaded episodes.
    public var localFiles: (any LocalEpisodeFiles)?
    /// ByteVC2 转码流: episodes the device can only play after converting them.
    public var convertedStreams: (any ConvertedStreams)?
    /// 投屏发布: serving the episode on the local network to an AirPlay receiver.
    public var cast: CastHook?
    /// 小窗: picture in picture.
    public var pictureInPicture: (any PictureInPictureHook)?

    public init(localFiles: (any LocalEpisodeFiles)? = nil, convertedStreams: (any ConvertedStreams)? = nil,
                cast: CastHook? = nil, pictureInPicture: (any PictureInPictureHook)? = nil) {
        self.localFiles = localFiles
        self.convertedStreams = convertedStreams
        self.cast = cast
        self.pictureInPicture = pictureInPicture
    }
}

/// Downloaded episodes (离线缓存).
public protocol LocalEpisodeFiles: Sendable {
    /// The file of a downloaded episode. Synchronous: it is asked on the instant-swap path.
    func file(vid: String) -> URL?
    /// A series' downloaded episodes in episode order, to open it with no network.
    @MainActor func offlineEpisodes(seriesId: String) -> [DownloadTask]
}

/// A conversion kept on the device: its address, the quality it was converted at and the
/// qualities the source offered then, so the quality menu stays usable.
public struct ConvertedStream: Sendable {
    public var url: URL
    public var quality: QualityOption?
    public var options: [QualityOption]

    public init(url: URL, quality: QualityOption?, options: [QualityOption]) {
        self.url = url
        self.quality = quality
        self.options = options
    }
}

/// Episodes offered only in ByteVC2, converted on the device and played as they convert.
public protocol ConvertedStreams: Sendable {
    /// A finished stream that fits the quality asked for, with no source lookup.
    func finishedStream(vid: String, preferredShortSide: Int?) async -> ConvertedStream?
    /// Starts (or joins) the conversion and returns the address to play once enough is ready.
    func open(_ prepared: PreparedEpisode, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// Converts the next episode ahead.
    func prepareAhead(_ prepared: PreparedEpisode) async
    /// Conversions started ahead for anything but `vids` give way.
    func yieldAhead(keeping vids: Set<String>) async
    /// The episode being left: a conversion only for it stops.
    func leave(vid: String, key: String?) async
    /// Nothing reads from the local stream any more.
    @MainActor func stopServing()
}

/// Makes the local-network publication an AirPlay receiver plays from.
public struct CastHook: Sendable {
    public var publish: @Sendable (@escaping @Sendable () async throws -> LocalCastServer.Media) -> CastPublication

    public init(publish: @escaping @Sendable (@escaping @Sendable () async throws -> LocalCastServer.Media) -> CastPublication) {
        self.publish = publish
    }
}

/// Makes the picture-in-picture controller for the video layer and keeps its automatic start
/// (退出 App 时自动小窗) in step with the setting.
@MainActor
public protocol PictureInPictureHook {
    func makeController(for layer: AVPlayerLayer, startsAutomatically: Bool) -> AVPictureInPictureController?
    func setStartsAutomatically(_ on: Bool, for controller: AVPictureInPictureController)
}
#endif

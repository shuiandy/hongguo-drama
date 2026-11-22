import HongguoPlayerKit
import MediaPlayer

/// What the system shows about the episode playing (the TV's Now Playing, the Control Center on
/// a paired iPhone) and the remote commands it sends back: play, pause, ±10 s, a position, the
/// next episode.
@MainActor
final class NowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []

    func start(play: @escaping () -> Void, pause: @escaping () -> Void, toggle: @escaping () -> Void,
               skip: @escaping (Double) -> Void, seek: @escaping (Double) -> Void, next: @escaping () -> Void) {
        stop()
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            targets.append((command, command.addTarget(handler: handler)))
        }
        add(center.playCommand) { _ in play(); return .success }
        add(center.pauseCommand) { _ in pause(); return .success }
        add(center.togglePlayPauseCommand) { _ in toggle(); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { _ in skip(10); return .success }
        add(center.skipBackwardCommand) { _ in skip(-10); return .success }
        add(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            seek(event.positionTime)
            return .success
        }
        add(center.nextTrackCommand) { _ in next(); return .success }
    }

    func update(title: String, episode: Int, engine: PlayerEngine) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode > 0 ? "\(title) 第\(episode)集" : title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? Double(engine.rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if engine.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = engine.duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func stop() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

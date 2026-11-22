import Foundation

/// Decides whether a failure reported by the player belongs to the episode on screen and has
/// not been acted on yet.
///
/// One failure can arrive several ways: the item's status turning to failed, the streaming
/// loader giving up, or `failedToPlayToEndTime` after the item was already ready (a source that
/// stops answering mid-play stalls, and about 18 s later posts only that notification; the
/// status stays ready). Each load has a token (the player's generation); a signal is taken only
/// when it carries the current token, comes from the item being played, and is the first one
/// for that token, so an old episode's late notification can never retry the new one and one
/// failure never starts two reloads.
public struct PlaybackFailureGate: Sendable {
    private var handledToken: Int?

    public init() {}

    /// - Parameters:
    ///   - token: the load generation the signal was registered for.
    ///   - current: the player's generation now.
    ///   - isCurrentItem: the signal's item is the one the player is playing (true for
    ///     signals that are not tied to an item, such as the loader's).
    public mutating func accept(token: Int, current: Int, isCurrentItem: Bool) -> Bool {
        guard token == current, isCurrentItem, handledToken != token else { return false }
        handledToken = token
        return true
    }
}

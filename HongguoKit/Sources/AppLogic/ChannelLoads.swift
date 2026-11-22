import Foundation

/// First-page requests of the home feed's channels (推荐, 真人剧, 漫剧) when the viewer switches
/// faster than the service answers. Each request gets a ticket naming the channel it was made
/// for. A reply is cached under that channel (never under whichever channel is on screen when
/// it lands), and only if it is still that channel's newest request; it reaches the screen only
/// while its channel is the one shown. A late failure never clears another channel's list.
public struct ChannelLoads<Channel: Hashable & Sendable>: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let channel: Channel
        fileprivate let id: Int
    }

    public struct Outcome: Equatable, Sendable {
        /// Store the page in the cache of `ticket.channel`.
        public var cache: Bool
        /// Put the page on screen.
        public var show: Bool
    }

    private var lastId = 0
    private var newest: [Channel: Int] = [:]

    public init() {}

    public mutating func begin(_ channel: Channel) -> Ticket {
        lastId += 1
        newest[channel] = lastId
        return Ticket(channel: channel, id: lastId)
    }

    private func isNewest(_ ticket: Ticket) -> Bool { newest[ticket.channel] == ticket.id }

    public func succeeded(_ ticket: Ticket, shown: Channel) -> Outcome {
        let current = isNewest(ticket)
        return Outcome(cache: current, show: current && ticket.channel == shown)
    }

    /// Whether the failure may replace what is on screen.
    public func failed(_ ticket: Ticket, shown: Channel) -> Bool {
        isNewest(ticket) && ticket.channel == shown
    }
}

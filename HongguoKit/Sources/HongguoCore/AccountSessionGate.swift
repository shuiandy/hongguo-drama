import Foundation

/// Which signed-in session a background account sync belongs to. Sign-in ends as soon as the
/// login is verified and the account's history, favourites, likes and reservations load
/// behind it; a sync that finishes after signing out, or after another account signed in, must
/// not write that data back. Every sync takes a token when it starts and writes only while the
/// token still names the current session (same sign-in and same account).
public struct AccountSessionGate: Sendable {
    public struct Token: Equatable, Sendable {
        public let generation: Int
        public let accountId: String
    }

    private var generation = 0
    private var accountId: String?

    public init() {}

    /// A login was verified (or a saved one restored): a new session starts.
    @discardableResult
    public mutating func signedIn(accountId: String) -> Token {
        generation += 1
        self.accountId = accountId
        return Token(generation: generation, accountId: accountId)
    }

    public mutating func signedOut() {
        generation += 1
        accountId = nil
    }

    /// The token for a sync starting now; nil when nobody is signed in.
    public var current: Token? {
        accountId.map { Token(generation: generation, accountId: $0) }
    }

    /// Whether a sync that started with `token` may still write.
    public func accepts(_ token: Token) -> Bool {
        token.generation == generation && token.accountId == accountId
    }
}

/// Roll back one optimistic account edit while preserving edits to other records.
public enum AccountListRollback {
    public static func restore<Row>(_ rows: inout [Row], prior: (offset: Int, element: Row)?,
                                     matching: (Row) -> Bool) {
        rows.removeAll(where: matching)
        if let prior { rows.insert(prior.element, at: min(prior.offset, rows.count)) }
    }
}

import Foundation
import HongguoCore
import Observation

/// Where each account's login is kept: one item per account id.
public protocol RosterCredentialVault: Sendable {
    func load(_ accountId: String) throws -> AccountCredentials?
    func save(_ accountId: String, _ value: AccountCredentials) throws
    func delete(_ accountId: String) throws
}

/// The keychain, one generic-password item per account (`HongguoDrama.account.roster` / the
/// account id), in the same format as the current login's item.
public struct KeychainRosterVault: RosterCredentialVault {
    public init() {}

    private func store(_ accountId: String) -> KeychainCredentialStore {
        var store = KeychainCredentialStore()
        store.service = "HongguoDrama.account.roster"
        store.account = accountId
        return store
    }

    public func load(_ accountId: String) throws -> AccountCredentials? { try store(accountId).load() }
    public func save(_ accountId: String, _ value: AccountCredentials) throws { try store(accountId).save(value) }
    public func delete(_ accountId: String) throws { try store(accountId).clear() }
}

/// The accounts signed in on this device, for choosing one at launch and switching later.
/// Each entry keeps the id, nickname, picture and when it was last used; each login is in its own
/// keychain item; the current account's id is kept apart. The device identity stays one for all
/// (as in the official app: the same device, another account). Switching goes through
/// AccountModel's sign-in steps. Removing an account deletes only this device's entry and its
/// keychain item (no sign-out request); 退出登录 on 我的 is the existing sign-out.
@MainActor
@Observable
public final class AccountRoster {
    public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var nickname: String
        public var avatar: String
        public var lastUsedAt: Date

        public init(id: String, nickname: String, avatar: String = "", lastUsedAt: Date = Date()) {
            self.id = id
            self.nickname = nickname
            self.avatar = avatar
            self.lastUsedAt = lastUsedAt
        }
    }

    /// Most recently used first.
    public private(set) var entries: [Entry] = []
    public private(set) var currentId: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let vault: any RosterCredentialVault
    @ObservationIgnored private let current: any AccountCredentialStore
    static let entriesKey = "HongguoDrama.accountRoster"
    static let currentKey = "HongguoDrama.accountRoster.current"

    /// - Parameters:
    ///   - current: the current login's store (the one the core signs in with).
    public init(defaults: UserDefaults = .standard, vault: any RosterCredentialVault = KeychainRosterVault(),
                current: any AccountCredentialStore = KeychainCredentialStore()) {
        self.defaults = defaults
        self.vault = vault
        self.current = current
        if let data = defaults.data(forKey: Self.entriesKey), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved.sorted { $0.lastUsedAt > $1.lastUsedAt }
        }
        currentId = defaults.string(forKey: Self.currentKey)
    }

    /// A sample roster for screenshots and UI tests: made-up accounts with no login, in memory only.
    public static func samples() -> AccountRoster {
        let name = "HongguoDrama.sampleRoster.\(UUID().uuidString)"
        let roster = AccountRoster(defaults: UserDefaults(suiteName: name) ?? .standard, vault: MemoryVault(), current: MemoryVault.Current())
        let now = Date()
        for (offset, sample) in [("1000000001", "小红果"), ("1000000002", "追剧达人"), ("1000000003", "家里的电视")].enumerated() {
            roster.add(Entry(id: sample.0, nickname: sample.1, lastUsedAt: now.addingTimeInterval(Double(-offset) * 3600)),
                       credentials: AccountCredentials(cookie: "", profile: AccountProfile(id: sample.0, nickname: sample.1)))
        }
        return roster
    }

    /// The entry chosen by default: the most recently used.
    public var mostRecent: Entry? { entries.first }

    /// An earlier version kept one login only: it becomes the first entry.
    public func migrateIfNeeded() {
        guard entries.isEmpty, let saved = try? current.load(), let profile = saved.profile else { return }
        add(Entry(id: profile.id, nickname: profile.nickname), credentials: saved)
        setCurrent(profile.id)
    }

    /// After a sign-in: the login now current joins the roster (or refreshes its entry) and is current.
    public func rememberCurrent(avatar: String = "") {
        guard let saved = try? current.load(), let profile = saved.profile else { return }
        let existing = entries.first { $0.id == profile.id }
        add(Entry(id: profile.id, nickname: profile.nickname, avatar: avatar.isEmpty ? (existing?.avatar ?? "") : avatar),
            credentials: saved)
        setCurrent(profile.id)
    }

    /// The account's picture or name changed (read after a sign-in or a switch).
    public func update(id: String, nickname: String, avatar: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if !nickname.isEmpty { entries[index].nickname = nickname }
        if !avatar.isEmpty { entries[index].avatar = avatar }
        persist()
    }

    /// Switches the account to an entry's login. False when its login is gone.
    public func switchTo(_ entry: Entry, account: AccountModel) async -> Bool {
        guard let saved = try? vault.load(entry.id) else { return false }
        guard await account.switchAccount(to: saved) else { return false }
        setCurrent(entry.id)
        return true
    }

    /// 不登录使用: carry on signed out; the entries and their logins stay for next time.
    public func continueSignedOut(account: AccountModel) async {
        if account.isSignedIn { await account.signOut() }
        setCurrent(nil)
    }

    /// Removes an account from this device only (no sign-out request). The current account is
    /// left signed out.
    public func remove(_ entry: Entry, account: AccountModel) async {
        entries.removeAll { $0.id == entry.id }
        try? vault.delete(entry.id)
        persist()
        if currentId == entry.id {
            await continueSignedOut(account: account)
        }
    }

    private func add(_ entry: Entry, credentials: AccountCredentials) {
        var stamped = entry
        stamped.lastUsedAt = max(entry.lastUsedAt, entries.first { $0.id == entry.id }?.lastUsedAt ?? .distantPast)
        entries.removeAll { $0.id == entry.id }
        entries.append(stamped)
        entries.sort { $0.lastUsedAt > $1.lastUsedAt }
        try? vault.save(entry.id, credentials)
        persist()
    }

    private func setCurrent(_ id: String?) {
        currentId = id
        if let id, let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].lastUsedAt = Date()
            entries.sort { $0.lastUsedAt > $1.lastUsedAt }
            persist()
        }
        defaults.set(id, forKey: Self.currentKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.entriesKey) }
    }
}

/// An in-memory vault and current-login store, for sample runs and tests.
public final class MemoryVault: RosterCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: AccountCredentials] = [:]

    public init() {}

    public func load(_ accountId: String) throws -> AccountCredentials? { lock.withLock { items[accountId] } }
    public func save(_ accountId: String, _ value: AccountCredentials) throws { lock.withLock { items[accountId] = value } }
    public func delete(_ accountId: String) throws { _ = lock.withLock { items.removeValue(forKey: accountId) } }

    public final class Current: AccountCredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var value: AccountCredentials?

        public init(_ value: AccountCredentials? = nil) { self.value = value }

        public func load() throws -> AccountCredentials? { lock.withLock { value } }
        public func save(_ value: AccountCredentials) throws { lock.withLock { self.value = value } }
        public func clear() throws { lock.withLock { value = nil } }
    }
}

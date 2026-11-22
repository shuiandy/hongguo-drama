import Foundation

/// The 点赞 wall: this device's likes joined with the account's.
///
/// The account likes episodes (one row per liked episode, with its number and category). This
/// device keeps one entry per series holding the liked episodes' video ids, with no episode
/// numbers and no category. The two cannot be matched episode by episode, so neither hides the
/// other: every account episode stays (an account like of episode 22 is not swallowed by a
/// local like of episode 1 of the same show), repeated account rows for one episode show once,
/// and a local entry takes its show's category from what the account knows, so it is found on
/// that category's page too. A local entry whose category is unknown shows only under 全部.
public enum LikeMerge {
    public struct Merged<Local, Account> {
        /// Local entries with the category used for them ("" when unknown).
        public var local: [(item: Local, category: String)]
        public var account: [Account]
    }

    /// - Parameters:
    ///   - categories: the category of a series from any account list (likes, favourites, history).
    ///   - selected: the category page, nil for 全部.
    public static func merge<Local, Account>(
        local: [Local], account: [Account],
        localSeries: (Local) -> String,
        accountSeries: (Account) -> String, accountVid: (Account) -> String = { _ in "" },
        accountEpisode: (Account) -> Int, accountCategory: (Account) -> String,
        categories: [String: String], selected: String?
    ) -> Merged<Local, Account> {
        var known = categories
        for row in account where known[accountSeries(row), default: ""].isEmpty && !accountCategory(row).isEmpty {
            known[accountSeries(row)] = accountCategory(row)
        }
        let localRows: [(item: Local, category: String)] = local.compactMap { item in
            let category = known[localSeries(item)] ?? ""
            guard selected == nil || category == selected else { return nil }
            return (item, category)
        }
        var seen: Set<String> = []
        let accountRows = account.filter { row in
            guard selected == nil || accountCategory(row) == selected else { return false }
            let vid = accountVid(row)
            let key = vid.isEmpty ? "episode:\(accountEpisode(row))" : "vid:\(vid)"
            return seen.insert("\(accountSeries(row)):\(key)").inserted
        }
        return Merged(local: localRows, account: accountRows)
    }
}

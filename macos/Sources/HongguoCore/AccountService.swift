// SPDX-License-Identifier: GPL-3.0-only
// Port of src/native/account-session.js: Hongguo account sign-in through the website's QR code
// (or a cookie read from a sign-in web view), the account profile, and the App watch history of
// the signed-in account. The login cookie is kept in the macOS Keychain only; it is never written
// to a plain file and never sent anywhere except hongguoduanju.com and the signed App account API.
import Foundation
import Security

public struct AccountProfile: Codable, Equatable, Sendable {
    public var id: String
    public var nickname: String
}

/// One row of the account's App watch history.
public struct AccountHistoryItem: Equatable, Sendable, Identifiable {
    public var id: String { seriesId }
    public var seriesId: String
    public var seriesTitle: String
    public var cover: String
    public var episodeId: String
    /// 1-based, 0 when unknown.
    public var episodeIndex: Int
    public var position: Double
    public var duration: Double
    public var updatedAt: Date
    public var total: Int
}

public struct AccountLoginQR: Equatable, Sendable {
    public var loginId: String
    /// PNG bytes of the QR code.
    public var image: Data
    public var expiresIn: Int
}

public enum AccountLoginStatus: Equatable, Sendable {
    case pending, expired, cancelled
    case signedIn(AccountProfile, storageWarning: String)
}

/// Saved credentials: the website cookie and the last verified profile.
public struct AccountCredentials: Codable, Equatable, Sendable {
    public var cookie: String
    public var profile: AccountProfile?
}

public protocol AccountCredentialStore: Sendable {
    func load() throws -> AccountCredentials?
    func save(_ value: AccountCredentials) throws
    func clear() throws
}

/// Keychain item (generic password) for this app only.
public struct KeychainCredentialStore: AccountCredentialStore {
    public var service = "HongguoDrama.account"
    public var account = "hongguoduanju.com"
    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> AccountCredentials? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw HongguoError(.unavailable, "无法读取钥匙串里的登录信息") }
        guard let value = try? JSONDecoder().decode(AccountCredentials.self, from: data),
              !value.cookie.trimmingCharacters(in: .whitespaces).isEmpty else { throw HongguoError(.input, "登录态无效，请重新扫码") }
        return value
    }

    public func save(_ value: AccountCredentials) throws {
        let data = try JSONEncoder().encode(value)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw HongguoError(.unavailable, "系统钥匙串不可用，本次登录只保留到应用退出") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw HongguoError(.unavailable, "系统钥匙串不可用，本次登录只保留到应用退出")
        }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HongguoError(.unavailable, "无法删除钥匙串里的登录信息") }
    }
}

/// Cookies by name, as the JS `CookieJar`.
struct CookieJar: Sendable {
    private(set) var values: [(String, String)] = []

    init(_ header: String = "") {
        for pair in header.split(separator: ";") {
            guard let at = pair.firstIndex(of: "="), at != pair.startIndex else { continue }
            set(pair[..<at].trimmingCharacters(in: .whitespaces), pair[pair.index(after: at)...].trimmingCharacters(in: .whitespaces))
        }
    }

    mutating func set(_ name: String, _ value: String) {
        if let at = values.firstIndex(where: { $0.0 == name }) { values[at].1 = value } else { values.append((name, value)) }
    }

    mutating func absorb(_ response: HTTPResponse) {
        guard let raw = response.header("Set-Cookie") else { return }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: response.url) {
            set(cookie.name, cookie.value)
        }
    }

    var header: String { values.filter { !$0.0.isEmpty && !$0.1.isEmpty }.map { "\($0.0)=\($0.1)" }.joined(separator: "; ") }
    var hasSession: Bool { values.contains { ($0.0 == "sessionid" || $0.0 == "sessionid_ss") && !$0.1.isEmpty } }
}

public actor AccountService {
    public static let shared = AccountService()

    static let webBase = "https://hongguoduanju.com"
    static let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    static let webQuery: [(String, String)] = [
        ("aid", "513755"), ("passport_jssdk_version", "3.4.10"), ("passport_jssdk_type", "normal"),
        ("account_sdk_source", "web"), ("is_from_ttaccountsdk", "1"), ("language", "zh"),
    ]

    public typealias WebRequest = @Sendable (_ url: URL, _ headers: [String: String]) async throws -> HTTPResponse
    public typealias AccountRequest = @Sendable (_ url: String, _ headers: [(String, String)]) async throws -> JSONValue

    private let store: AccountCredentialStore
    private let webRequest: WebRequest
    private let accountRequest: AccountRequest
    private let identity: @Sendable () async throws -> PlaybackIdentity
    private let now: @Sendable () -> Date

    private var credentials: AccountCredentials?
    private var profile: AccountProfile?
    private var cachedHistory: [AccountHistoryItem]?
    private var restored = false
    private var restoreError = ""
    private var generation = 0
    private var login: (id: String, token: String, jar: CookieJar, expiresAt: Date)?
    private var loginGeneration = 0

    public init(store: AccountCredentialStore = KeychainCredentialStore(), webRequest: WebRequest? = nil,
                accountRequest: AccountRequest? = nil, identity: (@Sendable () async throws -> PlaybackIdentity)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        self.webRequest = webRequest ?? { url, headers in
            var options = HTTPClient.Options()
            options.headers = headers
            options.timeout = 12
            options.maxBytes = 2 * 1024 * 1024
            options.maxRedirects = 0
            options.acceptStatus = 100...599
            return try await HTTPClient.shared.get(url, options: options)
        }
        let transport = AppTransport(http: .shared)
        self.accountRequest = accountRequest ?? { url, headers in
            do { return try await transport.requestJSON(url, headers: headers, deadline: Date().addingTimeInterval(12)) }
            catch let error as AppSourceError { throw HongguoError(.unavailable, error.message) }
        }
        self.identity = identity ?? { try await AppSearchIdentity.shared.get(transport: transport) }
    }

    // MARK: Parsing (pure)

    static func cleanText(_ value: String?) -> String { SearchText.clean(value) }

    static func cleanCover(_ value: String?) -> String {
        var text = (value ?? "").trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("//") { text = "https:" + text }
        guard text.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil, let url = URL(string: text) else { return "" }
        let heic = url.path.lowercased().hasSuffix(".heic")
        if heic, let host = url.host?.lowercased(), host.hasSuffix("-reading-sign.fqnovelpic.com") {
            let source = url.path.components(separatedBy: "~tplv-")[0]
            return "https://p3-novel.byteimg.com\(source)~tplv-shrink:320:0.webp"
        }
        return heic ? "" : text
    }

    /// Port of `responseData`: website passport replies use `message`, App replies use `code`.
    static func responseData(_ payload: JSONValue) throws -> JSONValue {
        guard payload.object != nil else { throw HongguoError(.format, "红果账号接口返回格式异常") }
        if let message = payload["message"].string, !message.trimmingCharacters(in: .whitespaces).isEmpty,
           message.trimmingCharacters(in: .whitespaces).lowercased() != "success" {
            let description = cleanText(payload["data"]["description"].string ?? message)
            throw HongguoError(.upstream, description.isEmpty ? "红果账号操作未完成" : description)
        }
        if !payload["code"].isNull {
            let code = payload["code"]
            let zero: Bool
            switch code { case .int(let i): zero = i == 0; case .double(let d): zero = d == 0; case .string(let s): zero = s == "0"; default: zero = false }
            if !zero {
                let text = cleanText(payload["message"].string ?? payload["msg"].string)
                throw HongguoError(.upstream, text.isEmpty ? "红果账号接口返回错误" : text)
            }
        }
        guard payload["data"].object != nil else { throw HongguoError(.format, "红果账号接口返回内容为空") }
        return payload["data"]
    }

    static func parseQR(_ payload: JSONValue, now: Date) throws -> (token: String, image: Data, expiresIn: Int) {
        let data = try responseData(payload)
        let token = (data["token"].string ?? "").trimmingCharacters(in: .whitespaces)
        let source = (data["qrcode"].string ?? "").trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !source.isEmpty else { throw HongguoError(.format, "红果登录二维码格式已变化") }
        let base64 = source.components(separatedBy: "base64,").last ?? source
        guard let image = Data(base64Encoded: base64), image.count > 8 else { throw HongguoError(.format, "红果登录二维码格式已变化") }
        let raw = data["expire_time"].number ?? 0
        let seconds = raw > 1_000_000_000 ? raw - now.timeIntervalSince1970.rounded(.down) : (raw > 0 ? raw : 180)
        return (token, image, Int(max(0, min(600, seconds)).rounded()))
    }

    static func parseProfile(_ payload: JSONValue) throws -> AccountProfile {
        let data = try responseData(payload)
        let id = (data["user_id_str"].idString ?? data["user_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw HongguoError(.input, "登录态未通过红果账号验证，请重新扫码") }
        guard id.matchesDigits(min: 1, max: 30), id.contains(where: { $0 != "0" }) else { throw HongguoError(.input, "红果账号编号无效，请重新扫码") }
        let nickname = cleanText(data["name"].string ?? data["screen_name"].string ?? data["username"].string)
        return AccountProfile(id: id, nickname: nickname.isEmpty ? "红果用户" : nickname)
    }

    static func parseHistory(_ payload: JSONValue) throws -> [AccountHistoryItem] {
        let data = try responseData(payload)
        guard let rows = data["data_list"].array else { throw HongguoError(.format, "APP 观看记录格式已变化") }
        let items = rows.compactMap { row -> AccountHistoryItem? in
            if row["is_delete"].bool == true { return nil }
            let seriesId = (row["book_id_str"].idString ?? row["book_id"].idString ?? row["series_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
            let episodeId = (row["vid"].idString ?? row["item_id"].idString ?? "").trimmingCharacters(in: .whitespaces)
            guard seriesId.matchesDigits(min: 1, max: 30), episodeId.matchesDigits(min: 1, max: 30) else { return nil }
            func seconds(_ value: JSONValue) -> Double { max(0, (value.number ?? Double(value.string ?? "") ?? 0) / 1000) }
            func pick(_ a: String, _ b: String) -> JSONValue { row[a].isNull ? row[b] : row[a] }
            let index = row["vid_index"].number.map(Int.init) ?? 0
            let rawTime = row["read_timestamp_ms"].number ?? row["last_watch_time"].number ?? 0
            let millis = rawTime > 0 && rawTime < 10_000_000_000 ? rawTime * 1000 : rawTime
            let title = cleanText(row["series_title"].string ?? row["book_name"].string)
            return AccountHistoryItem(seriesId: seriesId, seriesTitle: title.isEmpty ? "剧集 \(seriesId)" : title,
                                      cover: cleanCover(row["series_cover_url"].string ?? row["thumb_url"].string ?? row["cover"].string),
                                      episodeId: episodeId, episodeIndex: index > 0 ? index : 0,
                                      position: seconds(pick("current_play_position", "current_play_time")),
                                      duration: seconds(pick("duration", "current_total_time")),
                                      updatedAt: Date(timeIntervalSince1970: millis / 1000),
                                      total: max(0, (row["episode_cnt"].number ?? row["episode_count"].number).map(Int.init) ?? 0))
        }
        var seen = Set<String>()
        return items.sorted { $0.updatedAt > $1.updatedAt }.filter { seen.insert($0.seriesId).inserted }.prefix(50).map { $0 }
    }

    /// Error text safe to show: no URLs or session cookies.
    static func safeMessage(_ error: Error, fallback: String = "账号操作失败，请稍后重试") -> String {
        var text = (error as? HongguoError)?.message ?? (error as? AppSourceError)?.message ?? fallback
        text = text.replacingOccurrences(of: "https?://\\S+", with: "[地址]", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "(sessionid|sid_tt|passport_csrf_token)=[^;\\s]+", with: "$1=[已隐藏]", options: [.regularExpression, .caseInsensitive])
        return String(text.prefix(160))
    }

    // MARK: Website requests

    private func webJSON(_ path: String, _ params: [(String, String)] = [], jar: inout CookieJar) async throws -> JSONValue {
        var components = URLComponents(string: Self.webBase + path)!
        var items = Self.webQuery
        for (name, value) in params {
            if let at = items.firstIndex(where: { $0.0 == name }) { items[at].1 = value } else { items.append((name, value)) }
        }
        components.percentEncodedQuery = items.map { "\(AppCrypto.urlEncode($0.0))=\(AppCrypto.urlEncode($0.1))" }.joined(separator: "&")
        var headers = ["User-Agent": Self.webUA, "Referer": Self.webBase + "/", "Origin": Self.webBase,
                       "Accept": "application/json, text/javascript"]
        let cookie = jar.header
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let response = try await webRequest(components.url!, headers)
        jar.absorb(response)
        guard response.status == 200 else { throw HongguoError(.upstream, "红果网页登录请求失败（HTTP \(response.status)）") }
        guard !response.data.isEmpty, response.data.count <= 2 * 1024 * 1024 else { throw HongguoError(.upstream, "红果网页登录响应异常") }
        guard let payload = try? JSONValue.parse(response.data) else { throw HongguoError(.format, "红果网页登录响应格式异常") }
        return payload
    }

    private func finishRedirect(_ value: String, jar: inout CookieJar) async throws {
        guard var url = URL(string: value, relativeTo: URL(string: Self.webBase)!)?.absoluteURL else { throw HongguoError(.security, "登录确认跳转到了不支持的站点") }
        for _ in 0..<5 {
            guard url.scheme == "https", let host = url.host?.lowercased(), host == "hongguoduanju.com" || host.hasSuffix(".hongguoduanju.com") else {
                throw HongguoError(.security, "登录确认跳转到了不支持的站点")
            }
            let response = try await webRequest(url, ["User-Agent": Self.webUA, "Referer": Self.webBase + "/", "Cookie": jar.header])
            jar.absorb(response)
            if [301, 302, 303, 307, 308].contains(response.status), let location = response.header("Location"),
               let next = URL(string: location, relativeTo: url)?.absoluteURL {
                url = next
                continue
            }
            guard response.status == 200 else { throw HongguoError(.upstream, "登录确认失败（HTTP \(response.status)）") }
            return
        }
        throw HongguoError(.upstream, "登录确认跳转次数过多")
    }

    private func verify(_ cookie: String) async throws -> AccountProfile {
        var jar = CookieJar(cookie)
        return try Self.parseProfile(try await webJSON("/passport/account/info/v2/", jar: &jar))
    }

    // MARK: Public API

    /// Signed-in profile, restoring the saved login on first use. A saved profile shows at once;
    /// the cookie is checked in the background and dropped only when the website rejects it.
    public func status() async -> (profile: AccountProfile?, error: String) {
        guard !restored else { return (profile, restoreError) }
        restored = true
        do {
            guard let saved = try store.load() else { return (nil, "") }
            let token = generation
            if let cached = saved.profile, cached.id.matchesDigits(min: 1, max: 30) {
                credentials = saved
                profile = cached
                Task { await self.revalidate(saved, token: token) }
                return (cached, "")
            }
            let next = try await verify(saved.cookie)
            guard token == generation else { return (profile, "") }
            credentials = saved
            profile = next
            try? store.save(AccountCredentials(cookie: saved.cookie, profile: next))
            return (next, "")
        } catch {
            restoreError = Self.safeMessage(error, fallback: "上次登录暂时无法恢复")
            return (nil, restoreError)
        }
    }

    private func revalidate(_ saved: AccountCredentials, token: Int) async {
        do {
            let next = try await verify(saved.cookie)
            guard token == generation else { return }
            profile = next
            try? store.save(AccountCredentials(cookie: saved.cookie, profile: next))
        } catch {
            guard token == generation else { return }
            let message = Self.safeMessage(error)
            guard message.range(of: "会话过期|登录态未通过|账号编号无效|HTTP\\s*(401|403)", options: .regularExpression) != nil else { return }
            credentials = nil
            profile = nil
            cachedHistory = nil
            try? store.clear()
        }
    }

    private func signIn(cookie: String, profile next: AccountProfile) -> String {
        var warning = ""
        do { try store.save(AccountCredentials(cookie: cookie, profile: next)) } catch { warning = Self.safeMessage(error) }
        credentials = AccountCredentials(cookie: cookie, profile: next)
        profile = next
        cachedHistory = nil
        generation += 1
        restored = true
        restoreError = ""
        return warning
    }

    /// Finishes a sign-in done in a web view: `cookie` is the site's cookies as a header value.
    public func completeWebLogin(cookie: String) async throws -> AccountLoginStatus {
        loginGeneration += 1
        let attempt = loginGeneration, token = generation
        login = nil
        guard CookieJar(cookie).hasSession else { throw HongguoError(.input, "未检测到登录态，请先在网页里完成登录") }
        let next = try await verify(cookie)
        guard attempt == loginGeneration, token == generation else { return .cancelled }
        return .signedIn(next, storageWarning: signIn(cookie: cookie, profile: next))
    }

    public func startLogin() async throws -> AccountLoginQR {
        loginGeneration += 1
        let attempt = loginGeneration
        login = nil
        var jar = CookieJar()
        let payload = try await webJSON("/passport/web/get_qrcode/", [("next", Self.webBase + "/")], jar: &jar)
        guard attempt == loginGeneration else { throw HongguoError(.cancelled, "扫码已取消，请重新获取二维码") }
        let qr = try Self.parseQR(payload, now: now())
        let id = UUID().uuidString
        login = (id, qr.token, jar, now().addingTimeInterval(TimeInterval(qr.expiresIn)))
        return AccountLoginQR(loginId: id, image: qr.image, expiresIn: qr.expiresIn)
    }

    /// Call every 2 s or so while the QR code is shown.
    public func pollLogin(_ loginId: String) async throws -> AccountLoginStatus {
        guard let current = login, current.id == loginId else { throw HongguoError(.input, "扫码会话已失效，请重新获取二维码") }
        if now() >= current.expiresAt { login = nil; return .expired }
        let attempt = loginGeneration
        func stillCurrent() -> Bool { login?.id == current.id && attempt == loginGeneration }
        var jar = current.jar
        let data = try Self.responseData(try await webJSON("/passport/web/check_qrconnect/",
                                                           [("next", Self.webBase + "/"), ("token", current.token)], jar: &jar))
        guard stillCurrent() else { return .cancelled }
        login?.jar = jar
        let status = data["status"].idString ?? data["status"].string ?? ""
        if status == "5" || status == "expired" { login = nil; return .expired }
        guard status == "3" || status == "confirmed" else { return .pending }
        if let redirect = data["redirect_url"].string, !redirect.isEmpty { try await finishRedirect(redirect, jar: &jar) }
        guard stillCurrent() else { return .cancelled }
        login?.jar = jar
        guard jar.hasSession else { return .pending }
        let next = try await verify(jar.header)
        guard stillCurrent() else { return .cancelled }
        login = nil
        return .signedIn(next, storageWarning: signIn(cookie: jar.header, profile: next))
    }

    public func cancelLogin(_ loginId: String? = nil) {
        if let loginId, let login, login.id != loginId { return }
        loginGeneration += 1
        login = nil
    }

    /// Signs out and deletes the saved login. Returns a warning when the Keychain item could not be removed.
    @discardableResult
    public func logout() -> String {
        loginGeneration += 1
        generation += 1
        credentials = nil
        profile = nil
        cachedHistory = nil
        login = nil
        restored = true
        restoreError = ""
        do { try store.clear(); return "" } catch { return Self.safeMessage(error) }
    }

    /// The account's App watch history (latest per series, up to 50). Empty when signed out.
    public func history(refresh: Bool = false) async throws -> [AccountHistoryItem] {
        _ = await status()
        guard let current = credentials, profile != nil else { return [] }
        if let cachedHistory, !refresh { return cachedHistory }
        let token = generation
        let device = try await identity()
        guard token == generation else { return [] }
        let signed = try AppLegacySigner.shared.account(path: "/reading/bookapi/read_history/list/v1/", values: [
            ("book_type", "2"), ("limit", "0"), ("offset", "0"), ("last_min_read_timestamp_ms", "0"),
            ("full_field", "true"), ("is_first_load", "true"), ("query_soft_deleted", "false"),
        ], identity: device, nowMillis: Int64(now().timeIntervalSince1970 * 1000))
        let rows = try Self.parseHistory(try await accountRequest(signed.url, signed.headers + [("Cookie", current.cookie)]))
        guard token == generation else { return [] }
        cachedHistory = rows
        return rows
    }

    /// The account's history row for one series, from the last fetched history.
    public func historyRow(seriesId: String) -> AccountHistoryItem? {
        cachedHistory?.first { $0.seriesId == seriesId }
    }
}

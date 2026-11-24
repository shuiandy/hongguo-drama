// SPDX-License-Identifier: GPL-3.0-only
// Persistent single-device identity + BDInstall-aligned 6-hour renewal, activation
// (`app_alert_check`), `x-tt-dt` (`device_token`), and logged-in Cookie helper shared across all
// Hongguo API channels of every app (Mac, iOS, tvOS). Mirrors official iOS 7.4.3 `BDInstall`
// (`_needRegsiter` = 21600 s, `registerDeviceBaseURL`, `activateDeviceBaseURL`, `addDTokenForRequest:`).
// Registration envelope and ttEncrypt adapted from src/native/playback-device.js, itself from
// tsukiyo-zero/hongguoTV commit 388931852ddc614db8b00775a3dc54c5ede6307f,
// kotlin-tv/core/src/main/kotlin/com/hongguotv/core/DeviceRegister.kt
// (adapted from charlie901208/HGTV feat/phone-login, GPL-3.0-only).
// Never logs device IDs, device tokens, or cookies.
import Foundation
import Security

/// The App identity a request is signed with: the persistent device's ids.
struct PlaybackIdentity: Sendable, Equatable, Codable {
    var deviceId: String
    var iid: String
    var cdid: String
}

public actor PersistentAppDevice {
    public static let shared = PersistentAppDevice()

    /// Official `BDInstall._needRegsiter` re-registration interval: 21600 s (6 hours).
    public static let renewalInterval: TimeInterval = 21_600
    /// Minimum spacing between on-demand recovery renewals triggered by empty replies.
    private static let minRefreshInterval: TimeInterval = 30
    /// Minimum spacing between full fresh-device resets when even renewal returns empty.
    public static let minFreshResetInterval: TimeInterval = 120

    private static let keychainService = "io.github.shuiandy.hongguo-drama.device"
    private static let keychainAccount = "primary"
    private static let defaultsKey = "HongguoPersistentDeviceIdentity.v1"

    private static let primaryRegisterBase = "https://log5-applog-lf.fqnovel.com/service/2/device_register/"
    private static let fallbackRegisterBase = "https://log.snssdk.com/service/2/device_register/"
    private static let activateBase = "https://ichannel.snssdk.com/service/2/app_alert_check/"
    private static let registerUA = AppSource.iosPlayerUA
    /// ttEncrypt key derivation salt of `device_register`.
    static let kdfSalt = AppCrypto.fromHex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")!

    /// A numeric id from a `device_register` reply (`<name>_str` first), "" when absent or invalid.
    static func responseId(_ response: JSONValue, _ name: String) -> String {
        let preferred = response["\(name)_str"]
        let value: JSONValue = (preferred.isNull || preferred == .string("")) ? response[name] : preferred
        switch value {
        case .int(let i): return i > 0 && i <= 9_007_199_254_740_991 ? String(i) : ""
        case .double(let d): return d > 0 && d.rounded() == d && d <= 9_007_199_254_740_991 ? String(Int64(d)) : ""
        case .string(let s):
            return s.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil && s.contains(where: { $0 != "0" }) ? s : ""
        default: return ""
        }
    }

    /// Optional diagnostic hook for lifecycle events (status/booleans only, never secrets).
    public nonisolated(unsafe) static var onLog: (@Sendable (String) -> Void)?

    /// Persisted BDInstall-like record. Optional fields keep backward compatibility with v1 records.
    public struct StoredRecord: Codable, Equatable, Sendable {
        public let deviceId: String
        public let iid: String
        public let cdid: String
        public var openudid: String?
        public var clientudid: String?
        public var deviceToken: String?
        public var klinkEgdi: String?
        public var isActivated: Bool?
        public var lastRegisteredAt: Date?
        public var firstInstallTimeMs: Int64?
        /// Platform recorded at registration (`"iphone"` for official iOS 7.4.3 `BDInstall`);
        /// legacy non-iOS records trigger a one-time fresh iOS registration.
        public var platform: String?
        /// Guest cookies `device_register` sets (`ttreq`, `store-region`, `store-region-src`),
        /// echoed on playback requests when present. Nil on records saved before this field existed.
        public var guestCookies: [String: String]?

        public init(deviceId: String, iid: String, cdid: String,
                    openudid: String? = nil, clientudid: String? = nil,
                    deviceToken: String? = nil, klinkEgdi: String? = nil,
                    isActivated: Bool? = nil, lastRegisteredAt: Date? = nil,
                    firstInstallTimeMs: Int64? = nil, platform: String? = "iphone",
                    guestCookies: [String: String]? = nil) {
            self.deviceId = deviceId
            self.iid = iid
            self.cdid = cdid
            self.openudid = openudid
            self.clientudid = clientudid
            self.deviceToken = deviceToken
            self.klinkEgdi = klinkEgdi
            self.isActivated = isActivated
            self.lastRegisteredAt = lastRegisteredAt
            self.firstInstallTimeMs = firstInstallTimeMs
            self.platform = platform
            self.guestCookies = guestCookies
        }

        /// Mirrors `-[BDInstall _needRegsiter]`: re-register if >6 hours old, missing `device_token`,
        /// never activated via `app_alert_check`, or still on a legacy non-iOS registration.
        public func needsRenewal(now: Date = Date(), interval: TimeInterval = PersistentAppDevice.renewalInterval) -> Bool {
            guard let lastRegisteredAt else { return true }
            if now.timeIntervalSince(lastRegisteredAt) >= interval { return true }
            if (deviceToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            if isActivated != true { return true }
            if platform != "iphone" { return true }
            return false
        }

        var playbackIdentity: PlaybackIdentity {
            PlaybackIdentity(deviceId: deviceId, iid: iid, cdid: cdid)
        }
    }

    private var record: StoredRecord?
    private var inflight: Task<StoredRecord, Error>?
    private var inflightIsFresh = false
    private var backgroundRenewTask: Task<Void, Never>?
    private var lastBackgroundRenewFailureAt = Date.distantPast
    private static let backgroundRenewCooldown: TimeInterval = 60
    private var lastRefreshAt = Date.distantPast
    private var lastFreshResetAt = Date.distantPast
    private var resetGeneration: UInt64 = 0
    private var loadedFromStore = false
    private let freshRegisterOverride: (@Sendable () async throws -> StoredRecord)?

    public init() {
        self.freshRegisterOverride = nil
    }

    init(initialRecord: StoredRecord?, freshRegister: @escaping @Sendable () async throws -> StoredRecord) {
        self.record = initialRecord
        self.loadedFromStore = true
        self.freshRegisterOverride = freshRegister
    }

    /// Monotonic generation bumped after each fresh device reset, used to coalesce concurrent
    /// callers failing on the same unusable device into a single fresh registration.
    func currentGeneration() -> UInt64 {
        resetGeneration
    }

    /// Returns the persistent device identity immediately if stored (kicking off a non-blocking
    /// 6-hour `BDInstall` renewal in the background when due), or registers and activates once
    /// if no device is stored yet.
    func get(transport: AppTransport) async throws -> PlaybackIdentity {
        if let existing = currentRecord() {
            if existing.needsRenewal() {
                scheduleBackgroundRenewal(transport: transport)
            }
            return existing.playbackIdentity
        }
        return try await registerOrRenew(existing: nil, transport: transport).playbackIdentity
    }

    /// Called on app launch and foreground resume (`scenePhase == .active`), mirroring
    /// `-[BDInstall startRegisterDeviceWithSuccess:failure:]`. Never throws.
    public func ensureFresh(http: HTTPClient = .shared) async {
        let transport = AppTransport(http: http)
        if let existing = currentRecord() {
            guard existing.needsRenewal() else { return }
            _ = try? await registerOrRenew(existing: existing, transport: transport)
        } else {
            _ = try? await registerOrRenew(existing: nil, transport: transport)
        }
    }

    /// Synchronously refreshes the persisted device via `device_register` (passing existing
    /// `device_id`) + `app_alert_check` when a playback request encounters an empty reply.
    /// Rate-limited to `minRefreshInterval` (30 s). Returns `true` if a renewal actually ran.
    @discardableResult
    func refreshForRecovery(transport: AppTransport) async throws -> (identity: PlaybackIdentity, refreshed: Bool) {
        let existing = currentRecord()
        let now = Date()
        guard now.timeIntervalSince(lastRefreshAt) >= Self.minRefreshInterval || existing == nil || existing?.needsRenewal(now: now) == true else {
            if let existing { return (existing.playbackIdentity, false) }
            let fresh = try await registerOrRenew(existing: nil, transport: transport)
            return (fresh.playbackIdentity, true)
        }
        lastRefreshAt = now
        let updated = try await registerOrRenew(existing: existing, transport: transport)
        return (updated.playbackIdentity, true)
    }

    /// Discards the persisted device identity and registers + activates a brand-new device when
    /// even `refreshForRecovery` still yields empty or 403 replies. Concurrent callers that failed
    /// on the same generation (`expectedGeneration`) coalesce onto a single registration; after a
    /// successful reset, further resets are rate-limited to `minFreshResetInterval` (120 s).
    @discardableResult
    func resetFreshForRecovery(
        fromGeneration expectedGeneration: UInt64,
        transport: AppTransport,
        now: Date = Date()
    ) async throws -> (identity: PlaybackIdentity, reset: Bool) {
        if resetGeneration != expectedGeneration, let existing = currentRecord() {
            return (existing.playbackIdentity, true)
        }
        if let inflight, inflightIsFresh {
            let fresh = try await inflight.value
            return (fresh.playbackIdentity, true)
        }
        if now.timeIntervalSince(lastFreshResetAt) < Self.minFreshResetInterval, let existing = currentRecord() {
            return (existing.playbackIdentity, false)
        }
        let fresh = try await registerOrRenew(existing: nil, transport: transport, resetClock: now)
        return (fresh.playbackIdentity, true)
    }

    /// Device metadata sent on playback requests: registration `openudid`, optional guest cookies,
    /// `device_token` (`x-tt-dt`), and persisted `firstInstallTimeMs`.
    func playSessionContext() -> (openudid: String, cookies: [String: String]?, dToken: String, firstInstallTimeMs: Int64?) {
        let current = currentRecord()
        let token = current?.deviceToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (current?.openudid ?? "", current?.guestCookies, token, current?.firstInstallTimeMs)
    }

    /// Case-insensitive `Set-Cookie` lookup over raw `HTTPURLResponse` header maps (Foundation
    /// preserves `"Set-Cookie"` casing on HTTP/1.1 replies).
    static func guestCookies(fromHeaders headers: [String: String]) -> [String: String] {
        guard let raw = headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame })?.value else {
            return [:]
        }
        return guestCookies(fromSetCookie: raw)
    }

    /// The guest cookies a `device_register` reply sets that playback requests echo. `Set-Cookie`
    /// arrives folded into one header (joined by ", "), so split on both "," and ";".
    static func guestCookies(fromSetCookie header: String) -> [String: String] {
        var jar: [String: String] = [:]
        for part in header.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, ["ttreq", "store-region", "store-region-src"].contains(pair[0]), !pair[1].isEmpty else { continue }
            jar[pair[0]] = pair[1]
        }
        return jar
    }

    /// Returns `[("x-tt-dt", deviceToken)]` when a `device_token` is available, matching
    /// `+[BDInstall addDTokenForRequest:]`.
    func dTokenHeaders() -> [(String, String)] {
        let token = dTokenValue()
        guard !token.isEmpty else { return [] }
        return [("x-tt-dt", token)]
    }

    /// Returns the trimmed `device_token` string, or `""` when not yet issued.
    func dTokenValue() -> String {
        currentRecord()?.deviceToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func currentRecord() -> StoredRecord? {
        if let record { return record }
        if !loadedFromStore {
            loadedFromStore = true
            if let persisted = Self.loadPersisted() {
                record = persisted
                return persisted
            }
        }
        return nil
    }

    private func scheduleBackgroundRenewal(transport: AppTransport) {
        guard backgroundRenewTask == nil, inflight == nil else { return }
        guard Date().timeIntervalSince(lastBackgroundRenewFailureAt) >= Self.backgroundRenewCooldown else { return }
        let existing = record
        backgroundRenewTask = Task { [weak self] in
            guard let self else { return }
            let succeeded = (try? await self.registerOrRenew(existing: existing, transport: transport)) != nil
            await self.finishBackgroundRenewTask(succeeded: succeeded)
        }
    }

    private func finishBackgroundRenewTask(succeeded: Bool) {
        backgroundRenewTask = nil
        if !succeeded {
            lastBackgroundRenewFailureAt = Date()
        } else {
            lastBackgroundRenewFailureAt = .distantPast
        }
    }

    private func registerOrRenew(existing: StoredRecord?, transport: AppTransport, resetClock: Date? = nil) async throws -> StoredRecord {
        let wantsFresh = existing == nil
        if let inflight, (!wantsFresh || inflightIsFresh) {
            return try await inflight.value
        }
        let label = wantsFresh ? "register" : "renew"
        let baseRecord = existing?.platform == "iphone" ? existing : nil
        let override = wantsFresh ? freshRegisterOverride : nil
        let task = Task<StoredRecord, Error> {
            if let override {
                return try await override()
            }
            var updated = try await Self.performRegister(existing: baseRecord, transport: transport)
            let activated = await Self.performActivate(record: updated, transport: transport)
            if activated {
                updated.isActivated = true
            } else if updated.deviceId != baseRecord?.deviceId {
                updated.isActivated = false
            }
            Self.savePersisted(updated)
            Self.onLog?("device \(label) ok activated=\(updated.isActivated == true) dtoken=\(!(updated.deviceToken ?? "").isEmpty)")
            return updated
        }
        inflight = task
        inflightIsFresh = wantsFresh
        do {
            let value = try await task.value
            record = value
            if wantsFresh {
                resetGeneration &+= 1
                if let resetClock {
                    lastFreshResetAt = resetClock
                }
            }
            if inflight == task {
                inflight = nil
                inflightIsFresh = false
            }
            return value
        } catch {
            if inflight == task {
                inflight = nil
                inflightIsFresh = false
            }
            Self.onLog?("device \(label) failed")
            throw error
        }
    }

    // MARK: - BDInstall Wire Protocol (device_register + app_alert_check)

    private static func performRegister(existing: StoredRecord?, transport: AppTransport) async throws -> StoredRecord {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let firstInstallTime = existing?.firstInstallTimeMs ?? now
        let cdid = existing?.cdid ?? AppCrypto.uuid()
        let vendorId = existing?.clientudid ?? AppCrypto.uuid().uppercased()
        let openudid = existing?.openudid ?? AppCrypto.hex(AppCrypto.randomBytes(20))
        let wasActivated = existing?.isActivated == true

        // Official iOS 7.4.3 `BDInstallNetworkUtility +onTheFlyParameter` (`com.phoenix.video`,
        // `novelread`, `App Store`, `7.4.3`, `sdk_version=1120`, `os=iOS`, `device_platform=iphone`).
        var header: [String: Any] = [
            "package": "com.phoenix.video",
            "display_name": "红果短剧",
            "app_name": "novelread",
            "app_version": "7.4.3",
            "app_version_minor": "7.4.3.33",
            "aid": "8662",
            "channel": "App Store",
            "sdk_version": 1120,
            "os": "iOS",
            "os_version": "18.3",
            "device_platform": "iphone",
            "device_model": "iPhone17,1",
            "model_display_name": "iPhone 16 Pro",
            "resolution": "1206*2622",
            "language": "zh",
            "app_language": "zh-Hans",
            "region": "CN",
            "app_region": "CN",
            "timezone": 8,
            "tz_name": "Asia/Shanghai",
            "tz_offset": 28800,
            "access": "wifi",
            "is_jailbroken": false,
            "is_upgrade_user": false,
            "cdid": cdid,
            "vendor_id": vendorId,
            "openudid": openudid,
            "idfa": "00000000-0000-0000-0000-000000000000",
            "auth_status": 0,
            "user_agent": registerUA,
            "custom": ["account_region_src": "fallback", "account_region": "cn", "dragon_device_type": "phone"],
        ]
        if let oldDid = existing?.deviceId, !oldDid.isEmpty {
            header["device_id"] = oldDid
            header["old_did"] = oldDid
        }
        if let oldIid = existing?.iid, !oldIid.isEmpty {
            header["install_id"] = oldIid
        }
        if let oldToken = existing?.deviceToken, !oldToken.isEmpty {
            header["device_token"] = oldToken
        }

        let envelope: [String: Any] = ["magic_tag": "ss_app_log", "header": header, "_gen_time": now]
        let json = try JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes])
        let compressed = try AppCrypto.gzip(Array(json))
        let random = AppCrypto.randomBytes(32)
        let derived = AppCrypto.sha512(AppCrypto.sha512(random) + kdfSalt)
        let plaintext = AppCrypto.sha512(compressed) + compressed
        let cipher = try AppCrypto.aes128CBC(encrypt: true, key: Array(derived[0..<16]), iv: Array(derived[16..<32]),
                                             plaintext, pkcs7: true)
        let body = AppCrypto.fromHex("746305100000")! + random + cipher
        let headers: [(String, String)] = [
            ("User-Agent", registerUA),
            ("Accept", "application/json"),
            ("Content-Type", "application/octet-stream;tt-data=a"),
            ("log-encode-type", "gzip"),
            ("x-ss-dp", "8662"),
            ("x-ss-req-ticket", String(now)),
            ("sdk-version", "2"),
            ("x-ss-stub", AppCrypto.hex(AppCrypto.md5(body), uppercase: true)),
        ]

        var primaryQuery: [(String, String)] = [
            ("is_activated", wasActivated ? "1" : "0"),
            ("aid", "8662"),
            ("app_name", "novelread"),
            ("channel", "App Store"),
            ("device_platform", "iphone"),
            ("os_version", "18.3"),
            ("version_code", "7.4.3"),
            ("vid", vendorId),
            ("ac", "wifi"),
            ("timezone", "8"),
            ("is_upgrade_user", "0"),
            ("tt_data", "a"),
        ]
        var fallbackQuery: [(String, String)] = [
            ("aid", "8662"),
            ("app_name", "novelread"),
            ("channel", "App Store"),
            ("device_platform", "iphone"),
            ("os_version", "18.3"),
            ("version_code", "7.4.3"),
            ("is_activated", wasActivated ? "1" : "0"),
            ("tt_data", "a"),
        ]
        if let did = existing?.deviceId, !did.isEmpty {
            primaryQuery.insert(("device_id", did), at: 0)
            fallbackQuery.insert(("device_id", did), at: 0)
        }
        let urls = [
            "\(primaryRegisterBase)?\(AppCrypto.encodeQuery(primaryQuery))",
            "\(fallbackRegisterBase)?\(AppCrypto.encodeQuery(fallbackQuery))",
        ]

        var lastError: Error = AppSourceError(.deviceRegistrationFailed, "设备注册失败")
        let deadline = Date().addingTimeInterval(8)
        for url in urls {
            guard deadline.timeIntervalSinceNow >= 1 else { break }
            do {
                let (response, responseHeaders) = try await transport.requestJSONWithHeaders(
                    url, method: "POST", headers: headers, body: body, deadline: deadline
                )
                if !response["code"].isZeroOrMissingStatusCode || !response["Code"].isZeroOrMissingStatusCode {
                    throw AppSourceError(.businessRejected, "Registration rejected")
                }
                let deviceId = responseId(response, "device_id")
                let iid = responseId(response, "install_id")
                guard !deviceId.isEmpty, !iid.isEmpty else {
                    throw AppSourceError(.invalidResponse, "Invalid registration")
                }
                let token = response["device_token"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
                let egdi = response["klink_egdi"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
                let stillActivated = wasActivated && deviceId == existing?.deviceId
                let cookies = Self.guestCookies(fromHeaders: responseHeaders)
                return StoredRecord(
                    deviceId: deviceId,
                    iid: iid,
                    cdid: cdid,
                    openudid: openudid,
                    clientudid: vendorId,
                    deviceToken: (token?.isEmpty == false ? token : existing?.deviceToken),
                    klinkEgdi: (egdi?.isEmpty == false ? egdi : existing?.klinkEgdi),
                    isActivated: stillActivated,
                    lastRegisteredAt: Date(),
                    firstInstallTimeMs: firstInstallTime,
                    platform: "iphone",
                    guestCookies: cookies.isEmpty ? existing?.guestCookies : cookies
                )
            } catch let error as AppSourceError where error.code == .cancelled {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func performActivate(record: StoredRecord, transport: AppTransport) async -> Bool {
        var params: [(String, String)] = [
            ("aid", "8662"),
            ("app_name", "novelread"),
            ("channel", "App Store"),
            ("device_platform", "iphone"),
            ("os_version", "18.3"),
            ("version_code", "7.4.3"),
            ("device_id", record.deviceId),
            ("iid", record.iid),
            ("cdid", record.cdid),
            ("vid", record.clientudid ?? ""),
            ("ac", "wifi"),
            ("timezone", "8"),
            ("is_activated", record.isActivated == true ? "1" : "0"),
        ]
        var headers: [(String, String)] = [("User-Agent", registerUA)]
        if let token = record.deviceToken, !token.isEmpty {
            params.append(("device_token", token))
            headers.append(("x-tt-dt", token))
        }
        let url = "\(activateBase)?\(AppCrypto.encodeQuery(params))"
        guard let response = try? await transport.requestJSON(url, method: "GET", headers: headers,
                                                              deadline: Date().addingTimeInterval(6)) else {
            return false
        }
        let msg = response["message"].string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !msg.isEmpty { return msg == "success" }
        if let code = response["code"].signedInt ?? response["Code"].signedInt { return code == 0 }
        return false
    }

    // MARK: - Auth Cookie Helper

    private static var isMacTestRunner: Bool { MacTestRunner.isActive }
    private static let authCookieCache = LockedValue<(loaded: Bool, cookie: String)>((false, ""))

    /// Clears the cached auth cookie after sign-in, sign-out, or session expiration.
    static func invalidateAuthCache() {
        authCookieCache.withLock { $0 = (false, "") }
    }

    /// Returns the saved login Cookie header when signed in, or empty when anonymous.
    static func authHeaders() -> [(String, String)] {
        guard !isMacTestRunner else { return [] }
        let cached: String? = authCookieCache.withLock { state in
            state.loaded ? state.cookie : nil
        }
        let cookie: String
        if let cached {
            cookie = cached
        } else {
            let loaded = (try? KeychainCredentialStore().load())?.cookie.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            authCookieCache.withLock { $0 = (true, loaded) }
            cookie = loaded
        }
        guard !cookie.isEmpty else { return [] }
        return [("Cookie", cookie)]
    }

    static var isSignedIn: Bool {
        !authHeaders().isEmpty
    }

    /// The identity and `device_token` for every data request (search, account, catalogue, book
    /// mall, comments, danmaku). There is no other device.
    static func dataIdentity(transport: AppTransport) async throws -> (identity: PlaybackIdentity, dToken: String) {
        let identity = try await shared.get(transport: transport)
        let token = await shared.dTokenValue()
        return (identity, token)
    }

    // MARK: - Keychain Persistence

    public static func decodeRecord(_ data: Data) -> StoredRecord? {
        guard let stored = try? JSONDecoder().decode(StoredRecord.self, from: data),
              stored.deviceId.matchesDigits(min: 6, max: 30),
              stored.iid.matchesDigits(min: 6, max: 30),
              !stored.cdid.isEmpty else {
            return nil
        }
        return stored
    }

    public static func encodeRecord(_ record: StoredRecord) -> Data? {
        try? JSONEncoder().encode(record)
    }

    private static func loadPersisted() -> StoredRecord? {
        if let data = readKeychain(), let decoded = decodeRecord(data) {
            return decoded
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let decoded = decodeRecord(data) {
            return decoded
        }
        return nil
    }

    private static func savePersisted(_ record: StoredRecord) {
        guard let data = encodeRecord(record) else { return }
        if !writeKeychain(data) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func readKeychain() -> Data? {
        guard !isMacTestRunner else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeKeychain(_ data: Data) -> Bool {
        guard !isMacTestRunner else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var insert = baseQuery
        for (k, v) in attributes { insert[k] = v }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

/// Whether this process runs tests on a Mac. Test processes never touch the Keychain: the items
/// belong to the Mac app, so reading or updating them from `xctest` brings up an access prompt that
/// blocks the device actor until someone answers it. `swift test` does not set
/// `XCTestConfigurationFilePath` (only Xcode does), so the process name and the loaded XCTest
/// classes count too.
enum MacTestRunner {
    static let isActive: Bool = {
        #if os(macOS)
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil { return true }
        if ProcessInfo.processInfo.processName == "xctest" { return true }
        return NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }()
}

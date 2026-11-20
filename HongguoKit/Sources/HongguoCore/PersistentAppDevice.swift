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

    private static let keychainService = "io.github.shuiandy.hongguo-drama.device"
    private static let keychainAccount = "primary"
    private static let defaultsKey = "HongguoPersistentDeviceIdentity.v1"

    private static let primaryRegisterBase = "https://log5-applog-lf.fqnovel.com/service/2/device_register/"
    private static let fallbackRegisterBase = "https://log.snssdk.com/service/2/device_register/"
    private static let activateBase = "https://ichannel.snssdk.com/service/2/app_alert_check/"
    private static let registerUA = "com.phoenix.read/74332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
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

        public init(deviceId: String, iid: String, cdid: String,
                    openudid: String? = nil, clientudid: String? = nil,
                    deviceToken: String? = nil, klinkEgdi: String? = nil,
                    isActivated: Bool? = nil, lastRegisteredAt: Date? = nil) {
            self.deviceId = deviceId
            self.iid = iid
            self.cdid = cdid
            self.openudid = openudid
            self.clientudid = clientudid
            self.deviceToken = deviceToken
            self.klinkEgdi = klinkEgdi
            self.isActivated = isActivated
            self.lastRegisteredAt = lastRegisteredAt
        }

        /// Mirrors `-[BDInstall _needRegsiter]`: re-register if >6 hours old, missing `device_token`,
        /// or never activated via `app_alert_check`.
        public func needsRenewal(now: Date = Date(), interval: TimeInterval = PersistentAppDevice.renewalInterval) -> Bool {
            guard let lastRegisteredAt else { return true }
            if now.timeIntervalSince(lastRegisteredAt) >= interval { return true }
            if (deviceToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            if isActivated != true { return true }
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
    private var lastRefreshAt = Date.distantPast
    private var loadedFromStore = false

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
        let existing = record
        backgroundRenewTask = Task { [weak self] in
            defer { Task { await self?.clearBackgroundRenewTask() } }
            guard let self else { return }
            _ = try? await self.registerOrRenew(existing: existing, transport: transport)
        }
    }

    private func clearBackgroundRenewTask() {
        backgroundRenewTask = nil
    }

    private func registerOrRenew(existing: StoredRecord?, transport: AppTransport) async throws -> StoredRecord {
        let wantsFresh = existing == nil
        if let inflight, (!wantsFresh || inflightIsFresh) {
            return try await inflight.value
        }
        let label = wantsFresh ? "register" : "renew"
        let task = Task<StoredRecord, Error> {
            var updated = try await Self.performRegister(existing: existing, transport: transport)
            let activated = await Self.performActivate(record: updated, transport: transport)
            if activated { updated.isActivated = true }
            Self.savePersisted(updated)
            Self.onLog?("device \(label) ok activated=\(updated.isActivated == true) dtoken=\(!(updated.deviceToken ?? "").isEmpty)")
            return updated
        }
        inflight = task
        inflightIsFresh = wantsFresh
        do {
            let value = try await task.value
            record = value
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
        let cdid = existing?.cdid ?? AppCrypto.uuid()
        let openudid = existing?.openudid ?? AppCrypto.hex(AppCrypto.randomBytes(8))
        let clientudid = existing?.clientudid ?? AppCrypto.uuid()
        let wasActivated = existing?.isActivated == true

        var header: [String: Any] = [
            "display_name": "红果免费短剧", "update_version_code": 74332, "manifest_version_code": 74332,
            "app_version_minor": "7.4.3.32", "aid": 8662, "channel": "update_64", "package": "com.phoenix.read",
            "app_version": "7.4.3.32", "version_code": 74332, "sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo",
            "sdk_target_version": 29, "git_hash": "3a88f4e", "os": "Android", "os_version": "16", "os_api": 36,
            "device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Redmi",
            "cpu_abi": "arm64-v8a", "release_build": "b5e187f", "density_dpi": 520, "display_density": "mdpi",
            "resolution": "1280x2772", "language": "zh", "timezone": 8, "access": "wifi", "not_request_sender": 0,
            "carrier": "CHINA MOBILE", "mcc_mnc": "46000", "rom": "eng.root.20231116.160340",
            "rom_version": "W528JS release-keys", "cdid": cdid,
            "sig_hash": "56a962410c494bbaf0b58dba20cae56f", "openudid": openudid,
            "clientudid": clientudid, "ipv6_list": [Any](), "region": "CN", "tz_name": "Asia/Shanghai",
            "tz_offset": 28800, "sim_region": "cn", "sim_serial_number": [Any](), "oaid_may_support": false,
            "req_id": AppCrypto.uuid(), "device_platform": "android",
            "custom": ["account_region_src": "fallback", "account_region": "cn", "host_bit": 64, "dragon_device_type": "phone"],
            "pre_installed_channel": "", "apk_first_install_time": now, "is_system_app": 0, "sdk_flavor": "china", "guest_mode": 0,
        ]
        if let oldDid = existing?.deviceId, !oldDid.isEmpty {
            header["old_did"] = oldDid
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
            ("x-vc-bdturing-sdk-version", "4.0.3.cn"),
            ("lc", "101"),
            ("sdk-version", "2"),
            ("passport-sdk-version", "5051452"),
            ("x-neptune", "-8|50:51:59:30:40:47:49:39"),
            ("x-ss-stub", AppCrypto.hex(AppCrypto.md5(body), uppercase: true)),
        ]

        var primaryQuery: [(String, String)] = [
            ("tt_data", "a"),
            ("cronet_version", "8d40f833_2026-03-03"),
            ("ttnet_version", "4.2.243.31-douyin"),
            ("use_store_region_cookie", "1"),
        ]
        var fallbackQuery: [(String, String)] = [
            ("aid", "8662"),
            ("is_activated", wasActivated ? "1" : "0"),
            ("tt_data", "a"),
        ]
        if let did = existing?.deviceId, !did.isEmpty {
            primaryQuery.insert(("device_id", did), at: 0)
            primaryQuery.insert(("is_activated", wasActivated ? "1" : "0"), at: 1)
            primaryQuery.insert(("aid", "8662"), at: 2)
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
                let response = try await transport.requestJSON(url, method: "POST", headers: headers, body: body, deadline: deadline)
                if (response["code"].number ?? response["Code"].number ?? 0) != 0 {
                    throw AppSourceError(.businessRejected, "Registration rejected")
                }
                let deviceId = responseId(response, "device_id")
                let iid = responseId(response, "install_id")
                guard !deviceId.isEmpty, !iid.isEmpty else {
                    throw AppSourceError(.invalidResponse, "Invalid registration")
                }
                let token = response["device_token"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
                let egdi = response["klink_egdi"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
                return StoredRecord(
                    deviceId: deviceId,
                    iid: iid,
                    cdid: cdid,
                    openudid: openudid,
                    clientudid: clientudid,
                    deviceToken: (token?.isEmpty == false ? token : existing?.deviceToken),
                    klinkEgdi: (egdi?.isEmpty == false ? egdi : existing?.klinkEgdi),
                    isActivated: wasActivated,
                    lastRegisteredAt: Date()
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
            ("channel", "update_64"),
            ("device_platform", "android"),
            ("os_version", "16"),
            ("version_code", "74332"),
            ("device_id", record.deviceId),
            ("iid", record.iid),
            ("cdid", record.cdid),
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
        let msg = response["message"].string?.lowercased() ?? ""
        let code = response["code"].number ?? response["Code"].number ?? 0
        return msg == "success" || code == 0
    }

    // MARK: - Auth Cookie Helper

    private static var isMacTestRunner: Bool {
        #if os(macOS)
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        return false
        #endif
    }

    /// Returns the saved login Cookie header when signed in, or empty when anonymous.
    static func authHeaders() -> [(String, String)] {
        guard !isMacTestRunner else { return [] }
        guard let saved = try? KeychainCredentialStore().load() else { return [] }
        let cookie = saved.cookie.trimmingCharacters(in: .whitespacesAndNewlines)
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

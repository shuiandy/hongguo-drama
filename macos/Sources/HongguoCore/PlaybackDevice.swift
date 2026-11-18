// SPDX-License-Identifier: GPL-3.0-only
// Swift port of src/native/playback-device.js.
// ttEncrypt and registration fields adapted from tsukiyo-zero/hongguoTV,
// commit 388931852ddc614db8b00775a3dc54c5ede6307f,
// kotlin-tv/core/src/main/kotlin/com/hongguotv/core/DeviceRegister.kt
// (itself adapted from charlie901208/HGTV feat/phone-login, GPL-3.0-only).
// Changes: fixed anonymous phone profile; process-only identity; no cookies or tokens.
import Foundation

/// Anonymous playback identity returned by the App's device registration. Kept in memory only.
struct PlaybackIdentity: Sendable, Equatable {
    var deviceId: String
    var iid: String
    var cdid: String
}

/// Registers a fresh anonymous device per playback request (identities can be single-use),
/// with a 10 second shared cool-down after any failure. Nothing is written to disk.
actor PlaybackDevice {
    static let shared = PlaybackDevice()

    static let registerURL = "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"
    static let kdfSalt = AppCrypto.fromHex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")!

    private var retryAfter = Date.distantPast
    private var lastFailure: String?

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

    func register(transport: AppTransport) async throws -> PlaybackIdentity {
        if Date() < retryAfter {
            throw AppSourceError(.deviceRegistrationFailed, "匿名播放设备注册失败，请检查网络，10 秒后重试",
                                 registrationFailure: lastFailure)
        }
        do {
            let identity = try await Self.registerOnce(transport: transport)
            retryAfter = .distantPast
            return identity
        } catch let error as AppSourceError where error.code == .cancelled {
            throw error
        } catch {
            let failure = Self.classify(error)
            retryAfter = Date().addingTimeInterval(10)
            lastFailure = failure
            throw AppSourceError(.deviceRegistrationFailed, "匿名播放设备注册失败，请检查网络，10 秒后重试",
                                 registrationFailure: failure)
        }
    }

    static func classify(_ error: Error) -> String {
        guard let e = error as? AppSourceError else { return "UNKNOWN" }
        if let status = e.status, (300...599).contains(status) { return "HTTP_\(status)" }
        switch e.code {
        case .timeout: return "TIMEOUT"
        case .network: return "NETWORK_ERROR"
        case .emptyResponse: return "EMPTY_RESPONSE"
        case .invalidResponse: return "INVALID_RESPONSE"
        case .businessRejected: return "BUSINESS_REJECTED"
        case .securityBlocked: return "SECURITY_BLOCKED"
        default: return "UNKNOWN"
        }
    }

    static func registerOnce(transport: AppTransport) async throws -> PlaybackIdentity {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cdid = AppCrypto.uuid()
        let header: [String: Any] = [
            "display_name": "红果免费短剧", "update_version_code": 73932, "manifest_version_code": 73932,
            "app_version_minor": "7.3.9.32", "aid": 8662, "channel": "update_64", "package": "com.phoenix.read",
            "app_version": "7.3.9.32", "version_code": 73932, "sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo",
            "sdk_target_version": 29, "git_hash": "3a88f4e", "os": "Android", "os_version": "16", "os_api": 36,
            "device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Redmi",
            "cpu_abi": "arm64-v8a", "release_build": "b5e187f", "density_dpi": 520, "display_density": "mdpi",
            "resolution": "1280x2772", "language": "zh", "timezone": 8, "access": "wifi", "not_request_sender": 0,
            "carrier": "CHINA MOBILE", "mcc_mnc": "46000", "rom": "eng.root.20231116.160340",
            "rom_version": "W528JS release-keys", "cdid": cdid,
            "sig_hash": "56a962410c494bbaf0b58dba20cae56f", "openudid": AppCrypto.hex(AppCrypto.randomBytes(8)),
            "clientudid": AppCrypto.uuid(), "ipv6_list": [Any](), "region": "CN", "tz_name": "Asia/Shanghai",
            "tz_offset": 28800, "sim_region": "cn", "sim_serial_number": [Any](), "oaid_may_support": false,
            "req_id": AppCrypto.uuid(), "device_platform": "android",
            "custom": ["account_region_src": "fallback", "account_region": "cn", "host_bit": 64, "dragon_device_type": "phone"],
            "pre_installed_channel": "", "apk_first_install_time": now, "is_system_app": 0, "sdk_flavor": "china", "guest_mode": 0,
        ]
        let envelope: [String: Any] = ["magic_tag": "ss_app_log", "header": header, "_gen_time": now]
        let json = try JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes])
        let compressed = try AppCrypto.gzip(Array(json))
        let random = AppCrypto.randomBytes(32)
        let derived = AppCrypto.sha512(AppCrypto.sha512(random) + kdfSalt)
        let plaintext = AppCrypto.sha512(compressed) + compressed
        let cipher = try AppCrypto.aes128CBC(encrypt: true, key: Array(derived[0..<16]), iv: Array(derived[16..<32]),
                                             plaintext, pkcs7: true)
        let data = AppCrypto.fromHex("746305100000")! + random + cipher
        let headers: [(String, String)] = [
            ("User-Agent", "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"),
            ("Accept", "application/json"), ("Content-Type", "application/octet-stream;tt-data=a"),
            ("log-encode-type", "gzip"), ("x-ss-dp", "8662"), ("x-ss-req-ticket", String(now)),
            ("x-vc-bdturing-sdk-version", "4.0.3.cn"), ("lc", "101"), ("sdk-version", "2"),
            ("passport-sdk-version", "5051452"), ("x-neptune", "-8|50:51:59:30:40:47:49:39"),
            ("x-ss-stub", AppCrypto.hex(AppCrypto.md5(data), uppercase: true)),
        ]
        let response = try await transport.requestJSON(registerURL, method: "POST", headers: headers, body: data,
                                                       deadline: Date().addingTimeInterval(8))
        let deviceId = responseId(response, "device_id")
        let iid = responseId(response, "install_id")
        if (response["code"].number ?? response["Code"].number ?? 0) != 0 {
            throw AppSourceError(.businessRejected, "Registration rejected")
        }
        guard !deviceId.isEmpty, !iid.isEmpty else { throw AppSourceError(.invalidResponse, "Invalid registration") }
        return PlaybackIdentity(deviceId: deviceId, iid: iid, cdid: cdid)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Single-episode play request (`/novel/player/video_model/v1/`) signed with the v04.10.03
// phone-layout `x-medusa` (flags `04 05`, status `369`, per-device derived fingerprint),
// `x-helios`, `x-gorgon` (`04 05`, `0x040a0300`), and the device's real `x-tt-dt` token.
// Live A/B on 2026-11-24 confirmed legacy 551 `x-argus`/`x-ladon` are unnecessary and omitted,
// and `device_level: 1` returns full 1080p HEVC while guarding against ByteVC2 substitution.
import Foundation

enum VideoModelRequest {
    static let base = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/"
    static let versionCode = "73932"
    static let versionName = "7.3.9.32"
    static let channel = "xiaomi_8662_64"
    static let model = "23127PN0CC"
    static let brand = "Xiaomi"
    static let osVersion = "14"
    static let userAgent = "com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; 23127PN0CC; Build/UKQ1.230804.001; "
        + "Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)"

    /// Plain JSON body with `device_level: 1` (defends against server-side ByteVC2 substitution).
    static func payload(vid: String) throws -> [UInt8] {
        guard vid.range(of: "^[0-9]{4,25}$", options: .regularExpression) != nil else {
            throw AppSourceError(.invalidResponse, "无效的分集")
        }
        return Array(#"{"biz_param":{"device_level":1,"need_all_video_definition":true,"video_id_type":0,"video_platform":3},"video_id":"\#(vid)"}"#.utf8)
    }

    static func pairs(identity: PlaybackIdentity, openudid: String) -> [(String, String)] {
        [
            ("iid", identity.iid), ("device_id", identity.deviceId), ("ac", "wifi"), ("channel", channel), ("aid", "8662"),
            ("app_name", "novelread"), ("cdid", identity.cdid), ("version_code", versionCode), ("version_name", versionName),
            ("device_platform", "android"), ("os", "android"), ("ssmix", "a"), ("device_type", model), ("device_brand", brand),
            ("language", "zh"), ("os_api", "34"), ("os_version", osVersion), ("manifest_version_code", versionCode),
            ("resolution", "1200*2670"), ("dpi", "460"), ("update_version_code", versionCode), ("host_abi", "arm64-v8a"),
            ("dragon_device_type", "phone"), ("pv_player", versionCode), ("compliance_status", "0"),
            ("need_personal_recommend", "1"), ("player_so_load", "1"), ("is_android_pad_screen", "0"), ("openudid", openudid),
        ]
    }

    static func cookie(iid: String, guest: [String: String]?) -> String? {
        guard let guest, let ttreq = guest["ttreq"], !ttreq.isEmpty else { return nil }
        return "passport_csrf_token=; passport_csrf_token_default=; store-region=\(guest["store-region"] ?? "")"
            + "; store-region-src=\(guest["store-region-src"] ?? ""); install_id=\(iid); ttreq=\(ttreq)"
    }

    static func request(vid: String, identity: PlaybackIdentity, openudid: String, guest: [String: String]?,
                        dToken: String = "", installMillis: Int64? = nil,
                        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                        signer: PlaybackSignerV5 = .shared, random32: () -> UInt32 = AppCrypto.random32)
        throws -> (url: String, headers: [(String, String)], body: [UInt8]) {
        let body = try payload(vid: vid)
        let bodyMd5 = AppCrypto.md5(body)
        let basePairs = pairs(identity: identity, openudid: openudid)
        for offset in 0..<1024 {
            let ticket = nowMillis + Int64(offset)
            let ts = UInt32(ticket / 1000)
            let query = AppCrypto.encodeQuery(basePairs + [("ts", String(ts)), ("_rticket", String(ticket))])
            let queryHash = AppCrypto.sm3(Array(query.utf8))
            guard PlaybackSignerV5.branch(queryHash, bodyMd5, ts) == 12 else { continue }
            let f13 = try PlaybackSignerV5.hashF13(query: queryHash, body: bodyMd5, ts: ts)
            let who = PlaybackSignerV5.Who(deviceId: identity.deviceId, osVersion: osVersion, deviceType: model,
                                           channel: channel, versionName: versionName, brand: brand,
                                           sdkVersion: "v04.10.03-ml-android")
            let stub = AppCrypto.hex(bodyMd5)
            var headers: [(String, String)] = [
                ("User-Agent", userAgent), ("Accept", "application/json; charset=utf-8,application/x-protobuf"),
                ("x-xs-from-web", "0"), ("x-ss-req-ticket", String(ticket)), ("x-tt-request-tag", "t=0;n=0"),
                ("sdk-version", "2"), ("passport-sdk-version", "50561"), ("x-vc-bdturing-sdk-version", "3.7.2.cn"),
                ("x-khronos", String(ts)),
                ("x-gorgon", AppLegacySigner.xGorgon(query: query, body: body, ts: ts, random: random32() & 0xffff,
                                                     flags: (0x04, 0x05), sdkCode: 0x040a0300)),
                ("x-helios", signer.helios(ts: ts)),
                ("x-medusa", try signer.medusaDevice(query: queryHash, f13: f13, ts: ts, who: who, installMillis: installMillis)),
                ("x-tt-dt", dToken), ("Content-Type", "application/json; charset=UTF-8"), ("x-ss-stub", stub.uppercased()),
                ("x-ss-dp", "8662"), ("lc", "101"), ("x-reading-request", "\(ticket)-\(random32() & 0x7fffffff)"),
            ]
            if let cookie = cookie(iid: identity.iid, guest: guest) { headers.append(("Cookie", cookie)) }
            return ("\(Self.base)?\(query)", headers, body)
        }
        throw HongguoError(.format, "Unable to select the video_model signature branch within 1024 tickets")
    }
}

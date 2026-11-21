import Foundation

/// Raw access to `/reading/bookapi/bookmall/tab/v/` with `AppLegacySigner`'s metadata signing
/// profile (read-only) and the persistent device.
public enum AppBookMallAccess {
    /// Allowed paths for bookmall/discovery legacy signing.
    static let allowedPaths: Set<String> = [
        "/reading/bookapi/bookmall/tab/v/",
        "/reading/bookapi/bookmall/cell/change/v",
        "/reading/bookapi/plan/v/",
        "/reading/user/subscribe/list/v1/",
        "/reading/bookapi/search/suggest/v/",
    ]

    /// GET a bookmall/discovery endpoint with query values. Signed in, the login cookie goes along
    /// as the official app sends it on every request (ranking, calendar and suggestions then match
    /// the account), but only to the official API hosts (`AppTransport.apiDomains`); `authenticated:
    /// false` asks anonymously.
    public static func tab(
        values: [(String, String)],
        host: String? = nil,
        path: String = "/reading/bookapi/bookmall/tab/v/",
        timeout: TimeInterval = 10,
        authenticated: Bool = true
    ) async throws -> JSONValue {
        let transport = AppTransport(http: .shared)
        let deadline = Date().addingTimeInterval(timeout)
        do {
            let device = try await PersistentAppDevice.dataIdentity(transport: transport)
            let base = host ?? AppLegacySigner.metadataHost
            let extraHeaders = authenticated && isOfficialHost(base) ? PersistentAppDevice.authHeaders() : []
            return try await TransientReadRetry.run(deadline: deadline) {
                let signed = try AppLegacySigner.shared.bookMallTab(
                    host: base,
                    path: path,
                    values: values,
                    identity: device.identity,
                    dToken: device.dToken,
                    nowMillis: Int64(Date().timeIntervalSince1970 * 1000)
                )
                return try await transport.requestJSON(
                    signed.url,
                    method: "GET",
                    headers: signed.headers + extraHeaders,
                    body: nil,
                    deadline: deadline
                )
            }
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
    }

    /// HTTPS on one of the official API domains (or a subdomain), nothing else.
    static func isOfficialHost(_ base: String) -> Bool {
        guard let url = URL(string: base), url.scheme?.lowercased() == "https", url.user == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return AppTransport.apiDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

extension AppLegacySigner {
    func bookMallTab(
        host: String,
        path: String,
        values: [(String, String)],
        identity: PlaybackIdentity,
        dToken: String = "",
        nowMillis: Int64
    ) throws -> Signed {
        guard AppBookMallAccess.allowedPaths.contains(path) else {
            throw HongguoError(.security, "不支持的书城接口路径")
        }
        guard identity.deviceId.matchesDigits(min: 6, max: 30),
              identity.iid.matchesDigits(min: 6, max: 30) else {
            throw HongguoError(.input, "设备编号无效")
        }
        let devId = identity.deviceId
        var devicePairs: [(String, String)] = [("iid", identity.iid), ("device_id", devId)]
        if !identity.cdid.isEmpty { devicePairs.append(("cdid", identity.cdid)) }
        let device = Self.merged(Self.versioned(Self.currentVersionCode, Self.currentVersionName), devicePairs)
        let ts = UInt32(nowMillis / 1000)
        let bodyMd5 = [UInt8](repeating: 0, count: 16)
        let fields = Self.merged(values, device)
        let ua = Self.currentMetadataUA
        for n in 0..<128 {
            let ticket = String(nowMillis + Int64(n))
            let query = AppCrypto.encodeQuery(fields + [("ts", String(ts)), ("_rticket", ticket)])
            let url = "\(host)\(path)?\(query)"
            guard Self.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: bodyMd5, ts: ts) == 0 else { continue }
            let headers: [(String, String)] = [
                ("User-Agent", ua),
                ("Accept", "application/json"),
                ("x-xs-from-web", "0"),
                ("sdk-version", "2"),
                ("x-ss-dp", "8662"),
                ("x-tt-store-region", "cn"),
                ("x-tt-store-region-src", "did"),
                ("x-ss-req-ticket", ticket),
                ("x-khronos", String(ts)),
                ("x-gorgon", Self.xGorgon(query: query, body: nil, ts: ts, random: random32() >> 16)),
                ("x-ladon", AppCrypto.base64(AppCrypto.be32Bytes(ts))),
                ("x-argus", AppCrypto.base64(AppCrypto.le32(ts))),
                ("x-helios", helios(ts: ts)),
                ("x-medusa", try medusa(url: url, body: nil, ts: ts, deviceId: devId, versionName: Self.currentVersionName, nowMillis: nowMillis)),
                ("x-tt-dt", dToken),
            ]
            return Signed(url: url, query: query, headers: headers, body: nil)
        }
        throw HongguoError(.format, "无法生成书城推荐流请求签名")
    }
}

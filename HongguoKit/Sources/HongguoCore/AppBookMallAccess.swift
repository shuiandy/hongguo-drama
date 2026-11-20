import Foundation

/// Raw access to `/reading/bookapi/bookmall/tab/v/` using `AppLegacySigner`'s anonymous
/// metadata signing profile (read-only), or the persistent device when
/// `PlatformBehavior.persistentDataDevice` is on.
public enum AppBookMallAccess {
    /// GET /reading/bookapi/bookmall/tab/v/ with query values.
    public static func tab(
        values: [(String, String)],
        host: String? = nil,
        path: String = "/reading/bookapi/bookmall/tab/v/",
        timeout: TimeInterval = 10
    ) async throws -> JSONValue {
        let transport = AppTransport(http: .shared)
        let device = await DataDevice.optional(transport: transport)
        let signed = try AppLegacySigner.shared.bookMallTab(
            host: host ?? AppLegacySigner.metadataHost,
            path: path,
            values: values,
            identity: device.identity,
            dToken: device.dToken,
            nowMillis: Int64(Date().timeIntervalSince1970 * 1000)
        )
        do {
            return try await transport.requestJSON(
                signed.url,
                method: "GET",
                headers: signed.headers + DataDevice.authHeaders,
                body: nil,
                deadline: Date().addingTimeInterval(timeout)
            )
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
    }
}

extension AppLegacySigner {
    func bookMallTab(
        host: String,
        path: String,
        values: [(String, String)],
        identity: PlaybackIdentity? = nil,
        dToken: String = "",
        nowMillis: Int64
    ) throws -> Signed {
        let devId = identity?.deviceId ?? metadataDeviceId
        var devicePairs: [(String, String)] = [("iid", identity?.iid ?? metadataInstallId), ("device_id", devId)]
        if let cdid = identity?.cdid, !cdid.isEmpty { devicePairs.append(("cdid", cdid)) }
        let device = Self.merged(Self.versioned("74532", "7.4.5.32"), devicePairs)
        let ts = UInt32(nowMillis / 1000)
        let bodyMd5 = [UInt8](repeating: 0, count: 16)
        let fields = Self.merged(values, device)
        let ua = Self.metadataUA.replacingOccurrences(of: "73532", with: "74532")
        for n in 0..<128 {
            let ticket = String(nowMillis + Int64(n))
            let query = AppCrypto.encodeQuery(fields + [("ts", String(ts)), ("_rticket", ticket)])
            let url = "\(host)\(path)?\(query)"
            guard Self.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: bodyMd5, ts: ts) == 0 else { continue }
            let headers: [(String, String)] = [
                ("User-Agent", ua),
                ("Accept", "application/json"),
                ("Accept-Encoding", "identity"),
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
                ("x-medusa", try medusa(url: url, body: nil, ts: ts, deviceId: devId, versionName: "7.4.5.32", nowMillis: nowMillis)),
                ("x-tt-dt", dToken),
            ]
            return Signed(url: url, query: query, headers: headers, body: nil)
        }
        throw HongguoError(.format, "无法生成书城推荐流请求签名")
    }
}

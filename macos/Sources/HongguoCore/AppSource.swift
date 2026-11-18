// 6.7 unified release.
// SPDX-License-Identifier: GPL-3.0-only
// Swift port of the playback path of src/native/app-source.js.
// Signing and Spade algorithms adapted from woshishiq1/drpys
// commit 22261adfa31435e3b3ef5a730b8a2a75bcaf1715, spider/js/红果果[短].js,
// via N3urda/hongguoTV eea73e6a45569a2cbbb9440f7cd5290c459b0b70.
// Changes: registered in-memory playback identity; pure JS SM3;
// bounded HTTPS transport; exact episode matching; supported codec selection.
// Swift port: playback only (search/catalogue/account signers are not ported); ByteVC2 rows are
// skipped because AVFoundation cannot decode them; "auto" picks the best tier, others are variants.
// Crypto tables and SDK protocol constants below are not user credentials.
import Foundation

// MARK: Errors

struct AppSourceError: LocalizedError, Sendable {
    enum Code: String, Sendable {
        case input, timeout, network, cancelled, emptyResponse, invalidResponse, businessRejected, securityBlocked,
             missingModel, noCompatibleSource, deviceRegistrationFailed, http
    }
    var code: Code
    var message: String
    var status: Int?
    var registrationFailure: String?
    var incompleteEncryptionMetadata = false
    var minimumPixels = 0

    init(_ code: Code, _ message: String, status: Int? = nil, registrationFailure: String? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.registrationFailure = registrationFailure
    }

    var errorDescription: String? { message }

    /// Explicit upstream refusals stop work that was queued before they arrived.
    var isHardRejection: Bool {
        status == 403 || status == 429 || code == .businessRejected
            || (code == .deviceRegistrationFailed && ["BUSINESS_REJECTED", "HTTP_403", "HTTP_429"].contains(registrationFailure ?? ""))
    }

    var hongguoError: HongguoError {
        switch code {
        case .cancelled: return HongguoError(.cancelled, message)
        case .timeout: return HongguoError(.timeout, message)
        case .network: return HongguoError(.network, message)
        case .securityBlocked: return HongguoError(.security, message)
        case .input: return HongguoError(.input, message)
        case .invalidResponse, .missingModel: return HongguoError(.format, message)
        default: return HongguoError(.unavailable, message)
        }
    }
}

// MARK: Transport

/// Bounded HTTPS JSON transport for App endpoints: host allow-list, URLGuard (through HTTPClient),
/// no redirects for signed or POST requests, 2 MiB cap, and a hard overall deadline.
struct AppTransport: Sendable {
    let http: HTTPClient
    static let apiDomains = ["fqnovel.com", "snssdk.com"]

    func requestJSON(_ start: String, method: String = "GET", headers: [(String, String)], body: [UInt8]? = nil,
                     deadline: Date) async throws -> JSONValue {
        var url = try AppSource.checkedURL(start, domains: Self.apiDomains)
        for _ in 0..<4 {
            try Task.checkCancellationAsApp()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AppSourceError(.timeout, "App 片源请求超时") }
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let body { request.httpBody = Data(body) }
            var options = HTTPClient.Options()
            options.timeout = remaining
            options.maxBytes = 2 * 1024 * 1024
            options.maxRedirects = 0
            options.acceptStatus = 100...599
            for (k, v) in headers { options.headers[k] = v }
            let response: HTTPResponse
            let finalRequest = request, finalOptions = options, client = http
            do {
                response = try await withDeadline(deadline) { try await client.send(finalRequest, options: finalOptions) }
            } catch let error as AppSourceError {
                throw error
            } catch let error as HongguoError {
                switch error.kind {
                case .cancelled: throw AppSourceError(.cancelled, "已取消 App 片源请求")
                case .timeout: throw AppSourceError(.timeout, "App 片源请求超时")
                case .security: throw AppSourceError(.securityBlocked, error.message)
                default: throw AppSourceError(.network, "App 片源网络请求失败，请稍后重试")
                }
            } catch {
                throw AppSourceError(.network, "App 片源网络请求失败，请稍后重试")
            }
            if [301, 302, 303, 307, 308].contains(response.status) {
                // Signatures and session headers bind the final URL and must not follow a redirect.
                let bound = headers.contains { ["x-argus", "x-ladon", "x-gorgon", "x-medusa", "cookie", "authorization"].contains($0.0.lowercased()) }
                guard method != "POST", !bound, let location = response.header("Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw AppSourceError(.securityBlocked, "App 接口发生不支持的跳转")
                }
                url = try AppSource.checkedURL(next.absoluteString, domains: Self.apiDomains)
                continue
            }
            guard response.status == 200 else {
                throw AppSourceError(.http, "App 片源请求失败（HTTP \(response.status)）", status: response.status)
            }
            guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                var error = AppSourceError(.emptyResponse, "App 接口返回空响应（HTTP 200），原因尚未确认")
                error.status = 200
                throw error
            }
            guard let parsed = try? JSONValue.parse(response.data), parsed.object != nil else {
                throw AppSourceError(.invalidResponse, "App 接口未返回有效数据")
            }
            return parsed
        }
        throw AppSourceError(.securityBlocked, "App 片源跳转次数过多")
    }

    /// `URLRequest.timeoutInterval` is an idle timeout; this enforces the total budget.
    func withDeadline<T: Sendable>(_ deadline: Date, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let wait = max(0, deadline.timeIntervalSinceNow)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                throw AppSourceError(.timeout, "App 片源请求超时")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

extension Task where Success == Never, Failure == Never {
    static func checkCancellationAsApp() throws {
        if Task.isCancelled { throw AppSourceError(.cancelled, "已取消 App 片源请求") }
    }
}

// MARK: App source

/// Official App playback source: anonymous in-memory device registration, v5-signed
/// `multi_video_model/player/v1` (other official host on an empty reply), then one legacy
/// 551-signed attempt; all requests share one paced queue (one at a time, 1 s apart).
actor AppSource {
    static let shared = AppSource()

    static let videoAPI = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/"
    static let playerAPI = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/player/v1"
    static let videoUA = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
    static let playbackUA = videoUA.replacingOccurrences(of: "71332", with: "74332")
    static let playerUA = "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"
    static let mediaDomains = ["qznovelvod.com", "fqnovelvod.com", "douyinvod.com"]
    static let playbackDevice: [(String, String)] = [
        ("ac", "wifi"), ("channel", "update_64"), ("aid", "8662"), ("app_name", "novelread"),
        ("version_code", "74332"), ("version_name", "7.4.3.32"), ("device_platform", "android"), ("os", "android"),
        ("ssmix", "a"), ("device_type", "25053RT47C"), ("device_brand", "Redmi"), ("language", "zh"), ("os_api", "36"),
        ("os_version", "16"), ("manifest_version_code", "74332"), ("resolution", "1280*2772"), ("dpi", "520"),
        ("update_version_code", "74332"), ("host_abi", "arm64-v8a"), ("dragon_device_type", "phone"), ("pv_player", "74332"),
        ("compliance_status", "0"), ("need_personal_recommend", "1"), ("player_so_load", "1"), ("is_android_pad_screen", "0"),
    ]

    private let transport: AppTransport
    private let device: PlaybackDevice
    private var tail: Task<Void, Never> = Task {}
    private var readyAt = Date.distantPast
    private var rejectionGeneration = 0

    init(http: HTTPClient = .shared, device: PlaybackDevice = .shared) {
        transport = AppTransport(http: http)
        self.device = device
    }

    func playInfo(vid: String) async throws -> PlayInfo {
        guard vid.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else {
            throw AppSourceError(.input, "分集编号无效")
        }
        let generation = rejectionGeneration
        let previous = tail
        let work = Task { () throws -> PlayInfo in
            await previous.value
            try Task.checkCancellationAsApp()
            if self.rejectionGeneration != generation { throw AppSourceError(.businessRejected, "App 接口已拒绝之前的请求，已停止排队中的取址") }
            let wait = self.readyAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            try Task.checkCancellationAsApp()
            defer { self.readyAt = max(self.readyAt, Date().addingTimeInterval(1)) }
            do {
                return try await self.fetchFresh(vid: vid)
            } catch let error as AppSourceError {
                if error.isHardRejection { self.rejectionGeneration += 1 }
                throw error
            }
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func playbackRequest(payload: [UInt8], identity: PlaybackIdentity, modern: Bool, alternate: Bool = false)
        throws -> (url: String, headers: [(String, String)], body: [UInt8]) {
        let body = try AppCrypto.gzip(payload)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if modern {
            let base = alternate ? Self.playerAPI.replacingOccurrences(of: "sinfonlineb.", with: "sinfonlinea.") : Self.playerAPI
            let signed = try PlaybackSignerV5.shared.sign(base: base, values: [
                ("aid", "8662"), ("app_name", "novelread"), ("version_code", "74332"), ("version_name", "7.4.3.32"),
                ("channel", "vivo_8662_64"), ("device_platform", "android"), ("device_type", "PGT-AN10"), ("os_version", "12"),
                ("update_version_code", "74332"), ("iid", identity.iid), ("cdid", identity.cdid), ("device_id", identity.deviceId),
            ], body: body, nowMillis: now)
            return (signed.url, signed.headers + [
                ("User-Agent", Self.playerUA), ("Accept", "application/json"),
                ("Content-Type", "application/json; charset=utf-8"), ("Content-Encoding", "gzip"),
            ], body)
        }
        let khronos = UInt64(now / 1000)
        var values = Self.playbackDevice
        values += [("device_id", identity.deviceId), ("iid", identity.iid), ("cdid", identity.cdid),
                   ("ts", String(khronos)), ("_rticket", String(now))]
        let query = AppCrypto.encodeQuery(values)
        let signature = Dictionary(try PlayerSignature551.sign(query: query, body: body, ts: khronos), uniquingKeysWith: { a, _ in a })
        let headers: [(String, String)] = [
            ("User-Agent", Self.playbackUA), ("Accept", "application/json; charset=utf-8,application/x-protobuf"),
            ("x-ss-req-ticket", signature["x-ss-req-ticket"] ?? ""), ("sdk-version", "2"), ("x-xs-from-web", "0"),
            ("passport-sdk-version", "5051452"), ("x-ss-dp", "8662"), ("x-khronos", signature["x-khronos"] ?? ""),
            ("x-ladon", signature["x-ladon"] ?? ""), ("x-argus", signature["x-argus"] ?? ""), ("x-tt-dt", ""),
            ("x-tt-store-region", "cn"), ("x-tt-store-region-src", "did"),
            ("Content-Type", "application/json; charset=UTF-8"), ("Content-Encoding", "gzip"),
            ("x-ss-stub", signature["x-ss-stub"] ?? ""), ("Connection", "close"),
        ]
        return ("\(Self.videoAPI)?\(query)", headers, body)
    }

    func fetchFresh(vid: String) async throws -> PlayInfo {
        let payloadObject: [String: Any] = [
            "biz_param": ["detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
                          "disable_video_relate_book": false, "need_all_video_definition": true, "need_mp4_align": false,
                          "use_os_player": false, "use_server_dns": false, "video_platform": 1024],
            "mixed_video_id_map": ["1004": [vid]],
            "dr_scene": "player",
        ]
        let payload = Array(try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]))
        var identity = try await device.register(transport: transport)
        try Task.checkCancellationAsApp()
        // Registration has its own 8 s budget; the model request gets 12 s.
        let deadline = Date().addingTimeInterval(12)
        var response: JSONValue = .null
        for attempt in 0..<2 {
            try Task.checkCancellationAsApp()
            do {
                let signed = try playbackRequest(payload: payload, identity: identity, modern: attempt == 0)
                do {
                    response = try await transport.requestJSON(signed.url, method: "POST", headers: signed.headers,
                                                               body: signed.body, deadline: deadline)
                } catch let error as AppSourceError {
                    if attempt > 0 || error.code != .emptyResponse || deadline.timeIntervalSinceNow < 1 { throw error }
                    // An empty primary response can recover on the other official host with the same identity.
                    let alternate = try playbackRequest(payload: payload, identity: identity, modern: true, alternate: true)
                    response = try await transport.requestJSON(alternate.url, method: "POST", headers: alternate.headers,
                                                               body: alternate.body, deadline: deadline)
                }
                break
            } catch let error as AppSourceError {
                if error.code == .cancelled { throw error }
                if attempt > 0 || error.code != .emptyResponse || deadline.timeIntervalSinceNow < 1 { throw error }
                // Keep the legacy attempt even when a fresh registration fails.
                if deadline.timeIntervalSinceNow >= 8 {
                    do {
                        identity = try await device.register(transport: transport)
                    } catch let registration as AppSourceError {
                        if registration.code == .cancelled || registration.isHardRejection { throw registration }
                    }
                }
                if deadline.timeIntervalSinceNow < 1.5 { throw error }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellationAsApp()
            }
        }
        if (response["Code"].number ?? response["code"].number ?? 0) != 0 {
            throw AppSourceError(.businessRejected, "App 接口暂未提供本集播放信息")
        }
        let data = response["data"]
        let entries = !data["1004"].isNull ? data["1004"] : (!data["video_model_data"].isNull ? data["video_model_data"] : data)
        let entry = entries[vid]
        let model: JSONValue
        if let text = entry["video_model"].string { model = (try? JSONValue.parse(text)) ?? .null } else { model = entry["video_model"] }
        guard model.object != nil else {
            throw AppSourceError(entry["video_model"].isNull ? .missingModel : .invalidResponse, "App 接口未返回所选分集，已停止取址")
        }
        let inline = !(model["video_list"].object?.isEmpty ?? true)
        func readFallback() async throws -> JSONValue {
            guard let fallback = Self.parseFallback(model["fallback_api"]), !fallback.isEmpty else {
                throw AppSourceError(.missingModel, "App 接口未返回本集片源地址")
            }
            let outer = try await transport.requestJSON(fallback, headers: [("User-Agent", Self.videoUA)], deadline: deadline)
            for value in [outer, outer["video_info"]] where (value["Code"].number ?? value["code"].number ?? 0) != 0 {
                throw AppSourceError(.businessRejected, "App 接口暂未提供本集播放信息")
            }
            return outer["video_info"]["data"]
        }
        if !inline {
            return try Self.parsePlayModel(try await readFallback(), vid: vid, inline: false)
        }
        do {
            return try Self.parsePlayModel(model, vid: vid, inline: true)
        } catch let error as AppSourceError {
            // Only absent encryption metadata enables this recovery path; the fallback must
            // independently pass identity, duration, encryption and URL validation.
            let duration = model["video_duration"].number ?? .nan
            guard error.incompleteEncryptionMetadata, let videoId = model["video_id"].string,
                  !videoId.trimmingCharacters(in: .whitespaces).isEmpty, duration.isFinite, duration > 0,
                  error.minimumPixels > 0, !model["fallback_api"].isNull else { throw error }
            let info = try await readFallback()
            let fallbackDuration = info["video_duration"].number ?? .nan
            guard info["video_id"].string == videoId, fallbackDuration.isFinite, fallbackDuration > 0,
                  abs(fallbackDuration - duration) <= 0.5 else {
                throw AppSourceError(.invalidResponse, "备用片源编号或完整时长无法确认，已停止取址")
            }
            return try Self.parsePlayModel(info, vid: vid, inline: false, requireEncryptionMetadata: true,
                                           minimumPixels: error.minimumPixels)
        }
    }

    // MARK: Parsing (pure, unit-tested)

    static func parseFallback(_ value: JSONValue) -> String? {
        if let text = value.string {
            if let parsed = try? JSONValue.parse(text), let api = parsed["fallback_api"].string { return api }
            return text
        }
        if let first = value.array?.first { return first.string?.trimmingCharacters(in: .whitespaces) }
        return value["fallback_api"].string?.trimmingCharacters(in: .whitespaces)
    }

    static func cleanURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func checkedURL(_ value: String, domains: [String]) throws -> URL {
        guard let url = URL(string: value), let host = url.host?.lowercased() else {
            throw AppSourceError(.invalidResponse, "App 片源地址格式无效")
        }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              domains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            throw AppSourceError(.securityBlocked, "App 片源返回了不受支持的服务地址")
        }
        return url
    }

    /// `spade_a` -> 16-byte content key. Verbatim port of `deriveContentKey` (differs from
    /// `CencDecryptor.deriveKey`, which serves the legacy preload API).
    static func deriveContentKey(_ value: String) throws -> [UInt8] {
        let raw = AppCrypto.base64Decode(value.trimmingCharacters(in: .whitespaces))
        guard raw.count >= 3 else { throw AppSourceError(.invalidResponse, "spade_a too short") }
        var v8 = raw.count - Int(raw[0] ^ raw[1] ^ raw[2]) + 47
        v8 = min(v8, raw.count - 1)
        guard v8 >= 33 else { throw AppSourceError(.invalidResponse, "spade_a key length invalid") }
        var work = Array(raw[1..<(1 + v8)])
        var a = 85, b = 246
        for i in 0..<v8 {
            let old = Int(work[i])
            let previous = i & 1 == 1 ? a : b
            if i & 1 == 1 { a = old } else { b = old }
            work[i] = UInt8(truncatingIfNeeded: -21 - i.nonzeroBitCount + (previous ^ old))
        }
        guard let hex = String(bytes: work[1..<33], encoding: .ascii),
              hex.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil,
              let key = AppCrypto.fromHex(hex) else {
            throw AppSourceError(.invalidResponse, "App 视频密钥格式无效")
        }
        return key
    }

    static let spadeConstants = AppCrypto.fromHex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")!

    static func decryptSpadeURL(_ value: String, seed: [UInt8]) throws -> String {
        let encoded = value.trimmingCharacters(in: .whitespaces)
        if encoded.isEmpty { return "" }
        let raw = AppCrypto.base64Decode(encoded)
        guard raw.count >= 5 else { throw AppSourceError(.invalidResponse, "spade URL ciphertext too short") }
        guard raw[0] == 0xa8, raw[2] == 0x01, raw[3] == 0x00 else { throw AppSourceError(.invalidResponse, "spade URL header format error") }
        let cipherLength = (raw.count - 4) / 16 * 16
        guard cipherLength > 0 else { throw AppSourceError(.invalidResponse, "spade URL ciphertext has no complete block") }
        let h2 = AppCrypto.sha512(AppCrypto.sha512(seed) + spadeConstants)
        var plain = try AppCrypto.aes128CBC(encrypt: false, key: Array(h2[0..<16]), iv: Array(h2[16..<32]),
                                            Array(raw[4..<(4 + cipherLength)]), pkcs7: false)
        if let padding = plain.last, (1...16).contains(Int(padding)), Int(padding) <= plain.count {
            plain.removeLast(Int(padding))
        }
        while plain.last == 0 { plain.removeLast() }
        return String(decoding: plain, as: UTF8.self)
    }

    struct Row { var item: JSONValue; var codec: String; var codecRank: Int; var pixels: Int; var width: Int; var height: Int }

    /// Stream choice for "auto": H.264 > HEVC, then the highest tier. Every compatible encoding at the
    /// best tier is tried before failing; lower tiers are never used silently. ByteVC2 is used last,
    /// and only when the conversion helper is available.
    static func parsePlayModel(_ info: JSONValue, vid: String, inline: Bool, requireEncryptionMetadata: Bool? = nil,
                               minimumPixels: Int = 0) throws -> PlayInfo {
        let requireMetadata = requireEncryptionMetadata ?? inline
        guard !info.isNull else { throw AppSourceError(.missingModel, "App 接口未返回本集片源模型") }
        let items = info["video_list"].object.map { dict in
            dict.keys.sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }.map { dict[$0]! }
        } ?? info["video_list"].array ?? []
        let rows: [Row] = items.compactMap { item in
            guard item.object != nil, item["main_url"].string != nil || item["backup_url"].string != nil || item["backup_url_list"].array != nil else { return nil }
            let codec = (item["codec_type"].string ?? item["video_meta"]["codec_type"].string ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let rank = ["h264", "avc", "avc1"].contains(codec) ? 0 : ["hevc", "h265", "hvc1", "hev1", "bytevc1"].contains(codec) ? 1
                // ByteVC2 only when nothing else is offered and 兼容转换 can turn it into H.264.
                : codec == "bytevc2" && ByteVC2Converter.isEnabled ? 2 : 3
            let meta = item["video_meta"]
            let pairs = [(item["vwidth"], item["vheight"]), (item["width"], item["height"]), (meta["vwidth"], meta["vheight"]), (meta["width"], meta["height"])]
            let size = pairs.lazy.map { (Int($0.0.number ?? 0), Int($0.1.number ?? 0)) }.first { $0.0 > 0 && $0.1 > 0 } ?? (0, 0)
            let quality = item["quality_desc"].string ?? item["definition"].string ?? meta["definition"].string
                ?? item["height"].idString ?? item["vheight"].idString ?? ""
            let digits = quality.range(of: "[0-9]+", options: .regularExpression).map { Int(quality[$0]) ?? 0 } ?? 0
            let pixels = size.0 > 0 ? min(size.0, size.1) : digits
            return Row(item: item, codec: codec, codecRank: rank, pixels: pixels, width: size.0, height: size.1)
        }.filter { $0.codecRank < 3 && (minimumPixels == 0 || min($0.width, $0.height) >= minimumPixels) }
            .sorted { $0.codecRank != $1.codecRank ? $0.codecRank < $1.codecRank : $0.pixels > $1.pixels }
        guard let best = rows.first else {
            let onlyByteVC2 = items.contains { ($0["codec_type"].string ?? $0["video_meta"]["codec_type"].string)?.lowercased() == "bytevc2" }
            throw AppSourceError(.noCompatibleSource, onlyByteVC2
                ? (ByteVC2Converter.executableURL == nil
                    ? "本集仅提供 ByteVC2 编码，未找到兼容转换组件，请重新安装完整版本"
                    : "本集仅提供 ByteVC2 编码，已在设置中关闭兼容转换；打开设置 > 下载 > ByteVC2 兼容转换后可播放")
                : "本集暂未提供兼容的 H.264/HEVC 片源")
        }
        let seed = info["key_seed"].string.map(AppCrypto.base64Decode)
        var lastError: Error?
        var incomplete = false
        /// First working stream among `tierRows` (already in codec preference order).
        func resolve(_ tierRows: [Row]) -> PlayInfo? {
            for row in tierRows {
                do {
                    let spade = row.item["spade_a"].string ?? row.item["encrypt_info"]["spade_a"].string
                    let encrypt = !row.item["encrypt_info"]["encrypt"].isNull ? row.item["encrypt_info"]["encrypt"] : row.item["encrypt"]
                    let explicitlyPlain: Bool = {
                        switch encrypt {
                        case .bool(false), .int(0): return true
                        case .string(let s): return s == "0" || s == "false"
                        case .double(let d): return d == 0
                        default: return false
                        }
                    }()
                    if requireMetadata && (spade ?? "").isEmpty && !explicitlyPlain {
                        if encrypt.isNull { incomplete = true }
                        throw AppSourceError(.invalidResponse, "本集片源缺少有效解密信息")
                    }
                    let key = (spade ?? "").isEmpty ? nil : try deriveContentKey(spade!)
                    var candidates = [row.item["main_url"].string, row.item["backup_url"].string]
                    candidates += (row.item["backup_url_list"].array ?? []).map(\.string)
                    for candidate in candidates.compactMap({ $0 }).filter({ !$0.isEmpty }) {
                        do {
                            let media = try seed.map { try decryptSpadeURL(candidate, seed: $0) } ?? cleanURL(candidate)
                            let url = try checkedURL(media, domains: mediaDomains)
                            guard URLGuard.isPublicURL(url) else { throw URLGuard.blocked() }
                            return PlayInfo(url: url, spadeA: nil, codec: row.codec == "bytevc1" ? "hevc" : row.codec, source: .app,
                                            vid: vid, userAgent: inline ? playbackUA : videoUA, referer: nil, contentKey: key,
                                            quality: row.pixels > 0 ? QualityOption(shortSide: row.pixels) : nil)
                        } catch { lastError = error }
                    }
                } catch { lastError = error }
            }
            return nil
        }
        if var play = resolve(best.pixels > 0 ? rows.filter { $0.pixels == best.pixels } : [best]) {
            // Other tiers are offered for manual switching only; "auto" never drops a tier silently.
            let tiers = Set(rows.map(\.pixels).filter { $0 > 0 && $0 != best.pixels }).sorted(by: >)
            if best.pixels > 0 {
                play.variants = tiers.compactMap { tier in resolve(rows.filter { $0.pixels == tier }) }
            }
            return play
        }
        if let blocked = lastError as? AppSourceError, blocked.code == .securityBlocked { throw blocked }
        if let blocked = lastError as? HongguoError, blocked.kind == .security { throw blocked }
        var error = AppSourceError(.invalidResponse, "本集片源地址或密钥无法解析")
        if incomplete {
            error.incompleteEncryptionMetadata = true
            error.minimumPixels = min(best.width, best.height)
        }
        throw error
    }
}

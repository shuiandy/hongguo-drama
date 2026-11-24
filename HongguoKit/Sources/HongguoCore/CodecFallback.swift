// SPDX-License-Identifier: GPL-3.0-only
// For episodes whose play model offers only ByteVC2, which no Apple decoder plays. The official
// Android player (TTVideoEngine in 7.4.5.32, static reading supplied by the owner) retries such
// a failure on the `fallback_api` address the server itself returned, with `force_codec=h264`
// appended; another branch sets `codec_type=0` on that address. This asks the same way.
// Read-only: the same source lookup the core already makes, plus that one address.
import Foundation

public enum CodecFallback {
    /// One stream of a play model: its encoding and short side. No address, no key.
    public struct Stream: Equatable, Sendable, CustomStringConvertible {
        public var codec: String
        public var shortSide: Int
        public var description: String { "\(codec.isEmpty ? "?" : codec)/\(shortSide)" }
    }

    /// What a lookup offered, for a log line.
    public struct Offer: Sendable {
        public var streams: [Stream]
        public var duration: Double
    }

    public enum Variant: String, CaseIterable, Sendable {
        /// The address exactly as the server returned it.
        case plain
        /// `force_codec=h264` appended.
        case forceH264
        /// `codec_type=0` set.
        case codecTypeZero
    }

    static func streams(of info: JSONValue) -> [Stream] {
        let items = info["video_list"].object.map { Array($0.values) } ?? info["video_list"].array ?? []
        return items.map { item in
            let meta = item["video_meta"]
            let codec = (item["codec_type"].string ?? meta["codec_type"].string ?? "").lowercased()
            let width = Int(item["vwidth"].number ?? meta["vwidth"].number ?? item["width"].number ?? 0)
            let height = Int(item["vheight"].number ?? meta["vheight"].number ?? item["height"].number ?? 0)
            return Stream(codec: codec, shortSide: min(width, height))
        }.sorted { ($0.codec, $0.shortSide) < ($1.codec, $1.shortSide) }
    }

    /// The fallback address with the variant's change applied.
    static func address(_ fallback: String, variant: Variant) -> String {
        guard variant != .plain, var parts = URLComponents(string: fallback) else { return fallback }
        var query = parts.queryItems ?? []
        switch variant {
        case .plain: break
        case .forceH264:
            query.removeAll { $0.name == "force_codec" }
            query.append(URLQueryItem(name: "force_codec", value: "h264"))
        case .codecTypeZero:
            let wasDash = query.contains { $0.name == "format_type" && $0.value == "dash" }
            query.removeAll { $0.name == "codec_type" || (wasDash && $0.name == "format_type") }
            query.append(URLQueryItem(name: "codec_type", value: "0"))
            if wasDash { query.append(URLQueryItem(name: "format_type", value: "mp4")) }
        }
        parts.queryItems = query
        return parts.string ?? fallback
    }

    static func extractEntries(from data: JSONValue) -> [JSONValue] {
        var result: [JSONValue] = []
        for key in ["1004", "1001", "video_model_data"] {
            if let obj = data[key].object, !obj.isEmpty { result.append(data[key]) }
        }
        if let obj = data.object, !obj.isEmpty { result.append(data) }
        return result
    }

    static func lookupEntry(vid: String, in data: JSONValue) -> JSONValue {
        for bucket in extractEntries(from: data) {
            let entry = bucket[vid]
            if !entry.isNull { return entry }
        }
        return .null
    }

    /// The play model as the core asks for it, and the fallback address inside it.
    private static func model(vid: String, transport: AppTransport) async throws -> JSONValue {
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let ctx = await PersistentAppDevice.shared.playSessionContext()
        let isUGC = UGCVideos.contains(vid)
        func ask(ugc: Bool) async throws -> JSONValue {
            let signed = try VideoModelRequest.request(
                vid: vid,
                identity: identity,
                openudid: ctx.openudid,
                guest: ctx.cookies,
                dToken: ctx.dToken,
                installMillis: ctx.firstInstallTimeMs,
                isUGC: ugc
            )
            return try await transport.requestJSON(
                signed.url, method: "POST", headers: signed.headers, body: signed.body,
                deadline: Date().addingTimeInterval(12)
            )
        }
        var response = try await ask(ugc: isUGC)
        if !isUGC, Int(response["code"].number ?? -1) == 101_000 {
            response = try await ask(ugc: true)
            if response["Code"].isZeroOrMissingStatusCode && response["code"].isZeroOrMissingStatusCode,
               !response["data"]["video_model"].isNull {
                UGCVideos.insert([vid])
            }
        }
        guard response["Code"].isZeroOrMissingStatusCode && response["code"].isZeroOrMissingStatusCode else {
            throw HongguoError(.upstream, "App 接口暂未提供本集播放信息")
        }
        let entry = response["data"]
        if let text = entry["video_model"].string { return (try? JSONValue.parse(text)) ?? .null }
        return entry["video_model"]
    }

    private static func fallbackInfo(_ model: JSONValue, variant: Variant, transport: AppTransport) async throws -> JSONValue {
        guard let fallback = AppSource.parseFallback(model["fallback_api"]), !fallback.isEmpty else {
            throw HongguoError(.upstream, "App 接口未返回备用片源地址")
        }
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()
        return try await fetchFallback(fallback, variant: variant, transport: transport, extraHeaders: dToken,
                                       deadline: Date().addingTimeInterval(12))
    }

    private static func fetchFallback(_ fallback: String, variant: Variant, transport: AppTransport,
                                      extraHeaders: [(String, String)], deadline: Date) async throws -> JSONValue {
        let outer = try await transport.requestJSON(
            address(fallback, variant: variant),
            headers: [("User-Agent", AppSource.iosPlayerUA)] + extraHeaders,
            deadline: deadline
        )
        for value in [outer, outer["video_info"]]
        where !value["Code"].isZeroOrMissingStatusCode || !value["code"].isZeroOrMissingStatusCode {
            throw HongguoError(.upstream, "备用片源接口没有给出播放信息")
        }
        return outer["video_info"]["data"]
    }

    /// Attempts to obtain a hardware-decodable (H.264/HEVC) stream from an already-fetched
    /// `fallback_api` URL when the default response only offered ByteVC2. Returns nil if the
    /// server still only returns ByteVC2 or fails.
    static func tryHardwareCodecFallback(
        fallbackURL: String,
        expectedVideoId: String?,
        expectedDuration: Double?,
        vid: String,
        transport: AppTransport,
        extraHeaders: [(String, String)],
        deadline: Date,
        requireEncryptionMetadata: Bool = false,
        minimumPixels: Int = 0
    ) async -> PlayInfo? {
        for variant in [Variant.forceH264, .codecTypeZero] {
            guard deadline.timeIntervalSinceNow >= 1 else { break }
            do {
                let info = try await fetchFallback(fallbackURL, variant: variant, transport: transport,
                                                   extraHeaders: extraHeaders, deadline: deadline)
                if let expectedId = expectedVideoId, !expectedId.isEmpty,
                   let other = info["video_id"].string, other != expectedId {
                    continue
                }
                if let expectedDur = expectedDuration, expectedDur > 0,
                   let otherDur = info["video_duration"].number, otherDur > 0,
                   abs(otherDur - expectedDur) > 0.5 {
                    continue
                }
                let parsed = try AppSource.parsePlayModel(
                    info,
                    vid: vid,
                    inline: false,
                    requireEncryptionMetadata: requireEncryptionMetadata,
                    minimumPixels: minimumPixels
                )
                if !parsed.isByteVC2 {
                    return parsed
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// A stream Apple can decode for an episode the core found only in ByteVC2: the fallback
    /// address with `force_codec=h264`, then with `codec_type=0`. The reply must be the same
    /// video (id and length) as the model it came from.
    public static func playInfo(vid: String) async throws -> PlayInfo {
        do {
            let transport = AppTransport(http: .shared)
            let model = try await model(vid: vid, transport: transport)
            var last: Error = HongguoError(.upstream, "备用片源仍然只有 ByteVC2")
            for variant in [Variant.forceH264, .codecTypeZero] {
                do {
                    let info = try await fallbackInfo(model, variant: variant, transport: transport)
                    if let id = model["video_id"].string, !id.isEmpty, let other = info["video_id"].string, other != id {
                        throw HongguoError(.upstream, "备用片源编号对不上")
                    }
                    let length = model["video_duration"].number ?? 0, otherLength = info["video_duration"].number ?? 0
                    if length > 0, otherLength > 0, abs(length - otherLength) > 0.5 {
                        throw HongguoError(.upstream, "备用片源时长对不上")
                    }
                    let parsed = try AppSource.parsePlayModel(info, vid: vid, inline: false)
                    guard !parsed.isByteVC2 else {
                        last = HongguoError(.upstream, "备用片源仍然只有 ByteVC2")
                        continue
                    }
                    return parsed
                } catch {
                    last = error
                }
            }
            throw last
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
    }

    /// The source of an episode at one size, as the core resolves it. With ByteVC2 allowed
    /// (a Mac probe run only) this is how a sample for decoding measurements is fetched.
    public static func sampleSource(vid: String, shortSide: Int?) async throws -> PlayInfo {
        try await AuthenticatedPlaybackSource.shared.playInfo(vid: vid).selecting(shortSide: shortSide)
    }

    /// What the inline model and each form of the fallback address offer, for comparing.
    public static func compare(vid: String) async -> [(String, Result<Offer, Error>)] {
        let transport = AppTransport(http: .shared)
        var rows: [(String, Result<Offer, Error>)] = []
        do {
            let model = try await model(vid: vid, transport: transport)
            rows.append(("inline", .success(Offer(streams: streams(of: model), duration: model["video_duration"].number ?? 0))))
            for variant in Variant.allCases {
                do {
                    let info = try await fallbackInfo(model, variant: variant, transport: transport)
                    rows.append((variant.rawValue, .success(Offer(streams: streams(of: info), duration: info["video_duration"].number ?? 0))))
                } catch {
                    rows.append((variant.rawValue, .failure(error)))
                }
            }
        } catch {
            rows.append(("inline", .failure(error)))
        }
        return rows
    }
}

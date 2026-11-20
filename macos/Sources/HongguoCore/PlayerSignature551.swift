// SPDX-License-Identifier: GPL-3.0-only
// Swift port of src/native/playback-signature.js: playback-only 551 Argus/Ladon signing.
// Adapted from N3urda/hongguoTV 7444bb01aec7b0420740103e551c45f1f66101c9,
// kotlin-tv/core/src/main/kotlin/com/hongguotv/core/Argus.kt (blob 9f1b06f16c778f07d1bd9e1f8e9a596590e57213).
// Upstream attributes GPL-3.0-only ch6vip/fqapp rust/src/sign/{argus,simon,ladon,protobuf}.rs.
// Public protocol constants below are not account credentials. Legacy Gorgon/registration code is excluded.
import Foundation

/// Signs the legacy `multi_video_model/v1/` request used as the one empty-response retry.
enum PlayerSignature551 {
    static let licenseId: UInt64 = 1611921764
    static let signKey = AppCrypto.fromHex("fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304")!
    static let aesKey = AppCrypto.fromHex("d31e3718288a1027baab59f146a09a9c")!
    static let aesIV = AppCrypto.fromHex("ea180a0336ed352fcd24e4d50018ae54")!
    static let magic8 = AppCrypto.fromHex("f2f7fcfff2f7fcff")!
    static let tail9 = AppCrypto.fromHex("eafb2cfe8568519154")!

    @inline(__always) static func rol64(_ v: UInt64, _ bits: Int) -> UInt64 {
        let n = UInt64(bits & 63)
        return n == 0 ? v : (v << n) | (v >> (64 - n))
    }
    @inline(__always) static func ror64(_ v: UInt64, _ bits: Int) -> UInt64 { rol64(v, 64 - bits) }

    static func pad16(_ data: [UInt8]) -> [UInt8] {
        let n = 16 - data.count % 16
        return data + [UInt8](repeating: UInt8(n), count: n)
    }

    /// The JS ProtoBuf helper truncates varints to 32 bits and keeps empty strings.
    struct Proto32 {
        var bytes: [UInt8] = []
        mutating func varint(_ tag: Int, _ value: UInt64) {
            bytes += ProtoWriter.varint(UInt64(UInt32(truncatingIfNeeded: UInt64(tag) << 3)))
            bytes += ProtoWriter.varint(UInt64(UInt32(truncatingIfNeeded: value)))
        }
        mutating func raw(_ tag: Int, _ value: [UInt8]) {
            bytes += ProtoWriter.varint(UInt64(tag) << 3 | 2)
            bytes += ProtoWriter.varint(UInt64(value.count))
            bytes += value
        }
        mutating func utf8(_ tag: Int, _ value: String) { raw(tag, Array(value.utf8)) }
    }

    static func simonKeys(_ key: [UInt64]) -> [UInt64] {
        var expanded = key
        for i in 4..<72 {
            var tmp = ror64(expanded[i - 1], 3) ^ expanded[i - 3]
            tmp ^= ror64(tmp, 1)
            let bit = (UInt64(0x3dc94c3a046d678b) >> UInt64((i - 4) % 62)) & 1
            expanded.append(~expanded[i - 4] ^ tmp ^ bit ^ 3)
        }
        return expanded
    }

    static func simonEncrypt(_ left: UInt64, _ right: UInt64, keys: [UInt64]) -> (UInt64, UInt64) {
        var x = left, y = right
        for roundKey in keys {
            let previous = y
            y = x ^ (rol64(y, 1) & rol64(y, 8)) ^ rol64(y, 2) ^ roundKey
            x = previous
        }
        return (x, y)
    }

    static func argus(query: String, stubHex: String, ts: UInt64, aid: UInt64, deviceId: String, installId: String,
                      randField: Int32) throws -> String {
        let stubBytes = stubHex.isEmpty ? [UInt8](repeating: 0, count: 16) : (AppCrypto.fromHex(stubHex) ?? [])
        let bodyHash = Array(AppCrypto.sm3(stubBytes)[0..<6])
        let queryHash = Array(AppCrypto.sm3(query.isEmpty ? [UInt8](repeating: 0, count: 16) : Array(query.utf8))[0..<6])
        var inner15 = Proto32(); inner15.varint(1, 1); inner15.varint(2, 1); inner15.varint(3, 1); inner15.varint(7, 0xc792eccc)
        var inner23 = Proto32(); inner23.utf8(1, "NX551J"); inner23.varint(2, 8196); inner23.varint(4, 0x80e0d800)
        var bean = Proto32()
        bean.varint(1, 1077940818); bean.varint(2, 2); bean.varint(3, UInt64(UInt32(bitPattern: randField)))
        bean.utf8(4, String(aid == 0 ? 1967 : aid)); bean.utf8(5, deviceId)
        bean.utf8(6, String(licenseId)); bean.utf8(7, AppCrypto.queryParam(query, "version_name") ?? "")
        bean.utf8(8, "v04.04.05-ov-android"); bean.varint(9, 134744640); bean.raw(10, [UInt8](repeating: 0, count: 8))
        bean.varint(11, 0); bean.varint(12, ts << 1); bean.raw(13, bodyHash); bean.raw(14, queryHash)
        bean.raw(15, inner15.bytes); bean.utf8(16, installId); bean.utf8(20, "none"); bean.varint(21, 738)
        bean.raw(23, inner23.bytes); bean.varint(25, 2)
        let protobuf = pad16(bean.bytes)
        let keys = simonKeys((0..<4).map { AppCrypto.readLE64(signKey, $0 * 8) })
        var blocks: [UInt8] = []
        for at in stride(from: 0, to: protobuf.count, by: 16) {
            let (a, b) = simonEncrypt(AppCrypto.readLE64(protobuf, at), AppCrypto.readLE64(protobuf, at + 8), keys: keys)
            blocks += AppCrypto.le64(a) + AppCrypto.le64(b)
        }
        var framed = magic8 + blocks + tail9
        for i in 8..<framed.count { framed[i] ^= magic8[i % 8] }
        let padded = pad16(Array(framed.reversed()) + Array("ao".utf8))
        let encrypted = try AppCrypto.aes128CBC(encrypt: true, key: aesKey, iv: aesIV, padded, pkcs7: false)
        return AppCrypto.base64([0xf2, 0x81] + encrypted)
    }

    static func ladon(ts: UInt64, aid: UInt64, random: [UInt8]) -> String {
        let aidText = String(aid)
        let ascii = Array(AppCrypto.hex(AppCrypto.md5(random + Array(aidText.utf8))).utf8)
        let words = (0..<4).map { AppCrypto.readLE64(ascii, $0 * 8) }
        var table = [words[0]]
        var queue = Array(words[2...])
        var b0 = words[0], b8 = words[1]
        for i in 0..<34 {
            var x8 = (ror64(b8, 8) &+ b0) ^ UInt64(i)
            queue.append(x8)
            x8 ^= rol64(b0, 3)
            table.append(x8); b0 = x8; b8 = queue.removeFirst()
        }
        let input = pad16(Array("\(ts)-\(licenseId)-\(aidText)".utf8))
        var out: [UInt8] = []
        for at in stride(from: 0, to: input.count, by: 16) {
            var a = AppCrypto.readLE64(input, at), b = AppCrypto.readLE64(input, at + 8)
            for i in 0..<34 { b = table[i] ^ (a &+ ror64(b, 8)); a = b ^ rol64(a, 3) }
            out += AppCrypto.le64(a) + AppCrypto.le64(b)
        }
        return AppCrypto.base64(random + out)
    }

    /// Headers for the final query and raw body. `randField` / `ladonRandom` are injectable for tests.
    static func sign(query: String, body: [UInt8]?, ts: UInt64, randField: Int32? = nil,
                     ladonRandom: [UInt8]? = nil) throws -> [(String, String)] {
        var aid: UInt64 = 1967
        if let raw = AppCrypto.queryParam(query, "aid"), let value = Int64(raw) { aid = UInt64(bitPattern: value) }
        let stub = (body?.isEmpty == false) ? AppCrypto.hex(AppCrypto.md5(body!)) : ""
        let rand = randField ?? Int32(bitPattern: AppCrypto.random32())
        let ladonBytes = ladonRandom ?? AppCrypto.randomBytes(4)
        var headers: [(String, String)] = [
            ("x-ss-req-ticket", String(ts * 1000)), ("x-khronos", String(ts)),
            ("x-ladon", ladon(ts: ts, aid: aid, random: ladonBytes)),
            ("x-argus", try argus(query: query, stubHex: stub, ts: ts, aid: aid,
                                  deviceId: AppCrypto.queryParam(query, "device_id") ?? "", installId: "", randField: rand)),
        ]
        if !stub.isEmpty { headers.append(("x-ss-stub", stub)) }
        return headers
    }
}

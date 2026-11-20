// SPDX-License-Identifier: GPL-3.0-only
// Request signing (X-Gorgon / X-Ladon / X-Argus) for the timed danmaku API.
// Byte-for-byte port of src/native/danmaku-sign.js (itself adapted from dawei233/hongguo-drama,
// GPL-3.0, commit c884fab6c6e36ad38173e251738b9b35f958383f).
//
// Two hard rules carried over from the reference:
// 1. Do not "fix" code that looks wrong. The Gorgon key schedule assigns `box[i] = box[j]`
//    instead of swapping, and the server accepts exactly that.
// 2. Keep every 64-bit operation wrapping and every truncation where the reference has it.
// `DanmakuSigningTests` asserts golden vectors produced by scripts/gen-danmaku-vectors.cjs.
import Foundation

public enum DanmakuSigner {
    /// Nonce length. `[0..<2]` feeds Gorgon, `[2..<6]` Ladon, `[6..<11]` Argus.
    public static let nonceBytes = 11
    static let argusKey: [UInt8] = AppCrypto.fromHex("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c")!

    // MARK: Bit helpers (match the reference's Python semantics)

    @inline(__always) static func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
        let s = UInt64(((n % 64) + 64) % 64)
        return s == 0 ? x : (x << s) | (x >> (64 - s))
    }
    @inline(__always) static func rotr64(_ x: UInt64, _ n: Int) -> UInt64 { rotl64(x, -n) }
    @inline(__always) static func rotl8(_ x: UInt8, _ n: Int) -> UInt8 {
        let s = UInt8(n & 7)
        return s == 0 ? x : (x << s) | (x >> (8 - s))
    }
    @inline(__always) static func reverse8(_ x: UInt8) -> UInt8 {
        var v = x
        v = ((v & 0xF0) >> 4) | ((v & 0x0F) << 4)
        v = ((v & 0xCC) >> 2) | ((v & 0x33) << 2)
        v = ((v & 0xAA) >> 1) | ((v & 0x55) << 1)
        return v
    }

    /// PKCS#7 that always adds 1...16 bytes.
    static func pad(_ data: [UInt8]) -> [UInt8] {
        let padding = 16 - data.count % 16
        return data + [UInt8](repeating: UInt8(padding), count: padding)
    }

    /// Protobuf unsigned varint (Go `binary.AppendUvarint`).
    static func uvarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while true {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { out.append(byte | 0x80) } else { out.append(byte); return out }
        }
    }

    static func putLE64(_ value: UInt64, _ target: inout [UInt8], _ offset: Int) {
        for i in 0..<8 { target[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    }

    // MARK: Query

    static func baseParams(deviceId: String, installId: String) -> [(String, String)] {
        [
            ("aid", "8662"), ("app_name", "novelread"), ("version_code", "73532"), ("version_name", "7.3.5.32"),
            ("manifest_version_code", "73532"), ("update_version_code", "73532"), ("channel", "update_64"),
            ("device_platform", "android"), ("os", "android"), ("ssmix", "a"), ("device_type", "25053RT47C"),
            ("device_brand", "Redmi"), ("language", "zh"), ("os_api", "36"), ("os_version", "16"),
            ("resolution", "1280*2772"), ("dpi", "520"), ("ac", "wifi"), ("device_id", deviceId), ("iid", installId),
        ]
    }

    /// Python `quote_plus`: keeps only `A-Za-z0-9_.-~`, spaces become `+`.
    static func quotePlus(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2E, 0x2D, 0x7E: out.append(Character(UnicodeScalar(byte)))
            case 0x20: out.append("+")
            default: out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Keys sorted bytewise, like Go `url.Values.Encode`.
    public static func buildQuery(stampMs: Int64, deviceId: String, installId: String) -> String {
        var params = baseParams(deviceId: deviceId, installId: installId)
        params.append(("_rticket", String(stampMs)))
        params.sort { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        return params.map { "\(quotePlus($0.0))=\(quotePlus($0.1))" }.joined(separator: "&")
    }

    // MARK: X-Gorgon

    static func gorgon(rawQuery: String, stamp: Int64, nonce: [UInt8]) -> String {
        let head2 = UInt8(truncatingIfNeeded: ((Int(nonce[0]) % 7) + 1) << 5)
        let head3 = 0xE0 | (nonce[1] & 0x0F)

        var seed = [UInt8](repeating: 0, count: 20)
        let digest = AppCrypto.md5(Array(rawQuery.utf8))
        seed.replaceSubrange(0..<4, with: digest[0..<4])
        seed.replaceSubrange(12..<16, with: [0, 1, 7, 4])
        seed.replaceSubrange(16..<20, with: AppCrypto.be32Bytes(UInt32(truncatingIfNeeded: stamp)))

        let key: [UInt8] = [0x4A, 0x00, 0x16, head3, 0x47, 0x6C, 0x00, head2]
        var box = (0..<256).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(box[i]) + Int(key[i & 7])) & 0xFF
            box[i] = box[j] // assignment, not swap: matches the reference
        }
        j = 0
        for offset in 0..<20 {
            let i = (offset + 1) & 0xFF
            j = (j + Int(box[i])) & 0xFF
            box[i] = box[j]
            seed[offset] ^= box[(Int(box[i]) + Int(box[j])) & 0xFF]
        }
        for i in 0..<20 {
            seed[i] = reverse8(rotl8(seed[i], 4) ^ seed[(i + 1) % 20]) ^ 0xEB
        }
        return AppCrypto.hex([0x84, 0x04, head2, head3, 0x00, 0x00] + seed)
    }

    // MARK: X-Ladon

    static func ladon(aid: String, timestamp: Int64, prefix: [UInt8]) -> String {
        let digest = Array(AppCrypto.hex(AppCrypto.md5(prefix + Array(aid.utf8))).utf8)
        var left = AppCrypto.readLE64(digest, 0)
        var right = AppCrypto.readLE64(digest, 8)
        var queue = [AppCrypto.readLE64(digest, 16), AppCrypto.readLE64(digest, 24)]
        var keys: [UInt64] = []
        for i in 0..<34 {
            keys.append(left)
            let mixed = (rotr64(right, 8) &+ left) ^ UInt64(i)
            queue.append(mixed)
            left = mixed ^ rotl64(left, 3)
            right = queue.removeFirst()
        }
        var data = pad(Array("\(timestamp)-1611921764-3019".utf8))
        var offset = 0
        while offset < data.count {
            var bl = AppCrypto.readLE64(data, offset)
            var br = AppCrypto.readLE64(data, offset + 8)
            for key in keys {
                br = key ^ (bl &+ rotr64(br, 8))
                bl = br ^ rotl64(bl, 3)
            }
            putLE64(bl, &data, offset)
            putLE64(br, &data, offset + 8)
            offset += 16
        }
        return AppCrypto.base64(prefix + data)
    }

    // MARK: X-Argus

    static func argus(rawQuery: String, timestamp: Int64, nonce: [UInt8]) throws -> String {
        let key = argusKey
        var parts: [UInt8] = []
        func varint(_ field: UInt64, _ value: UInt64) {
            parts += uvarint(field * 8)
            parts += uvarint(value)
        }
        func bytesField(_ field: UInt64, _ value: [UInt8]) {
            parts += uvarint(field * 8 + 2)
            parts += uvarint(UInt64(value.count))
            parts += value
        }
        varint(1, UInt64(0x20200929 * 2))
        varint(2, 2)
        varint(3, UInt64(AppCrypto.readLE32(nonce, 6)))
        bytesField(4, Array("3019".utf8))
        bytesField(6, Array("1611921764".utf8))
        bytesField(7, Array("6.8.1.32".utf8))
        bytesField(8, Array("v04.07.01-ml-android".utf8))
        varint(9, 135_135_744)
        bytesField(10, [UInt8](repeating: 0, count: 8))
        varint(12, UInt64(bitPattern: timestamp &* 2))
        let bodyHash = AppCrypto.sm3([UInt8](repeating: 0, count: 16))
        let queryHash = AppCrypto.sm3(Array(rawQuery.utf8))
        bytesField(13, Array(bodyHash[0..<6]))
        bytesField(14, Array(queryHash[0..<6]))
        var nested: [UInt8] = [0x08, UInt8(truncatingIfNeeded: 2 + (Int(nonce[10]) % 49) * 2)]
        for field: UInt64 in [2, 3, 4] {
            nested += uvarint(field * 8)
            nested += uvarint(1_388_734)
        }
        bytesField(15, nested)
        bytesField(20, Array("none".utf8))
        varint(21, 738)

        var data = pad(parts)
        let derived = AppCrypto.sm3(key + [0x3C, 0xCC, 0x56, 0x7B] + key)
        var rounds = [UInt64](repeating: 0, count: 72)
        for i in 0..<4 { rounds[i] = AppCrypto.readLE64(derived, i * 8) }
        let constant: UInt64 = 0x3DC94C3A046D678B
        for i in 4..<72 {
            var mixed = rotr64(rounds[i - 1], 3) ^ rounds[i - 3]
            mixed ^= rotr64(mixed, 1)
            rounds[i] = ~rounds[i - 4] ^ mixed ^ ((constant >> UInt64((i - 4) % 62)) & 1) ^ 3
        }
        var offset = 0
        while offset < data.count {
            var left = AppCrypto.readLE64(data, offset)
            var right = AppCrypto.readLE64(data, offset + 8)
            for round in rounds {
                let next = left ^ (rotl64(right, 1) & rotl64(right, 8)) ^ rotl64(right, 2) ^ round
                left = right
                right = next
            }
            putLE64(left, &data, offset)
            putLE64(right, &data, offset + 8)
            offset += 16
        }
        let xor: [UInt8] = [0xD0, 0x4F, 0xFD, 0xFF, 0xD0, 0x4F, 0xFD, 0xFF]
        for i in data.indices { data[i] ^= xor[i % 8] }
        let reversed = Array((xor + data).reversed())
        let container = pad([0xA6, 0xE7, 0x83, 0xEE, 0x70, 0x01, 0x10, 0x09, 0x18] + reversed + [0x56, 0x7B])
        // The container is already block aligned; the reference adds no further padding.
        let encrypted = try AppCrypto.aes128CBC(encrypt: true, key: AppCrypto.md5(Array(key[0..<16])),
                                                iv: AppCrypto.md5(Array(key[16..<32])), container, pkcs7: false)
        return AppCrypto.base64([0x3C, 0xCC] + encrypted)
    }

    // MARK: Headers

    /// All signing headers, in the reference's order. `stamp` is in seconds and must match the
    /// `_rticket` (milliseconds) inside `rawQuery`.
    public static func headers(rawQuery: String, stamp: Int64, nonce: [UInt8], aid: String = "8662") throws -> [(String, String)] {
        guard nonce.count == nonceBytes else { throw HongguoError(.input, "弹幕签名随机数长度无效") }
        return [
            ("X-Gorgon", gorgon(rawQuery: rawQuery, stamp: stamp, nonce: nonce)),
            ("X-Khronos", String(stamp)),
            ("X-SS-Req-Ticket", String(stamp * 1000)),
            ("X-SS-STUB", ""),
            ("X-Argus", try argus(rawQuery: rawQuery, timestamp: stamp, nonce: nonce)),
            ("X-Ladon", ladon(aid: aid, timestamp: stamp, prefix: Array(nonce[2..<6]))),
        ]
    }
}

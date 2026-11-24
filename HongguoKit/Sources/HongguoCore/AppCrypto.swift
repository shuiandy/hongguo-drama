// SPDX-License-Identifier: GPL-3.0-only
// Byte-level primitives shared by the App playback signers (ports of src/native/sm3.js and
// the node:crypto / node:zlib calls used by app-source.js, playback-v5.js,
// playback-signature.js and playback-device.js). No keys or identities live here.
import Foundation
import CryptoKit
import zlib
#if canImport(CommonCrypto)
import CommonCrypto
#endif

enum AppCrypto {
    // MARK: Hashes

    /// SM3 (GB/T 32905). Port of `src/native/sm3.js`.
    static func sm3(_ source: [UInt8]) -> [UInt8] {
        let paddedLength = ((source.count + 9 + 63) / 64) * 64
        var data = [UInt8](repeating: 0, count: paddedLength)
        data.replaceSubrange(0..<source.count, with: source)
        data[source.count] = 0x80
        let bits = UInt64(source.count) &* 8
        for i in 0..<8 { data[paddedLength - 1 - i] = UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i))) }
        var state: [UInt32] = [0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e]
        var w = [UInt32](repeating: 0, count: 68)
        @inline(__always) func rot(_ x: UInt32, _ n: Int) -> UInt32 { let k = UInt32(n & 31); return k == 0 ? x : (x << k) | (x >> (32 - k)) }
        var offset = 0
        while offset < data.count {
            for i in 0..<16 { w[i] = be32(data, offset + i * 4) }
            for i in 16..<68 {
                let x = w[i - 16] ^ w[i - 9] ^ rot(w[i - 3], 15)
                w[i] = x ^ rot(x, 15) ^ rot(x, 23) ^ rot(w[i - 13], 7) ^ w[i - 6]
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let a12 = rot(a, 12)
                let s1 = rot(a12 &+ e &+ rot(i < 16 ? 0x79cc4519 : 0x7a879d8a, i), 7)
                let s2 = s1 ^ a12
                let ff = i < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c)
                let gg = i < 16 ? e ^ f ^ g : (e & f) | (~e & g)
                let t1 = ff &+ d &+ s2 &+ (w[i] ^ w[i + 4])
                let t2 = gg &+ h &+ s1 &+ w[i]
                d = c; c = rot(b, 9); b = a; a = t1
                h = g; g = rot(f, 19); f = e
                e = t2 ^ rot(t2, 9) ^ rot(t2, 17)
            }
            let next = [a, b, c, d, e, f, g, h]
            for i in 0..<8 { state[i] ^= next[i] }
            offset += 64
        }
        var digest: [UInt8] = []
        for v in state { digest += be32Bytes(v) }
        return digest
    }

    static func md5(_ data: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: data)) }
    static func sha512(_ data: [UInt8]) -> [UInt8] { Array(SHA512.hash(data: data)) }

    // MARK: AES-128-CBC

    static func aes128CBC(encrypt: Bool, key: [UInt8], iv: [UInt8], _ data: [UInt8], pkcs7: Bool) throws -> [UInt8] {
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(pkcs7 ? kCCOptionPKCS7Padding : 0),
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw HongguoError(.decrypt, "AES 运算失败") }
        return Array(out[0..<moved])
        #else
        throw HongguoError(.decrypt, "当前平台不支持 AES")
        #endif
    }

    // MARK: gzip (zlib)

    static func gzip(_ input: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw HongguoError(.format, "gzip 初始化失败")
        }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 32)
        var source = input
        let status: Int32 = source.withUnsafeMutableBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                stream.next_in = src.baseAddress
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.baseAddress
                stream.avail_out = uInt(dst.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw HongguoError(.format, "gzip 压缩失败") }
        return Array(output[0..<Int(stream.total_out)])
    }

    /// Bounded gunzip, used to validate signed bodies.
    static func gunzip(_ input: [UInt8], limit: Int = 2 * 1024 * 1024) throws -> [UInt8] {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw HongguoError(.format, "gzip 初始化失败")
        }
        defer { inflateEnd(&stream) }
        var source = input
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var status: Int32 = Z_OK
        try source.withUnsafeMutableBufferPointer { src in
            stream.next_in = src.baseAddress
            stream.avail_in = uInt(src.count)
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { dst in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = uInt(dst.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw HongguoError(.format, "gzip 数据无效") }
                result += chunk[0..<(chunk.count - Int(stream.avail_out))]
                if result.count > limit { throw HongguoError(.format, "gzip 数据过大") }
            } while status != Z_STREAM_END && stream.avail_in > 0
        }
        guard status == Z_STREAM_END else { throw HongguoError(.format, "gzip 数据不完整") }
        return result
    }

    // MARK: Encoding helpers

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
    static func be32Bytes(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    static func be32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }
    static func readLE32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
    static func readLE64(_ d: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[o + i]) << (8 * UInt64(i)) }
        return v
    }

    static func hex(_ bytes: [UInt8], uppercase: Bool = false) -> String {
        bytes.map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined()
    }

    static func fromHex(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexValue(chars[i]), let lo = hexValue(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }

    /// Node `Buffer.from(text, 'base64')`: accepts standard and URL-safe alphabets, ignores
    /// invalid characters and missing padding.
    static func base64Decode(_ text: String) -> [UInt8] {
        var table = [Int](repeating: -1, count: 256)
        for (i, c) in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8).enumerated() { table[Int(c)] = i }
        table[Int(UInt8(ascii: "-"))] = 62
        table[Int(UInt8(ascii: "_"))] = 63
        var out: [UInt8] = []
        var acc = 0, bits = 0
        for c in text.utf8 {
            if c == UInt8(ascii: "=") { break }
            let v = table[Int(c)]
            if v < 0 { continue }
            acc = (acc << 6) | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> bits) & 255))
            }
        }
        return out
    }

    static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    /// `encodeURIComponent` plus `!'()` escaping (Python `quote(safe='')` / Java URLEncoder parity).
    static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func encodeQuery(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(urlEncode($0.0))=\(urlEncode($0.1))" }.joined(separator: "&")
    }

    /// `decodeURIComponent(x.replace(/\+/g, ' '))` lookup of the first matching key.
    static func queryParam(_ query: String, _ name: String) -> String? {
        func decode(_ s: String) -> String {
            let spaced = s.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        for part in query.split(separator: "&", omittingEmptySubsequences: false) {
            let piece = String(part)
            if let eq = piece.firstIndex(of: "=") {
                if decode(String(piece[..<eq])) == name { return decode(String(piece[piece.index(after: eq)...])) }
            } else if decode(piece) == name {
                return ""
            }
        }
        return nil
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    static func random32() -> UInt32 { UInt32.random(in: 0...UInt32.max) }

    static func uuid() -> String { UUID().uuidString.lowercased() }
}

/// Minimal protobuf writer for the playback signers.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    static func varint(_ value: UInt64) -> [UInt8] {
        var n = value
        var out: [UInt8] = []
        while n > 127 { out.append(UInt8(n & 127) | 128); n >>= 7 }
        out.append(UInt8(n))
        return out
    }

    static func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value << 1) ^ (value >> 63)) }

    /// Varint field (wire type 0) with a raw unsigned value.
    mutating func uint(_ tag: Int, _ value: UInt64) {
        bytes += Self.varint(UInt64(tag) << 3)
        bytes += Self.varint(value)
    }

    /// Pre-encoded field bytes (for wire types the helpers do not cover).
    mutating func raw(_ value: [UInt8]) { bytes += value }

    /// 32-bit IEEE 754 float field (wire type 5, little-endian).
    mutating func float(_ tag: Int, _ value: Float) {
        bytes += Self.varint(UInt64(tag) << 3 | 5)
        bytes += AppCrypto.le32(value.bitPattern)
    }

    /// Zig-zag encoded signed field (app-source.js / playback-v5.js `'sint'`).
    mutating func sint(_ tag: Int, _ value: Int64) { uint(tag, Self.zigzag(value)) }

    /// Length-delimited field. `skipEmpty` mirrors helpers that drop empty strings.
    mutating func bytes(_ tag: Int, _ value: [UInt8], skipEmpty: Bool = true) {
        if skipEmpty && value.isEmpty { return }
        bytes += Self.varint(UInt64(tag) << 3 | 2)
        bytes += Self.varint(UInt64(value.count))
        bytes += value
    }

    mutating func string(_ tag: Int, _ value: String, skipEmpty: Bool = true) {
        bytes(tag, Array(value.utf8), skipEmpty: skipEmpty)
    }
}

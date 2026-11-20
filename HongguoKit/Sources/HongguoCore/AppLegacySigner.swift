// SPDX-License-Identifier: GPL-3.0-only
// Swift port of the search / catalogue signing in src/native/app-source.js (xGorgon, helios,
// buildMedusa with AesV3, branchOf, signedSearchRequest, signedMetadataRequest). Those were
// adapted from woshishiq1/drpys 22261adfa31435e3b3ef5a730b8a2a75bcaf1715 via N3urda/hongguoTV
// eea73e6a45569a2cbbb9440f7cd5290c459b0b70 (GPL-3.0). Crypto tables and SDK protocol constants
// below are not user credentials. Only hash branch 0 is needed: callers pick tickets until the
// request lands on it, exactly like the JS.
import Foundation

struct AppLegacySigner {
    struct Signed: Equatable { var url: String; var query: String; var headers: [(String, String)]; var body: [UInt8]?
        static func == (a: Signed, b: Signed) -> Bool {
            a.url == b.url && a.body == b.body && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
        }
    }

    var processNonce: String
    var processStarted: Int64
    /// Unsigned 32-bit random source standing in for `Math.floor(Math.random() * 2^32)`.
    var random32: () -> UInt32
    /// Device ids used for catalogue requests (random per process in the JS).
    var metadataDeviceId: String
    var metadataInstallId: String

    static func localId() -> String {
        let random = AppCrypto.randomBytes(6).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return String(1_000_000_000_000_000 + random)
    }

    static let shared = AppLegacySigner(
        processNonce: AppCrypto.base64(AppCrypto.randomBytes(18)).base64URL,
        processStarted: Int64(Date().timeIntervalSince1970 * 1000),
        random32: AppCrypto.random32, metadataDeviceId: localId(), metadataInstallId: localId())

    static let searchAPI = "https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/search/tab/v"
    static let metadataHost = "https://api5-normal-sinfonlineb.fqnovel.com"
    static let searchUA = "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
    static let metadataUA = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

    static let device: [(String, String)] = [
        ("ac", "wifi"), ("channel", "update_64"), ("aid", "8662"), ("app_name", "novelread"),
        ("version_code", "71332"), ("version_name", "7.1.3.32"), ("device_platform", "android"), ("os", "android"),
        ("ssmix", "a"), ("device_type", "25053RT47C"), ("device_brand", "Redmi"), ("language", "zh"), ("os_api", "36"),
        ("os_version", "16"), ("manifest_version_code", "71332"), ("resolution", "1280*2772"), ("dpi", "520"),
        ("update_version_code", "71332"), ("host_abi", "arm64-v8a"), ("dragon_device_type", "phone"), ("pv_player", "71332"),
        ("compliance_status", "0"), ("need_personal_recommend", "1"), ("player_so_load", "1"), ("is_android_pad_screen", "0"),
    ]

    /// `{ ...DEVICE, overrides }`: existing keys keep their place, new keys are appended.
    static func merged(_ base: [(String, String)], _ overrides: [(String, String)]) -> [(String, String)] {
        var out = base
        for (key, value) in overrides {
            if let at = out.firstIndex(where: { $0.0 == key }) { out[at].1 = value } else { out.append((key, value)) }
        }
        return out
    }

    static func versioned(_ code: String, _ name: String) -> [(String, String)] {
        merged(device, [("version_code", code), ("version_name", name), ("manifest_version_code", code),
                        ("update_version_code", code), ("pv_player", code)])
    }

    // MARK: Bit helpers

    @inline(__always) static func rol32(_ v: UInt32, _ c: Int) -> UInt32 {
        let n = UInt32(c & 31)
        return n == 0 ? v : (v << n) | (v >> (32 - n))
    }
    @inline(__always) static func ror32(_ v: UInt32, _ c: Int) -> UInt32 { rol32(v, 32 - (c & 31)) }

    static func getIv(_ initial: UInt32, _ data: [UInt8]) -> UInt32 {
        var value = initial
        for (i, byte) in data.enumerated() {
            if i & 1 == 0 { value = (value >> 4) ^ value ^ (value << 6) ^ UInt32(byte) }
            else { value = ~((value >> 7) ^ value ^ (UInt32(byte) | (value << 12))) }
        }
        return value
    }

    static func sumMd5(_ data: [UInt8]) -> UInt32 {
        var check: UInt32 = 0x20220420
        for i in 0..<12 {
            let temp = i & 1 == 0 ? (check >> 3) ^ check : (check >> 5) ^ check
            check = i & 1 == 0 ? UInt32(data[i]) ^ (check << 7) : UInt32(data[i]) | (check << 11)
            if i & 1 != 0 { check = ~check }
            check ^= temp
        }
        return (check | 4) ^ 0x1000000
    }

    static func branch(querySm3: [UInt8], bodyMd5: [UInt8], ts: UInt32) -> UInt32 {
        let iv = getIv(getIv(getIv(0x20230928, querySm3), bodyMd5), AppCrypto.le32(ts))
        let low = iv & 15
        return low - ((low * 171) >> 9) * 3
    }

    static let tt02: [UInt32] = [
        0xebb64faf, 0x7aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8, 0xf233eb6f, 0xb1a584cc,
        0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288, 0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00,
        0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e, 0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6,
        0x736f8650, 0x6560306c, 0x617ce2a6, 0xe423417e, 0xa40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x5b23bb3,
        0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8, 0x72aad10d, 0x26c53a3d,
        0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14, 0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1,
        0x6ca86f6e, 0x284ba7, 0x8387cfa, 0x5fb37586,
    ]

    /// `hashF13` for branch 0 (the only branch these requests use).
    static func hashF13(querySm3: [UInt8], bodyMd5: [UInt8], ts: UInt32) throws -> [UInt8] {
        let tsBytes = AppCrypto.le32(ts)
        let iv = getIv(getIv(getIv(0x20230928, querySm3), bodyMd5), tsBytes)
        let low = iv & 15, ivV0 = Int((low * 171) >> 9)
        guard low - UInt32(ivV0) * 3 == 0 else { throw HongguoError(.format, "App 签名分支不受支持") }
        let ivV1List: [UInt32] = [0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1]
        let ivV1 = ivV1List[ivV0]
        let countV1 = Int((ivV1 &+ ts &+ 1) & 255), countV2 = ivV1 &+ ts
        let tt = tt02.map { ror32($0, countV1) }
        let n0 = Int((countV2 &+ 2) & 7)
        let pad = [0xfa, 0x45, 0x61, 0xd7].map { UInt8((($0 | ($0 << 8)) >> n0) & 255) }
        let data = querySm3 + bodyMd5 + tsBytes + pad + AppCrypto.fromHex("00000000000001a0")!
        var di: [UInt32] = stride(from: 0, to: data.count, by: 4).map { AppCrypto.be32(data, $0) }
        var di0 = di[0]
        for i in 0..<112 {
            let di1 = di[i + 1], di14 = di[i + 14]
            let r1 = rol32(di1, 14) ^ rol32(di1, 25) ^ (di1 >> 3)
            let r2 = rol32(di14, 13) ^ rol32(di14, 15) ^ (di14 >> 10)
            di.append(di0 &+ di[i + 9] &+ r1 &+ r2)
            di0 = di1
        }
        let initial: [UInt32] = [0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264]
            .map { ror32($0, Int(countV2 & 31)) }
        let chosen = [[101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3], [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4], [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
                      [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6], [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4], [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5]][ivV0]
        var d = initial
        for i in 0..<chosen[0] {
            let base = ivV1 &+ UInt32(i)
            let n0v = di[Int(base & 127)]
            let n1 = ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]
            let n2 = rol32(d[chosen[1]], 26) ^ rol32(d[chosen[1]], 21) ^ rol32(d[chosen[1]], 7)
            let n4 = n0v &+ n1 &+ n2 &+ tt[Int(base & 63)] &+ d[chosen[5]]
            let n5 = rol32(d[chosen[2]], 30) ^ rol32(d[chosen[2]], 19) ^ rol32(d[chosen[2]], 10)
            let n6 = (d[chosen[2]] & d[chosen[6]]) | ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]])
            let n7 = n5 &+ n6
            let old = d[chosen[9]]
            d.insert(d.removeLast(), at: 0)
            d[chosen[10]] = n7 &+ n4
            d[chosen[8]] = old &+ n4
        }
        var ret: [UInt8] = []
        for i in 0..<8 { ret += AppCrypto.be32Bytes(d[i] &+ initial[i]) }
        let folded = (0..<16).map { ret[$0] ^ ret[$0 + 16] }
        return folded + AppCrypto.le32(sumMd5(folded))
    }

    // MARK: X-Gorgon

    static func reverseBits(_ value: UInt8) -> UInt8 {
        var result: UInt8 = 0
        for i in 0..<8 { result = (result << 1) | ((value >> i) & 1) }
        return result
    }

    static func xGorgon(query: String, body: [UInt8]?, ts: UInt32, random: UInt32) -> String {
        let input = Array(AppCrypto.md5(Array(query.utf8))[0..<4]) + (body.map { Array(AppCrypto.md5($0)[0..<4]) } ?? [0, 0, 0, 0])
            + [0, 0, 0, 0] + AppCrypto.le32(67503104) + AppCrypto.be32Bytes(ts)
        let key: [UInt8] = [0x4a, 0x40, 0x16, UInt8((random >> 8) & 255), 0x47, 0x6c, 0x01, UInt8(random & 255)]
        var s = (0..<256).map { UInt8($0) }
        var j = 0
        // Not a swap: the reference only copies s[j] into s[i].
        for i in 0..<256 { j = (j + Int(s[i]) + Int(key[i % key.count])) & 255; s[i] = s[j] }
        var i = 0
        j = 0
        var out = input.map { value -> UInt8 in
            i += 1
            let x = s[i]
            j += Int(x)
            let y = s[j & 255]
            s[i] = y
            return value ^ s[(Int(y) + Int(y)) & 255]
        }
        for k in 0..<out.count {
            let value = (out[k] >> 4) | (out[k] << 4)
            let next = k + 1 < out.count ? out[k + 1] : out[0]
            out[k] = ~(reverseBits(next ^ value) ^ 20)
        }
        return AppCrypto.hex([0x84, 0x04, UInt8(random & 255), UInt8((random >> 8) & 255), 0x40, 0x01] + out)
    }

    // MARK: Medusa

    static let sbox = AppCrypto.base64Decode("+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==")

    struct AesV3 {
        var box: ArraySlice<UInt8>
        var con2: [Int]
        var order: [Int]
        var keys: [[UInt8]]

        init(key: [UInt8], ts: UInt32) {
            let size = Int(ts & 3)
            box = AppLegacySigner.sbox[(size * 256)..<((size + 1) * 256)]
            con2 = [[1, 0, 2, 3], [2, 0, 3, 1], [0, 1, 3, 2], [1, 0, 2, 3]][size]
            order = [[0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3], [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
                     [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15], [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3]][size]
            let initWord: UInt32 = [0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f][size]
            let initial = (0..<4).flatMap { _ in AppCrypto.le32(initWord) }
            var expanded = (0..<16).map { initial[$0] ^ key[$0 % key.count] } + [UInt8](repeating: 0, count: 32)
            var rounds = 8
            for i in 4..<12 {
                let at = 4 * (i - 1)
                var a = expanded[at], b = expanded[at + 1], c = expanded[at + 2], d = expanded[at + 3]
                if i & 3 == 0 {
                    let t = UInt8(truncatingIfNeeded: initWord >> UInt32(rounds & 24)) ^ box[box.startIndex + Int(b)]
                    b = box[box.startIndex + Int(c)]; c = box[box.startIndex + Int(d)]; d = box[box.startIndex + Int(a)]; a = t
                }
                rounds += 2
                expanded[at + 4] = a ^ expanded[at - 12]; expanded[at + 5] = b ^ expanded[at - 11]
                expanded[at + 6] = c ^ expanded[at - 10]; expanded[at + 7] = d ^ expanded[at - 9]
            }
            keys = (0..<12).map { Array(expanded[($0 * 4)..<($0 * 4 + 4)]) }
        }

        func sbox(_ v: UInt8) -> UInt8 { box[box.startIndex + Int(v)] }

        func block(_ value: [UInt8]) -> [UInt8] {
            var rows = (0..<4).map { Array(value[($0 * 4)..<($0 * 4 + 4)]) }
            func addCon(_ offset: Int) { for i in 0..<4 { for j in 0..<4 { rows[i][j] ^= keys[offset + i][con2[j]] } } }
            addCon(0)
            for round in 1..<3 {
                for i in 0..<4 { for j in 0..<4 { rows[i][j] = sbox(rows[i][j]) } }
                let old = rows
                for i in 0..<4 { rows[i] = old[con2[i]] }
                let flat = rows.flatMap { $0 }
                for i in 0..<16 { rows[i / 4][i % 4] = flat[order[i]] }
                if round == 1 {
                    let before = rows
                    for i in 0..<4 { rows[i] = con2.map { before[i][$0] } }
                    for i in 0..<4 {
                        let t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i], u = rows[0][i]
                        func xt(_ x: UInt8) -> UInt8 { (x << 1) ^ ((x & 128) != 0 ? 0x1b : 0) }
                        rows[0][i] ^= t ^ xt(rows[0][i] ^ rows[1][i])
                        rows[1][i] ^= t ^ xt(rows[1][i] ^ rows[2][i])
                        rows[2][i] ^= t ^ xt(rows[2][i] ^ rows[3][i])
                        rows[3][i] ^= t ^ xt(rows[3][i] ^ u)
                    }
                }
                addCon(round * 4)
            }
            for i in 0..<4 { for j in 0..<4 { rows[i][j] ^= keys[4 + i][j] } }
            return rows.flatMap { $0 }
        }

        func encrypt(_ source: [UInt8], iv: [UInt8]) throws -> [UInt8] {
            guard source.count >= 248 else { throw HongguoError(.format, "App 签名数据过短") }
            var plaintext = [UInt8](repeating: 0, count: 32)
            for i in 0..<31 {
                let at = i * 8
                var n = (source[at] >> 4) & 2
                n |= source[at + 1] & 64
                n |= (source[at + 2] >> 2) & 1
                n |= (source[at + 3] << 3) & 128
                n |= (source[at + 4] >> 1) & 4
                n |= (source[at + 5] << 3) & 16
                n |= (source[at + 6] << 5) & 32
                plaintext[i] = n | ((source[at + 7] >> 4) & 8)
            }
            plaintext[31] = 1
            var key: [UInt8] = []
            var previous = iv
            for at in stride(from: 0, to: 32, by: 16) {
                let value = block((0..<16).map { plaintext[at + $0] ^ previous[$0] })
                key += value
                previous = value
            }
            var out = source
            for i in 0..<31 {
                let at = i * 8, k = key[i]
                out[at] = (out[at] & 0xdf) | ((k << 4) & 32)
                out[at + 1] = (out[at + 1] & 0xbf) | (k & 64)
                out[at + 2] = (out[at + 2] & 0xfb) | ((k << 2) & 4)
                out[at + 3] = (out[at + 3] & 0xef) | ((k >> 3) & 16)
                out[at + 4] = (out[at + 4] & 0xf7) | ((k &+ k) & 8)
                out[at + 5] = (out[at + 5] & 0xfd) | ((k >> 3) & 2)
                out[at + 6] = (out[at + 6] & 0xfe) | ((k >> 5) & 1)
                out[at + 7] = (out[at + 7] & 0x7f) | ((k << 4) & 128)
            }
            return [key[key.count - 1]] + out
        }
    }

    static func xmxor(_ data: [UInt8], _ key: [UInt8]) -> [UInt8] {
        let n = data.count
        var encoded = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let at = (i * 4) & 28
            let d0 = Int(key[at]), d1 = Int(key[at + 1])
            var d2 = ((((Int(data[i]) << 4) | (Int(data[i]) >> 4)) & 255) + d0)
            d2 = (~d2) ^ d1
            d2 = (((d2 & 255) << 3) | ((d2 & 255) >> 5)) & 255
            d2 = (d2 + d1) & 255
            d2 = (d2 ^ d0) & 255
            encoded[n - i - 1] = (~d2) & 255
        }
        let last = encoded[n - 1] ^ encoded[n - 2], first = encoded[0]
        encoded[0] = (~last + first) & 255
        encoded[1] = ((encoded[0] ^ encoded[n - 1] ^ 254) + encoded[1]) & 255
        encoded[2] = (encoded[2] + ((last - first) ^ (((encoded[1] << 3) | (encoded[1] >> 5)) & 255) ^ 2)) & 255
        for i in 0..<(n - 4) {
            let temp = (((encoded[i + 2] << 3) | (encoded[i + 2] >> 5)) & 255) ^ encoded[i + 1] ^ (i + 3)
            encoded[i + 3] = (~temp + encoded[i + 3]) & 255
        }
        encoded[n - 1] ^= encoded[n - 2]
        var sum = 0
        for i in 0..<(n - 1) { sum += encoded[i + 1] }
        encoded[0] = ((encoded[0] ^ encoded[1]) + sum) & 255
        return encoded.map { UInt8($0 & 255) }
    }

    static func float(_ writer: inout ProtoWriter, _ tag: Int) {
        writer.raw(ProtoWriter.varint(UInt64(tag) << 3 | 5) + [0, 0, 0, 0])
    }

    func deviceProto(_ deviceId: String) -> [UInt8] {
        var p = ProtoWriter()
        p.sint(1, 1); p.sint(2, 2); p.string(3, "8662"); p.string(4, deviceId); p.string(5, processNonce)
        p.string(6, "!noperm!"); p.sint(7, -888888); p.sint(8, -888888); p.sint(9, 3); p.sint(10, -888888)
        p.string(11, "!notset!"); p.string(12, "Asia/Shanghai,8"); p.string(13, "zh_CN"); p.sint(14, 4)
        for tag in 16...21 { Self.float(&p, tag) }
        p.string(22, "16"); p.sint(23, 41); p.sint(24, 36)
        for tag in 25...28 { p.sint(tag, processStarted) }
        p.sint(29, -1); p.string(30, "25053RT47C"); p.string(31, "Redmi"); p.string(32, "25053RT47C"); p.string(33, "25053RT47C")
        p.string(34, "Xiaomi"); p.string(35, "Redmi"); p.string(36, "Redmi"); p.sint(38, 31)
        return p.bytes
    }

    func medusa(url: String, body: [UInt8]?, ts: UInt32, deviceId: String, versionName: String, nowMillis: Int64) throws -> String {
        let query = Array((url.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? "").utf8)
        let bodyMd5 = body.map(AppCrypto.md5) ?? [UInt8](repeating: 0, count: 16)
        let querySm3 = AppCrypto.sm3(query)
        let f13 = try Self.hashF13(querySm3: querySm3, bodyMd5: bodyMd5, ts: ts)
        var nested = ProtoWriter()
        nested.sint(1, 111); nested.sint(2, 10); nested.sint(3, 694367); nested.sint(5, 586952199)
        let messageRand = random32()
        let envLaunch = Int64((UInt64(random32()) * 21) >> 32) + 100
        let envPid = Int64((UInt64(random32()) * 2000) >> 32) + 10001
        var clock = ProtoWriter()
        clock.sint(1, nowMillis / 1000); clock.sint(2, -2); clock.sint(4, 200)
        var env = ProtoWriter()
        env.sint(1, envLaunch); env.sint(2, 146331399); env.sint(3, 146331396); env.sint(5, 7)
        env.string(6, "v04.06.04.03-bugfix"); env.sint(7, envPid); env.bytes(12, deviceProto(deviceId))
        env.bytes(13, clock.bytes); env.string(14, versionName)
        let queryHash = AppCrypto.sm3(query + bodyMd5 + Array("none".utf8))
        let magic = AppCrypto.fromHex("f7e85ffad7d7dc3bd62ac87057cf6118")!
        let flags = AppCrypto.fromHex("4001000000000000")!
        var message = ProtoWriter()
        message.bytes(1, magic); message.sint(2, 3); message.sint(3, Int64(messageRand)); message.string(4, "8662")
        message.string(5, deviceId); message.string(6, "1588093228"); message.string(7, versionName)
        message.string(8, "v04.06.04-ml-android"); message.sint(9, 67503104); message.bytes(10, flags)
        message.sint(12, Int64(ts)); message.bytes(13, f13); message.bytes(14, Array(querySm3[0..<6]))
        message.bytes(15, nested.bytes); message.string(16, processNonce); message.sint(17, Int64(ts))
        message.bytes(19, queryHash); message.string(20, "none"); message.sint(21, 312); message.bytes(23, env.bytes)
        message.string(24, #"{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}"#)
        let random = random32()
        let signKey = AppCrypto.fromHex("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")!
        let hash = AppCrypto.sm3(signKey + AppCrypto.le32(random) + signKey)
        let d1 = (random >> 16) & 255
        let seed = AppCrypto.le32(~(((d1 << 11) | (random >> 24)) ^ (d1 >> 5) ^ d1))
        var transformed = Array((flags + Self.xmxor(message.bytes, hash)).reversed())
        for i in 0..<transformed.count { transformed[i] ^= seed[(~i) & 3] }
        let check: UInt32 = (UInt32(querySm3[0] & 63) << 14) | 0x18000001 | (UInt32(f13[0] & 63) << 8)
        let xmRand = random32()
        let packed = [0x35] + AppCrypto.le32(xmRand) + AppCrypto.le32(check) + transformed
            + [UInt8((random >> 16) & 255), UInt8(random >> 24)]
        let encrypted = try AesV3(key: AppCrypto.fromHex("f1593376766ea98d34f31b057a9d5be4")!, ts: ts)
            .encrypt(packed, iv: AppCrypto.fromHex("1fe109a4125283f418de9e051a969e12")!)
        let version = AppCrypto.fromHex("03000000f7e85ffad7d7dc3bd62ac87057cf6118")!
        var prefix: [UInt8] = []
        for at in stride(from: 0, to: 20, by: 4) { prefix += AppCrypto.le32(AppCrypto.readLE32(version, at) ^ ts) }
        return AppCrypto.base64(prefix + [UInt8(random & 255), UInt8((random >> 8) & 255), 0, 1] + encrypted)
    }

    func helios(ts: UInt32) -> String {
        let nonce = AppCrypto.le32(random32())
        let ascii = Array(AppCrypto.hex(AppCrypto.md5(nonce + Array("8662".utf8))).utf8)
        var words = (0..<4).map { AppCrypto.readLE64(ascii, $0 * 8) }
        var table = [words[0]]
        var b0 = words.removeFirst(), b8 = words.removeFirst()
        for i in 0..<34 {
            var value = (PlaybackSignerV5.ror64(b8, 8) &+ b0) ^ UInt64(i)
            words.append(value)
            value ^= PlaybackSignerV5.ror64(b0, 61)
            table.append(value); b0 = value; b8 = words.removeFirst()
        }
        let text = Array("\(ts)-1588093228-8662".utf8)
        let padding = 16 - text.count % 16
        let data = text + [UInt8](repeating: UInt8(padding), count: padding)
        var output: [UInt8] = []
        for at in stride(from: 0, to: data.count, by: 16) {
            var a = AppCrypto.readLE64(data, at), b = AppCrypto.readLE64(data, at + 8)
            for i in 0..<34 { b = table[i] ^ (a &+ PlaybackSignerV5.ror64(b, 8)); a = b ^ PlaybackSignerV5.ror64(a, 61) }
            output += AppCrypto.le64(a) + AppCrypto.le64(b)
        }
        return AppCrypto.base64(nonce + output)
    }

    // MARK: Requests

    struct SearchCursor: Equatable, Sendable {
        var searchId: String
        var passback: String
        var nextOffset: Int?
    }

    /// Port of `signedSearchRequest` (hongguoTV 7.2.2.32 profile, hash branch 0).
    func search(keyword: String, page: Int, cursor: SearchCursor?, identity: PlaybackIdentity, nowMillis: Int64) throws -> Signed {
        guard (1...50).contains(page) else { throw HongguoError(.input, "App 搜索页码需为 1 至 50 的整数") }
        guard [identity.deviceId, identity.iid].allSatisfy({ $0.matchesDigits(min: 1, max: 30) && $0.contains(where: { $0 != "0" }) }),
              identity.cdid.range(of: "^[a-fA-F0-9-]{36}$", options: .regularExpression) != nil else {
            throw HongguoError(.input, "App 搜索设备身份无效")
        }
        let device = Self.merged(Self.versioned("72232", "7.2.2.32"),
                                 [("iid", identity.iid), ("device_id", identity.deviceId), ("cdid", identity.cdid)])
        let ts = UInt32(nowMillis / 1000)
        var base = device + [("query", String(keyword.prefix(80))), ("count", "20"), ("tab_type", "11"),
                             ("bookshelf_search_plan", "4"), ("use_correct", "true"), ("user_is_login", "0")]
        if let cursor, !cursor.searchId.isEmpty { base.append(("search_id", cursor.searchId)) }
        if let cursor, !cursor.passback.isEmpty { base.append(("passback", cursor.passback)) }
        base.append(("offset", String(cursor?.nextOffset ?? (page - 1) * 20)))
        let random = random32() >> 16
        for n in 0..<128 {
            let ticket = String(nowMillis + Int64(n))
            let query = AppCrypto.encodeQuery(base + [("ts", String(ts)), ("_rticket", ticket)])
            let url = "\(Self.searchAPI)?\(query)"
            guard Self.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: [UInt8](repeating: 0, count: 16), ts: ts) == 0 else { continue }
            let headers: [(String, String)] = [
                ("User-Agent", Self.searchUA), ("Accept", "application/json; charset=utf-8,application/x-protobuf"),
                ("x-ss-req-ticket", ticket), ("x-tt-request-tag", "t=0;n=0"), ("sdk-version", "2"),
                ("passport-sdk-version", "50561"), ("x-xs-from-web", "0"), ("x-khronos", String(ts)),
                ("x-ladon", AppCrypto.base64(AppCrypto.be32Bytes(ts))), ("x-argus", AppCrypto.base64(AppCrypto.le32(ts))),
                ("x-gorgon", Self.xGorgon(query: query, body: nil, ts: ts, random: random)), ("x-helios", helios(ts: ts)),
                ("x-medusa", try medusa(url: url, body: nil, ts: ts, deviceId: identity.deviceId, versionName: "7.2.2.32", nowMillis: nowMillis)),
                ("x-tt-dt", ""),
            ]
            return Signed(url: url, query: query, headers: headers, body: nil)
        }
        throw HongguoError(.format, "无法生成搜索请求签名")
    }

    static let accountPaths = ["/reading/user/info/v1/", "/reading/bookapi/read_history/list/v1/",
                               "/reading/bookapi/read_progress/list/v1/", "/reading/bookapi/multi-detail/v1/"]
    static let accountHost = "https://api5-normal-sinfonlinea.fqnovel.com"

    /// Port of `signedAccountRequest`: the registered identity plus the website login cookie (added by the caller).
    func account(path: String, values: [(String, String)], identity: PlaybackIdentity, nowMillis: Int64) throws -> Signed {
        guard Self.accountPaths.contains(path) else { throw HongguoError(.input, "不支持的账号接口") }
        guard [identity.deviceId, identity.iid].allSatisfy({ $0.matchesDigits(min: 1, max: 30) && $0.contains(where: { $0 != "0" }) }),
              identity.cdid.range(of: "^[a-fA-F0-9-]{36}$", options: .regularExpression) != nil else {
            throw HongguoError(.input, "账号设备身份无效")
        }
        let device = Self.merged(Self.versioned("72232", "7.2.2.32"),
                                 [("iid", identity.iid), ("device_id", identity.deviceId), ("cdid", identity.cdid)])
        let ts = UInt32(nowMillis / 1000)
        let fields = Self.merged(values, device)
        for n in 0..<128 {
            let ticket = String(nowMillis + Int64(n))
            let query = AppCrypto.encodeQuery(fields + [("ts", String(ts)), ("_rticket", ticket)])
            let url = "\(Self.accountHost)\(path)?\(query)"
            guard Self.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: [UInt8](repeating: 0, count: 16), ts: ts) == 0 else { continue }
            let headers: [(String, String)] = [
                ("User-Agent", Self.searchUA), ("Accept", "application/json; charset=utf-8,application/x-protobuf"),
                ("x-ss-req-ticket", ticket), ("x-tt-request-tag", "t=0;n=0"), ("sdk-version", "2"),
                ("passport-sdk-version", "50561"), ("x-xs-from-web", "0"), ("x-khronos", String(ts)),
                ("x-ladon", AppCrypto.base64(AppCrypto.be32Bytes(ts))), ("x-argus", AppCrypto.base64(AppCrypto.le32(ts))),
                ("x-gorgon", Self.xGorgon(query: query, body: nil, ts: ts, random: random32() >> 16)), ("x-helios", helios(ts: ts)),
                ("x-medusa", try medusa(url: url, body: nil, ts: ts, deviceId: identity.deviceId, versionName: "7.2.2.32", nowMillis: nowMillis)),
                ("x-tt-dt", ""),
            ]
            return Signed(url: url, query: query, headers: headers, body: nil)
        }
        throw HongguoError(.format, "无法生成账号请求签名")
    }

    static let metadataPaths = ["/reading/distribution/category/landpage/v/", "/reading/bookapi/bookmall/cell/change/v"]

    /// Port of `signedMetadataRequest` (catalogue lists; one anonymous identity per process).
    /// `identity` and `dToken` (the persistent device) replace the fixed metadata device.
    func metadata(path: String, values: [(String, String)], payload: [UInt8]?, identity: PlaybackIdentity? = nil,
                  dToken: String = "", nowMillis: Int64) throws -> Signed {
        guard Self.metadataPaths.contains(path) else { throw HongguoError(.input, "不支持的 App 目录接口") }
        let devId = identity?.deviceId ?? metadataDeviceId
        var devicePairs: [(String, String)] = [("iid", identity?.iid ?? metadataInstallId), ("device_id", devId)]
        if let cdid = identity?.cdid, !cdid.isEmpty { devicePairs.append(("cdid", cdid)) }
        let device = Self.merged(Self.versioned("73532", "7.3.5.32"), devicePairs)
        let ts = UInt32(nowMillis / 1000)
        let bodyMd5 = payload.map(AppCrypto.md5) ?? [UInt8](repeating: 0, count: 16)
        // `{ ...values, ...metadataDevice }`: device fields win but keep the position of an earlier key.
        let fields = Self.merged(values, device)
        for n in 0..<128 {
            let ticket = String(nowMillis + Int64(n))
            let query = AppCrypto.encodeQuery(fields + [("ts", String(ts)), ("_rticket", ticket)])
            let url = "\(Self.metadataHost)\(path)?\(query)"
            guard Self.branch(querySm3: AppCrypto.sm3(Array(query.utf8)), bodyMd5: bodyMd5, ts: ts) == 0 else { continue }
            var headers: [(String, String)] = [
                ("User-Agent", Self.metadataUA), ("Accept", "application/json"), ("Accept-Encoding", "identity"),
                ("x-xs-from-web", "0"), ("sdk-version", "2"), ("x-ss-dp", "8662"), ("x-tt-store-region", "cn"),
                ("x-tt-store-region-src", "did"), ("x-ss-req-ticket", ticket), ("x-khronos", String(ts)),
                ("x-gorgon", Self.xGorgon(query: query, body: payload, ts: ts, random: random32() >> 16)),
                ("x-ladon", AppCrypto.base64(AppCrypto.be32Bytes(ts))), ("x-argus", AppCrypto.base64(AppCrypto.le32(ts))),
                ("x-helios", helios(ts: ts)),
                ("x-medusa", try medusa(url: url, body: payload, ts: ts, deviceId: devId, versionName: "7.3.5.32", nowMillis: nowMillis)),
                ("x-tt-dt", dToken),
            ]
            if let payload {
                headers.append(("Content-Type", "application/json; charset=utf-8"))
                headers.append(("x-ss-stub", AppCrypto.hex(AppCrypto.md5(payload), uppercase: true)))
            }
            return Signed(url: url, query: query, headers: headers, body: payload)
        }
        throw HongguoError(.format, "无法生成 App 目录请求签名")
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Swift port of src/native/playback-v5.js, itself a port of N3urda/hongguoTV
// 18c37c2afd0567520135abcae312352542f09083: Signer.kt, AesV3.kt, V5Constants.kt;
// originally drpys 22261ad (GPL-3.0).
// Public wire constants, no captured sessions, SDK, VM or PolyForm implementation.
import Foundation
import CryptoKit

/// Signs the App `multi_video_model/player/v1` request: X-Khronos / X-Helios / X-Medusa / X-SS-Stub.
struct PlaybackSignerV5 {
    struct Signed { var url: String; var query: String; var headers: [(String, String)] }

    /// Process-scoped fields (the JS module samples these once at load).
    var processNonce: String
    var processStarted: Int64
    /// Unsigned 32-bit random source; injectable so tests can replay node vectors.
    var random32: () -> UInt32

    static let shared = PlaybackSignerV5(
        processNonce: AppCrypto.base64(AppCrypto.randomBytes(18)).base64URL,
        processStarted: Int64(Date().timeIntervalSince1970 * 1000),
        random32: AppCrypto.random32)

    static let magic = AppCrypto.fromHex("2d4b4fca49750d433fb5ae2c226dcc56")!
    static let signKey = AppCrypto.fromHex("b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d")!
    static let sbox = AppCrypto.fromHex("53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0df37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1dd12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe127400248591238922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c894545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dccd759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8de0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd288fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac91fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443fd830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f44591681335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e")!
    static let hashTable: [UInt32] = [
        0xebb64faf, 0x7aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
        0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
        0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
        0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
        0x617ce2a6, 0xe423417e, 0xa40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x5b23bb3,
        0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
        0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
        0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x284ba7, 0x8387cfa, 0x5fb37586,
    ]

    // MARK: Bit helpers (JS uint32 semantics)

    @inline(__always) static func rol32(_ v: UInt32, _ c: Int) -> UInt32 {
        let n = UInt32(c & 31)
        return n == 0 ? v : (v << n) | (v >> (32 - n))
    }
    @inline(__always) static func ror32(_ v: UInt32, _ c: Int) -> UInt32 { rol32(v, -c) }
    @inline(__always) static func ror64(_ v: UInt64, _ c: Int) -> UInt64 {
        let n = UInt64(c & 63)
        return n == 0 ? v : (v >> n) | (v << (64 - n))
    }

    static func getIv(_ initial: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var value = initial
        for (i, b) in bytes.enumerated() {
            if i & 1 == 0 {
                value = (value >> 4) ^ value ^ (value << 6) ^ UInt32(b)
            } else {
                value = ~((value >> 7) ^ value ^ (UInt32(b) | (value << 12)))
            }
        }
        return value
    }

    static func branch(_ query: [UInt8], _ body: [UInt8], _ ts: UInt32) -> UInt32 {
        getIv(getIv(getIv(0x20230928, query), body), AppCrypto.le32(ts)) & 15
    }

    static func sumMd5(_ bytes: [UInt8]) -> UInt32 {
        var check: UInt32 = 0x20220420
        for i in 0..<12 {
            let temp = (check >> (i & 1 == 0 ? 3 : 5)) ^ check
            check = (i & 1 == 0 ? UInt32(bytes[i]) ^ (check << 7) : ~(UInt32(bytes[i]) | (check << 11))) ^ temp
        }
        return (check | 4) ^ 0x1000000
    }

    // MARK: f13

    static func hashF13(query: [UInt8], body: [UInt8], ts: UInt32) throws -> [UInt8] {
        guard branch(query, body, ts) == 12 else { throw HongguoError(.format, "Unsupported v5 hash branch") }
        let seed: UInt32 = 0x9d4a97c2
        let count = seed &+ ts
        let table = hashTable.map { ror32($0, Int(count & 31) + 1) }
        let shift = Int((count &+ 2) & 7)
        let pad: [UInt8] = [0xfa, 0x45, 0x61, 0xd7].map { v in
            let x = Int(v) | (Int(v) << 8)
            return UInt8((x >> shift) & 255)
        }
        let data = query + body + AppCrypto.le32(ts) + pad + AppCrypto.fromHex("00000000000001a0")!
        var schedule: [UInt32] = stride(from: 0, to: data.count, by: 4).map { AppCrypto.be32(data, $0) }
        for i in 0..<112 {
            let x = schedule[i + 1], y = schedule[i + 14]
            schedule.append(schedule[i] &+ schedule[i + 9] &+ (rol32(x, 14) ^ rol32(x, 25) ^ (x >> 3))
                            &+ (rol32(y, 13) ^ rol32(y, 15) ^ (y >> 10)))
        }
        let initial: [UInt32] = [0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264]
            .map { ror32($0, Int(count & 31)) }
        var state = initial
        for i in 0..<96 {
            let base = Int(seed) + i
            let n1 = ((state[4] ^ state[0]) & state[1]) ^ state[4]
            let n2 = rol32(state[1], 26) ^ rol32(state[1], 21) ^ rol32(state[1], 7)
            let n4 = schedule[base & 127] &+ n1 &+ n2 &+ table[base & 63] &+ state[6]
            let n5 = rol32(state[3], 30) ^ rol32(state[3], 19) ^ rol32(state[3], 10)
            let n6 = (state[3] & state[5]) | ((state[3] | state[5]) & state[2])
            let old = state[7]
            state.insert(state.removeLast(), at: 0)
            state[7] = n5 &+ n6 &+ n4
            state[0] = old &+ n4
        }
        var output: [UInt8] = []
        for i in 0..<8 { output += AppCrypto.be32Bytes(state[i] &+ initial[i]) }
        let folded = (0..<16).map { output[$0] ^ output[$0 + 16] }
        return folded + AppCrypto.le32(sumMd5(folded) | 0x20)
    }

    // MARK: Carrier (two-round, protocol-specific; not standard AES)

    struct Carrier {
        let box: ArraySlice<UInt8>
        let con: [Int]
        let order: [Int]
        let keys: [[UInt8]]

        init(key: [UInt8], ts: UInt32) {
            let word = Int(ts & 3)
            box = PlaybackSignerV5.sbox[(word * 256)..<((word + 1) * 256)]
            con = [[2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]][word]
            order = [
                [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
                [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
                [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
                [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7],
            ][word]
            let initial: UInt32 = [0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9][word]
            let initBytes = Array((0..<4).map { _ in AppCrypto.le32(initial) }.joined())
            var expanded = (0..<16).map { initBytes[$0] ^ key[$0] } + [UInt8](repeating: 0, count: 32)
            let b0 = box.startIndex
            var rounds = 8
            for i in 4..<12 {
                let at = 4 * (i - 1)
                var a = expanded[at], b = expanded[at + 1], c = expanded[at + 2], d = expanded[at + 3]
                if i & 3 == 0 {
                    // JS `initial >> n` is an arithmetic shift of the int32 value; only the low byte is used.
                    let shifted = UInt8(truncatingIfNeeded: Int32(bitPattern: initial) >> Int32(rounds & 24))
                    let temp = shifted ^ box[b0 + Int(b)]
                    b = box[b0 + Int(c)]; c = box[b0 + Int(d)]; d = box[b0 + Int(a)]; a = temp
                }
                rounds += 2
                expanded[at + 4] = a ^ expanded[at - 12]; expanded[at + 5] = b ^ expanded[at - 11]
                expanded[at + 6] = c ^ expanded[at - 10]; expanded[at + 7] = d ^ expanded[at - 9]
            }
            keys = (0..<12).map { Array(expanded[($0 * 4)..<($0 * 4 + 4)]) }
        }

        func block(_ value: [UInt8]) -> [UInt8] {
            let b0 = box.startIndex
            var rows = (0..<4).map { Array(value[($0 * 4)..<($0 * 4 + 4)]) }
            func add(_ offset: Int) {
                for i in 0..<4 { for j in 0..<4 { rows[i][j] ^= keys[offset + i][con[j]] } }
            }
            add(0)
            for round in 1...2 {
                let before = rows.map { $0.map { box[b0 + Int($0)] } }
                let flat = con.flatMap { before[$0] }
                rows = (0..<4).map { i in order[(i * 4)..<(i * 4 + 4)].map { flat[$0] } }
                if round == 1 {
                    rows = rows.map { row in con.map { row[$0] } }
                    func xt(_ x: UInt8) -> UInt8 { (x << 1) ^ ((x & 128) != 0 ? 0x1b : 0) }
                    for i in 0..<4 {
                        let t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i], u = rows[0][i]
                        rows[0][i] ^= t ^ xt(rows[0][i] ^ rows[1][i])
                        rows[1][i] ^= t ^ xt(rows[1][i] ^ rows[2][i])
                        rows[2][i] ^= t ^ xt(rows[2][i] ^ rows[3][i])
                        rows[3][i] ^= t ^ xt(rows[3][i] ^ u)
                    }
                }
                add(round * 4)
            }
            for i in 0..<4 { for j in 0..<4 { rows[i][j] ^= keys[4 + i][j] } }
            return rows.flatMap { $0 }
        }

        func encrypt(_ source: [UInt8], iv: [UInt8]) throws -> [UInt8] {
            guard source.count >= 248 else { throw HongguoError(.format, "V5 carrier requires at least 248 bytes") }
            let wire = [6, 5, 3, 4, 2, 7, 1, 0], compact = [1, 7, 3, 6, 2, 0, 4, 5]
            var plaintext = [UInt8](repeating: 0, count: 32)
            for i in 0..<31 {
                for j in 0..<8 {
                    plaintext[i] |= ((source[i * 8 + j] >> wire[j]) & 1) << compact[j]
                }
            }
            plaintext[31] = 1
            let first = block((0..<16).map { plaintext[$0] ^ iv[$0] })
            let second = block((0..<16).map { plaintext[16 + $0] ^ first[$0] })
            let key = first + second
            var output = source
            for i in 0..<31 {
                for j in 0..<8 {
                    let at = i * 8 + j
                    output[at] = (output[at] & ~(1 << wire[j])) | (((key[i] >> compact[j]) & 1) << wire[j])
                }
            }
            return [key[31]] + output
        }
    }

    // MARK: Medusa / Helios

    static func xmxor(_ data: [UInt8], _ key: [UInt8]) -> [UInt8] {
        let n = data.count
        var encoded = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let at = (i * 4) & 28
            let d0 = Int(key[at]), d1 = Int(key[at + 1])
            let x = Int(data[i])
            var value = (~((((x << 4) | (x >> 4)) & 255) + d0)) ^ d1
            value = (((value & 255) << 3) | ((value & 255) >> 5)) & 255
            encoded[n - i - 1] = ~(((value + d1) & 255) ^ d0) & 255
        }
        let last = encoded[n - 1] ^ encoded[n - 2], first = encoded[0]
        encoded[0] = (~last + first) & 255
        encoded[1] = ((encoded[0] ^ encoded[n - 1] ^ 254) + encoded[1]) & 255
        encoded[2] = (encoded[2] + ((last - first) ^ (((encoded[1] << 3) | (encoded[1] >> 5)) & 255) ^ 2)) & 255
        if n > 4 {
            for i in 0..<(n - 4) {
                let temp = (((encoded[i + 2] << 3) | (encoded[i + 2] >> 5)) & 255) ^ encoded[i + 1] ^ (i + 3)
                encoded[i + 3] = (~temp + encoded[i + 3]) & 255
            }
        }
        encoded[n - 1] ^= encoded[n - 2]
        var sum = 0
        for i in 1..<n { sum += encoded[i] }
        encoded[0] = ((encoded[0] ^ encoded[1]) + sum) & 255
        return encoded.map { UInt8($0 & 255) }
    }

    struct Who { var deviceId, osVersion, deviceType, channel, versionName: String; var brand: String = "HONOR"; var sdkVersion: String = "v04.10.03-ml-android" }

    func medusa(query: [UInt8], f13: [UInt8], ts: UInt32, who: Who) throws -> String {
        let flags = [UInt8](repeating: 0, count: 8)
        var device = ProtoWriter()
        device.sint(1, 1); device.sint(2, 2); device.string(3, "8662"); device.string(4, who.deviceId)
        device.string(5, processNonce); device.string(6, "!noperm!"); device.string(12, "Asia/Shanghai,8")
        device.string(13, "zh_CN"); device.string(22, who.osVersion); device.sint(25, processStarted)
        device.string(30, who.deviceType); device.string(31, who.brand); device.string(32, who.deviceType)
        device.string(34, who.brand)
        var env = ProtoWriter()
        env.string(6, "v04.10.03.04-bugfix"); env.string(8, who.channel); env.bytes(12, device.bytes)
        env.string(14, who.versionName)
        var nested = ProtoWriter()
        nested.sint(1, 1); nested.sint(2, 1); nested.sint(3, 1); nested.sint(5, 1)
        var message = ProtoWriter()
        message.bytes(1, Self.magic); message.sint(2, 5); message.sint(3, Int64(random32()))
        message.string(4, "8662"); message.string(5, who.deviceId); message.string(6, "646637794")
        message.string(7, who.versionName); message.string(8, who.sdkVersion); message.sint(9, 0x040a0300)
        message.bytes(10, flags); message.sint(12, Int64(ts)); message.bytes(13, f13)
        message.bytes(14, Array(query[0..<6])); message.bytes(15, nested.bytes)
        message.sint(17, Int64(ts)); message.string(20, "none"); message.sint(21, 377); message.bytes(23, env.bytes)
        message.string(24, #"{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}"#)

        return try seal(message.bytes, flags: flags, query: query, f13: f13, ts: ts, nonce: random32(), packedRandom: { random32() })
    }

    /// Encrypts a medusa message into the header (shared by both layouts). `packedRandom` is drawn
    /// after the nonce, as the SDK does.
    func seal(_ message: [UInt8], flags: [UInt8], query: [UInt8], f13: [UInt8], ts: UInt32, nonce: UInt32,
              packedRandom: () -> UInt32) throws -> String {
        let high = (nonce >> 16) & 255
        let hash = AppCrypto.sm3(Self.signKey + AppCrypto.le32(nonce) + Self.signKey)
        let seed = AppCrypto.le32(~(((high << 11) | (nonce >> 24)) ^ (high >> 5) ^ high))
        var transformed = Array((flags + Self.xmxor(message, hash)).reversed())
        for i in 0..<transformed.count { transformed[i] ^= seed[(~i) & 3] }
        let check: UInt32 = 0x18000001 | (UInt32(query[0] & 63) << 14) | (UInt32(f13[0] & 63) << 8)
        let packed = [0xca] + AppCrypto.le32(packedRandom()) + AppCrypto.le32(check) + transformed
            + [UInt8((nonce >> 16) & 255), UInt8(nonce >> 24)]
        let carrier = Carrier(key: AppCrypto.md5(Array(Self.signKey[0..<16])), ts: ts)
        let encrypted = try carrier.encrypt(packed, iv: AppCrypto.md5(Array(Self.signKey[16...])))
        var prefix = AppCrypto.le32(5) + Self.magic
        let time = AppCrypto.le32(ts)
        for i in 0..<prefix.count { prefix[i] ^= time[i & 3] }
        return AppCrypto.base64(prefix + [UInt8(nonce & 255), UInt8((nonce >> 8) & 255), 0, 1] + encrypted)
    }

    /// Phone-layout `x-medusa` (v04.10.03 SDK, flags `04 05`, status `369`). Since 2026-11-23 play
    /// requests carrying the legacy emulator status (`377`) receive empty HTTP 200 replies. All
    /// per-device traits and field-24 fingerprint hashes are deterministically derived from
    /// `deviceId` (never shared hardcoded capture hashes).
    func medusaDevice(query: [UInt8], f13: [UInt8], ts: UInt32, who: Who, installMillis: Int64? = nil) throws -> String {
        let flags: [UInt8] = [0x04, 0x05, 0, 0, 0, 0, 0, 0]
        let process = MedusaProcess.shared
        let traits = MedusaProcess.traits(deviceId: who.deviceId, referenceMillis: process.launchMillis)
        let effectiveInstall = installMillis ?? traits.installMillis
        let messageRandom = random32() & 0x7fffffff
        let nowMillis = Int64(ts) * 1000 + Int64(messageRandom % 1000)
        var device = ProtoWriter()
        device.sint(1, 1); device.string(3, "8662"); device.string(4, who.deviceId)
        device.string(5, "!notset!"); device.string(6, "!noperm!")
        device.sint(7, -888888); device.sint(8, -888888); device.sint(9, 2); device.sint(10, -888888)
        device.string(11, "!notset!"); device.string(12, "Asia/Shanghai,8"); device.string(13, "zh_CN"); device.sint(14, 8)
        device.float(16, traits.storage); device.float(17, traits.storageFree)
        device.float(18, traits.memory); device.float(19, traits.memoryFree)
        device.float(20, traits.storage * 2); device.float(21, traits.storageFree * 2)
        device.string(22, who.osVersion); device.sint(23, 60); device.sint(24, 10)
        device.sint(25, effectiveInstall); device.sint(26, process.launchMillis + 540); device.sint(27, effectiveInstall)
        device.sint(28, nowMillis); device.sint(29, 1)
        device.string(30, who.deviceType); device.string(31, who.brand)
        device.string(32, "!notset!"); device.string(33, "!notset!"); device.string(34, "!notset!")
        device.string(35, who.brand); device.string(36, "!notset!"); device.sint(38, 3); device.sint(40, process.launchMillis)
        var env = ProtoWriter()
        env.sint(1, max(1, Int64(ts) - process.launchMillis / 1000))
        env.string(6, "v04.10.03.04-bugfix"); env.sint(7, process.pid); env.string(8, who.channel)
        env.bytes(12, device.bytes); env.raw([0x6a, 0x00])
        env.string(14, who.versionName); env.sint(15, process.ppid)
        env.sint(18, Int64(ts) + 766353820); env.sint(19, Int64(ts) + 16); env.sint(20, Int64(ts) - 1072050540)
        var counters = ProtoWriter()
        counters.sint(1, process.nextCount()); counters.sint(2, 5); counters.sint(3, 694367); counters.sint(5, 694367)
        var message = ProtoWriter()
        message.bytes(1, Self.magic); message.sint(2, 5); message.sint(3, Int64(messageRandom))
        message.string(4, "8662"); message.string(5, who.deviceId); message.string(6, "646637794")
        message.string(7, who.versionName); message.string(8, who.sdkVersion); message.sint(9, 0x040a0300)
        message.bytes(10, flags); message.sint(12, Int64(ts)); message.bytes(13, f13)
        message.bytes(14, Array(query[0..<6])); message.bytes(15, counters.bytes)
        message.sint(17, Int64(ts)); message.string(20, "none"); message.sint(21, 369); message.bytes(23, env.bytes)
        message.string(24, MedusaProcess.fingerprintJSON(deviceId: who.deviceId))
        return try seal(message.bytes, flags: flags, query: query, f13: f13, ts: ts, nonce: random32() & 0x7fffffff,
                        packedRandom: { random32() & 0x7fffffff })
    }

    func helios(ts: UInt32) -> String {
        let nonce = AppCrypto.le32(random32())
        let ascii = Array(AppCrypto.hex(AppCrypto.md5(nonce + Array("8662".utf8))).utf8)
        var words = (0..<4).map { AppCrypto.readLE64(ascii, $0 * 8) }
        var table = [words[0]]
        var b0 = words.removeFirst(), b8 = words.removeFirst()
        for i in 0..<34 {
            var value = (Self.ror64(b8, 8) &+ b0) ^ UInt64(i)
            words.append(value)
            value ^= Self.ror64(b0, 61)
            table.append(value); b0 = value; b8 = words.removeFirst()
        }
        let text = Array("\(ts)-646637794-8662".utf8)
        let padding = 16 - text.count % 16
        let data = text + [UInt8](repeating: UInt8(padding), count: padding)
        var output: [UInt8] = []
        for at in stride(from: 0, to: data.count, by: 16) {
            var a = AppCrypto.readLE64(data, at), b = AppCrypto.readLE64(data, at + 8)
            for i in 0..<34 { b = table[i] ^ (a &+ Self.ror64(b, 8)); a = b ^ Self.ror64(a, 61) }
            output += AppCrypto.le64(a) + AppCrypto.le64(b)
        }
        return AppCrypto.base64(nonce + output)
    }

    // MARK: Entry point

    /// `values` keeps insertion order; `_rticket` is appended. `body` is the exact gzip payload sent.
    func sign(base: String, values: [(String, String)], body: [UInt8], nowMillis: Int64) throws -> Signed {
        guard let parsed = URL(string: base), parsed.scheme == "https", parsed.query == nil, parsed.fragment == nil,
              parsed.user == nil, parsed.password == nil, parsed.port == nil || parsed.port == 443 else {
            throw HongguoError(.input, "V5 base must be an HTTPS URL without query or fragment")
        }
        guard nowMillis >= 0, nowMillis / 1000 <= 0x7fffffff else { throw HongguoError(.input, "V5 now out of range") }
        let lookup = Dictionary(values, uniquingKeysWith: { a, _ in a })
        for key in ["device_id", "iid"] {
            guard let v = lookup[key], v.range(of: "^[1-9][0-9]{0,29}$", options: .regularExpression) != nil else {
                throw HongguoError(.input, "V5 \(key) must be a positive decimal string")
            }
        }
        for key in ["cdid", "version_name", "channel", "os_version", "device_type"] {
            guard let v = lookup[key], !v.trimmingCharacters(in: .whitespaces).isEmpty, v.count <= 128 else {
                throw HongguoError(.input, "V5 \(key) is required and must be bounded")
            }
        }
        if let aid = lookup["aid"], aid != "8662" { throw HongguoError(.input, "V5 aid must be 8662") }
        guard body.count >= 18, body.count <= 2 * 1024 * 1024, body[0] == 0x1f, body[1] == 0x8b, body[2] == 8,
              (try? AppCrypto.gunzip(body)) != nil else {
            throw HongguoError(.input, "V5 body must be a bounded gzip Buffer")
        }
        let ts = UInt32(nowMillis / 1000)
        let bodyHash = AppCrypto.md5(body)
        let fields = values.map { $0.0 == "ts" ? ($0.0, String(ts)) : $0 }
        let isIOS = lookup["device_platform"]?.lowercased() == "iphone"
        let brand = isIOS ? "Apple" : "HONOR"
        let sdkVersion = isIOS ? "v04.10.03-ml-ios" : "v04.10.03-ml-android"
        let who = Who(deviceId: lookup["device_id"]!, osVersion: lookup["os_version"]!, deviceType: lookup["device_type"]!,
                      channel: lookup["channel"]!, versionName: lookup["version_name"]!, brand: brand, sdkVersion: sdkVersion)
        for offset in 0..<1024 {
            let ticket = String(nowMillis + Int64(offset))
            var pairs = fields
            if let at = pairs.firstIndex(where: { $0.0 == "_rticket" }) { pairs[at].1 = ticket } else { pairs.append(("_rticket", ticket)) }
            let query = AppCrypto.encodeQuery(pairs)
            let queryHash = AppCrypto.sm3(Array(query.utf8))
            guard Self.branch(queryHash, bodyHash, ts) == 12 else { continue }
            let f13 = try Self.hashF13(query: queryHash, body: bodyHash, ts: ts)
            let helios = helios(ts: ts)
            let medusa = try medusa(query: queryHash, f13: f13, ts: ts, who: who)
            return Signed(url: "\(parsed.absoluteString)?\(query)", query: query, headers: [
                ("x-khronos", String(ts)), ("x-helios", helios), ("x-medusa", medusa),
                ("x-ss-stub", AppCrypto.hex(bodyHash, uppercase: true)), ("x-ss-req-ticket", ticket),
            ])
        }
        throw HongguoError(.format, "Unable to select V5 playback signature branch within 1024 tickets")
    }
}

extension String {
    /// base64 -> base64url without padding (Node `toString('base64url')`).
    var base64URL: String {
        replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Process-wide and per-device fields for phone-layout `x-medusa`: launch time, process ids,
/// monotonically increasing signature counter, hardware traits, and deterministic per-device
/// field-24 fingerprint hashes.
final class MedusaProcess: @unchecked Sendable {
    static let shared = MedusaProcess()
    let launchMillis = Int64(Date().timeIntervalSince1970 * 1000)
    let pid: Int64
    let ppid: Int64
    private let lock = NSLock()
    private var count: Int64

    init() {
        let nanos = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        pid = 3000 + nanos % 25000
        ppid = 500 + (nanos / 25000) % 700
        count = 20 + nanos % 100
    }

    func nextCount() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    struct Traits: Equatable { var storage, storageFree, memory, memoryFree: Float; var installMillis: Int64 }

    /// Storage, memory, and fallback install time derived stably from `deviceId`.
    static func traits(deviceId: String, referenceMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Traits {
        let h = Array(SHA256.hash(data: Data("medusa-device\u{0}\(deviceId)".utf8)))
        func pick(_ i: Int, _ n: UInt32) -> UInt32 {
            (UInt32(h[i * 4]) | UInt32(h[i * 4 + 1]) << 8 | UInt32(h[i * 4 + 2]) << 16 | UInt32(h[i * 4 + 3]) << 24) % n
        }
        let storage = [Float(106.83), 108.57, 229.36, 233.91, 487.62][Int(pick(0, 5))] + Float(pick(1, 400)) / 1000
        let memory = [Float(5.37), 7.42, 11.18, 15.07][Int(pick(2, 4))] + Float(pick(3, 90)) / 1000
        let day: Int64 = 86_400_000
        return Traits(
            storage: storage,
            storageFree: storage * (0.25 + Float(pick(5, 500)) / 1000),
            memory: memory,
            memoryFree: 0.35 + Float(pick(6, 900)) / 1000,
            installMillis: referenceMillis - day - Int64(pick(4, UInt32(20 * day)))
        )
    }

    /// Per-device field-24 JSON derived deterministically from `deviceId` (avoids sharing static
    /// captured hashes across installations).
    static func fingerprintJSON(deviceId: String) -> String {
        let h = Array(SHA256.hash(data: Data("medusa-fp-v1\u{0}\(deviceId)".utf8)))
        func u32(_ idx: Int) -> UInt32 {
            let o = (idx * 4) % (h.count - 4)
            return UInt32(h[o]) | (UInt32(h[o + 1]) << 8) | (UInt32(h[o + 2]) << 16) | (UInt32(h[o + 3]) << 24)
        }
        func u40(_ idx: Int) -> UInt64 {
            (UInt64(u32(idx)) << 8) | UInt64(h[(idx + 7) % h.count])
        }
        let unH = u32(0)
        let fkd = u32(1)
        let pd = u32(2)
        let lp = "2|\(500_000_000_000 + u40(3) % 400_000_000_000)|\(500_000_000_000 + u40(4) % 400_000_000_000)|\(1_800_000_000_000 + u40(5) % 800_000_000_000)|\(1_000_000_000 + UInt64(u32(6)) % 500_000_000)"
        let fl = "0|0|\(u32(7))|\(u32(0) ^ 0x5a5a5a5a)|\(u32(1) ^ 0xa5a5a5a5)|0|0|0|0|\(u32(2) ^ 0x3c3c3c3c)"
        return #"{"cmr":16777216,"cmr2":16777216,"un_h":\#(unH),"vpn":0,"sts":27,"kd":0,"fkd":\#(fkd),"pd":\#(pd),"lp":"\#(lp)","fl":"\#(fl)","dyn":"","do":0,"tk":true}"#
    }
}

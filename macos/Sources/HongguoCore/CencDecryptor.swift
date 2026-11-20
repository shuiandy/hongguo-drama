import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Decrypts the CENC (AES-128-CTR, full-sample) MP4 files served to the App, and derives the
/// key from `spade_a`. Port of `deriveKey` / `decryptMp4Buffer` in `hongguo.js`.
public enum CencDecryptor {
    // MARK: Key derivation

    /// FFmpeg-compatible base64 decode: stops at the first invalid character and keeps the
    /// bytes of a partial final group.
    static func avBase64Decode(_ s: String) -> [UInt8] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var table = [Int](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { table[Int(c)] = i }
        let chars = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i + 4 <= chars.count {
            var vals: [Int] = []
            var ok = true
            for j in 0..<4 {
                let v = table[Int(chars[i + j])]
                if v >= 0 { vals.append(v) } else { ok = false; break }
            }
            if !ok {
                var v = 0
                for x in vals { v = (v << 6) | x }
                if vals.count == 3 {
                    out.append(UInt8((v >> 10) & 0xff)); out.append(UInt8((v >> 2) & 0xff))
                } else if vals.count == 2 {
                    out.append(UInt8((v >> 4) & 0xff))
                }
                break
            }
            let v = (vals[0] << 18) | (vals[1] << 12) | (vals[2] << 6) | vals[3]
            out.append(UInt8((v >> 16) & 0xff)); out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8(v & 0xff))
            i += 4
        }
        return out
    }

    /// `spade_a` -> 16-byte AES key, or nil when the material is malformed.
    public static func deriveKey(_ spadeA: String) -> [UInt8]? {
        let buf = avBase64Decode(spadeA)
        let length = buf.count
        guard length >= 3 else { return nil }
        let key0 = Int(buf[0] ^ buf[1] ^ buf[2])
        let x27 = key0 - 0x30
        let w22 = length - key0 + 0x2f
        guard x27 >= 2, w22 >= 2, w22 <= length - 1 else { return nil }
        var x21 = Array(buf[1..<(1 + w22)])
        var w11 = 0x55, w12 = 0xfa
        let w10 = 0xeb
        for i in 0..<x21.count {
            let original = Int(x21[i])
            let pc = i.nonzeroBitCount
            let w14 = (i & 1) == 0 ? w12 : w11
            if (i & 1) == 1 { w11 = original } else { w12 = original }
            x21[i] = UInt8(truncatingIfNeeded: (w10 - pc) + (w14 ^ original))
        }
        let c0 = Int(x21[0])
        let hval: Int
        if (0x30...0x39).contains(c0) { hval = c0 - 0x30 }
        else if (0x61...0x7a).contains(c0) { hval = c0 - 0x57 }
        else { return nil }
        let w9 = w22 - hval
        guard w9 >= 2, w9 <= x21.count else { return nil }
        let hex = x21[1..<w9]
        guard hex.count == 32, let text = String(bytes: hex, encoding: .ascii) else { return nil }
        var key: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            key.append(byte)
            index = next
        }
        return key.count == 16 ? key : nil
    }

    // MARK: AES

    static func aesECBEncrypt(key: [UInt8], _ data: [UInt8]) throws -> [UInt8] {
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved == data.count else { throw HongguoError(.decrypt, "AES 运算失败") }
        return out
        #else
        throw HongguoError(.decrypt, "当前平台不支持 AES")
        #endif
    }

    /// CTR keystream XOR with counter blocks `nonce(8) || BE64(k)`, k from 0 per sample.
    public static func decryptSample(key: [UInt8], nonce: ArraySlice<UInt8>, cipher: ArraySlice<UInt8>) throws -> [UInt8] {
        if cipher.isEmpty { return [] }
        let blocks = (cipher.count + 15) / 16
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        let n = Array(nonce.prefix(8))
        for k in 0..<blocks {
            let base = k * 16
            for j in 0..<min(8, n.count) { counters[base + j] = n[j] }
            var value = UInt64(k).bigEndian
            withUnsafeBytes(of: &value) { raw in
                for j in 0..<8 { counters[base + 8 + j] = raw[j] }
            }
        }
        let stream = try aesECBEncrypt(key: key, counters)
        var plain = [UInt8](repeating: 0, count: cipher.count)
        var i = 0
        for byte in cipher {
            plain[i] = byte ^ stream[i]
            i += 1
        }
        return plain
    }

    // MARK: MP4 boxes

    struct Box {
        var type: String
        var offset: Int
        var size: Int
        var header: Int
        var children: [Box]?
    }

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta", "meta"]

    static func u32(_ d: [UInt8], _ o: Int) -> Int {
        Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
    }

    static func u64(_ d: [UInt8], _ o: Int) -> Int {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(d[o + i]) }
        return v > UInt64(Int.max) ? Int.max : Int(v)
    }

    static func put32(_ d: inout [UInt8], _ o: Int, _ v: Int) {
        d[o] = UInt8((v >> 24) & 0xff); d[o + 1] = UInt8((v >> 16) & 0xff)
        d[o + 2] = UInt8((v >> 8) & 0xff); d[o + 3] = UInt8(v & 0xff)
    }

    static func put64(_ d: inout [UInt8], _ o: Int, _ v: Int) {
        let u = UInt64(v)
        for i in 0..<8 { d[o + i] = UInt8((u >> (56 - 8 * UInt64(i))) & 0xff) }
    }

    static func fourCC(_ d: [UInt8], _ o: Int) -> String {
        String(bytes: d[o..<(o + 4)], encoding: .isoLatin1) ?? ""
    }

    static func parseBoxes(_ d: [UInt8], _ start: Int, _ end: Int) -> [Box] {
        var boxes: [Box] = []
        var off = start
        while off + 8 <= end {
            var size = u32(d, off)
            let type = fourCC(d, off + 4)
            var header = 8
            if size == 1 {
                guard off + 16 <= end else { break }
                size = u64(d, off + 8)
                header = 16
            } else if size == 0 {
                size = end - off
            }
            if size < header || off + size > end { break }
            let children = containers.contains(type) ? parseBoxes(d, off + header, off + size) : nil
            boxes.append(Box(type: type, offset: off, size: size, header: header, children: children))
            off += size
        }
        return boxes
    }

    static func walk(_ boxes: [Box]) -> [Box] {
        boxes.flatMap { box in (box.children.map(walk) ?? []) + [box] }
    }

    // MARK: Decrypt

    /// One encrypted sample: absolute file offset, size and 8-byte CTR nonce.
    public struct Sample: Sendable {
        public var offset: Int
        public var size: Int
        public var nonce: [UInt8]
    }

    /// Builds the sample table (offset, size, IV) for every track from the `stbl` boxes.
    /// Only the bytes of `moov` must be present in `d`; sample offsets may point past its end.
    static func sampleTable(_ d: [UInt8], _ top: [Box]) -> [Sample] {
        let total = d.count
        var samples: [Sample] = []
        for stbl in walk(top) where stbl.type == "stbl" {
            let kids = stbl.children ?? []
            guard let stsz = kids.first(where: { $0.type == "stsz" }),
                  let stco = kids.first(where: { $0.type == "stco" }),
                  let stsc = kids.first(where: { $0.type == "stsc" }) else { continue }
            let senc = kids.first(where: { $0.type == "senc" })

            let sampleSize = u32(d, stsz.offset + 12)
            let sampleCount = u32(d, stsz.offset + 16)
            guard stsz.offset + 20 + (sampleSize == 0 ? sampleCount * 4 : 0) <= total else { continue }
            let sizes: [Int] = sampleSize == 0
                ? (0..<sampleCount).map { u32(d, stsz.offset + 20 + $0 * 4) }
                : [Int](repeating: sampleSize, count: sampleCount)

            let chunkCount = u32(d, stco.offset + 12)
            guard stco.offset + 16 + chunkCount * 4 <= total else { continue }
            let chunkOffsets = (0..<chunkCount).map { u32(d, stco.offset + 16 + $0 * 4) }

            let stscCount = u32(d, stsc.offset + 12)
            guard stsc.offset + 16 + stscCount * 12 <= total else { continue }
            let stscTable = (0..<stscCount).map { i in
                (u32(d, stsc.offset + 16 + i * 12), u32(d, stsc.offset + 20 + i * 12))
            }

            var nonces: [[UInt8]] = []
            if let senc {
                let count = u32(d, senc.offset + 12)
                for i in 0..<count where senc.offset + 24 + i * 8 <= total {
                    nonces.append(Array(d[(senc.offset + 16 + i * 8)..<(senc.offset + 24 + i * 8)]))
                }
            }

            var samplesPerChunk = [Int](repeating: 1, count: chunkCount)
            for (i, row) in stscTable.enumerated() {
                let first = row.0
                let next = i + 1 < stscTable.count ? stscTable[i + 1].0 : chunkCount + 1
                if first >= 1 {
                    for ci in (first - 1)..<max(first - 1, next - 1) where ci < chunkCount { samplesPerChunk[ci] = row.1 }
                }
            }

            var sampleIndex = 0
            for ci in 0..<chunkCount {
                var off = chunkOffsets[ci]
                for _ in 0..<samplesPerChunk[ci] {
                    guard sampleIndex < sampleCount else { break }
                    let size = sizes[sampleIndex]
                    if sampleIndex < nonces.count {
                        samples.append(Sample(offset: off, size: size, nonce: nonces[sampleIndex]))
                    }
                    off += size
                    sampleIndex += 1
                }
            }
        }
        return samples
    }

    /// Decrypts a complete CENC MP4 and rewrites `moov` so players see clear avc1/hvc1/mp4a tracks.
    public static func decryptMP4(_ input: Data, key: [UInt8]) throws -> Data {
        var d = [UInt8](input)
        let total = d.count
        let top = parseBoxes(d, 0, total)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw HongguoError(.decrypt, "no moov box found in MP4") }

        for sample in sampleTable(d, top) where sample.offset + sample.size <= total {
            let range = sample.offset..<(sample.offset + sample.size)
            let plain = try decryptSample(key: key, nonce: sample.nonce[...], cipher: d[range])
            d.replaceSubrange(range, with: plain)
        }

        let newMoov = try rebuildMoov(&d, moov: moov)
        var out = Data(capacity: total)
        var off = 0
        while off + 8 <= total {
            var size = u32(d, off)
            let type = fourCC(d, off + 4)
            if size == 1 { size = u64(d, off + 8) } else if size == 0 { size = total - off }
            guard size >= 8, off + size <= total else { break }
            if type == "moov" { out.append(contentsOf: newMoov) } else { out.append(contentsOf: d[off..<(off + size)]) }
            off += size
        }
        return out
    }

    /// Drops encryption boxes, renames encv/enca sample entries and fixes `stco` offsets that
    /// point past `moov` (moov sits before mdat in these files and shrinks).
    static func rebuildMoov(_ d: inout [UInt8], moov: Box) throws -> [UInt8] {
        func prune(_ box: Box) -> Box {
            guard let children = box.children else { return box }
            var copy = box
            copy.children = children.filter { !["senc", "saio", "saiz", "sgpd", "sbgp"].contains($0.type) }.map(prune)
            return copy
        }
        let tree = prune(moov)
        let all = walk([tree])

        var patches: [Int: [UInt8]] = [:]
        for box in all where box.type == "stsd" {
            let content = box.offset + 8
            let count = u32(d, content + 4)
            var p = content + 8
            var entries: [[UInt8]] = []
            for _ in 0..<count {
                let entrySize = u32(d, p)
                let entryType = fourCC(d, p + 4)
                guard entrySize >= 8, p + entrySize <= box.offset + box.size else { throw HongguoError(.decrypt, "stsd 结构异常") }
                if entryType == "encv" || entryType == "enca" {
                    let headerSize = entryType == "encv" ? 78 : 28
                    let children = parseBoxes(d, p + 8 + headerSize, p + entrySize)
                    var newType = "mp4a"
                    if entryType == "encv" {
                        var original: String?
                        if let sinf = children.first(where: { $0.type == "sinf" }),
                           let frma = parseBoxes(d, sinf.offset + sinf.header, sinf.offset + sinf.size).first(where: { $0.type == "frma" }),
                           frma.size == frma.header + 4 {
                            original = fourCC(d, frma.offset + frma.header)
                        }
                        let avc = children.contains { $0.type == "avcC" }
                        let hevc = children.contains { $0.type == "hvcC" }
                        let guess: String? = original ?? (avc && !hevc ? "avc1" : hevc && !avc ? "hvc1" : nil)
                        guard let guess, ["avc1", "avc3", "hvc1", "hev1"].contains(guess),
                              guess.hasPrefix("avc") ? (avc && !hevc) : (hevc && !avc) else {
                            throw HongguoError(.decrypt, "无法确定加密视频的原始编码（codec），请更换片源重试。")
                        }
                        newType = guess
                    }
                    var entry = [UInt8](repeating: 0, count: 8)
                    entry.replaceSubrange(4..<8, with: Array(newType.utf8))
                    entry.append(contentsOf: d[(p + 8)..<(p + 8 + headerSize)])
                    for child in children where child.type != "sinf" {
                        entry.append(contentsOf: d[child.offset..<(child.offset + child.size)])
                    }
                    put32(&entry, 0, entry.count)
                    entries.append(entry)
                } else {
                    entries.append(Array(d[p..<(p + entrySize)]))
                }
                p += entrySize
            }
            var stsd = Array(d[box.offset..<(content + 8)])
            put32(&stsd, 12, entries.count)
            for entry in entries { stsd.append(contentsOf: entry) }
            put32(&stsd, 0, stsd.count)
            patches[box.offset] = stsd
        }

        func serialize(_ box: Box) -> [UInt8] {
            guard let children = box.children else {
                return patches[box.offset] ?? Array(d[box.offset..<(box.offset + box.size)])
            }
            var body: [UInt8] = []
            for child in children { body.append(contentsOf: serialize(child)) }
            var header = Array(d[box.offset..<(box.offset + box.header)])
            if box.header == 8 {
                put32(&header, 0, 8 + body.count)
            } else {
                put32(&header, 0, 1)
                put64(&header, 8, 16 + body.count)
            }
            return header + body
        }

        let first = serialize(tree)
        let delta = moov.size - first.count
        for box in all where box.type == "stco" {
            let count = u32(d, box.offset + 12)
            for i in 0..<count {
                let at = box.offset + 16 + i * 4
                let value = u32(d, at)
                if value >= moov.offset + moov.size { put32(&d, at, value - delta) }
            }
        }
        return serialize(tree)
    }
}

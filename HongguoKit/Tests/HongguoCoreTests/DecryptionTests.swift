import XCTest
@testable import HongguoCore

final class DecryptionTests: XCTestCase {
    /// Vectors produced with the Electron implementation (`deriveKey` in src/native/hongguo.js).
    func testDeriveKeyMatchesElectronImplementation() {
        let vectors = [
            ("nLIa+FO/K8Z7vQHtS5cD7X6UNexOlQfffKM26kugMepKoxXDdwswVXo=", "9421ab8ec92c0bdc4acb12be21d2a1a3"),
            ("qIwT9lyKFvdfvxX0b6Qn61uSENlBog7cdJQ87m2/PcRAgx/jfYEZ5H6CFusLMFV6n8Tp", "0d8f3f1234b907cc449d7fa10b897bc1"),
            ("oL8t92S/HsRVjC71YL0x8mO6L/VjvhruYakq12StK+NkpQsw", "b222cd32db6197925844a8b03f5b6550"),
            ("moEizViDEMlfsxH0XLMl/WyEIf5thhT8WIEQy22bP9FwqS/JTaspzk6oJsFNqiDEUAswVXqfxOkOMw==", "a6c8137d7050a60c6c4aab3f02d8915b"),
        ]
        for (spadeA, expected) in vectors {
            XCTAssertEqual(CencDecryptor.deriveKey(spadeA).map(hex), expected, spadeA)
        }
    }

    func testDeriveKeyRejectsGarbage() {
        XCTAssertNil(CencDecryptor.deriveKey(""))
        XCTAssertNil(CencDecryptor.deriveKey("AAAA"))
        XCTAssertNil(CencDecryptor.deriveKey("not base64 at all!!"))
    }

    /// Node `aes-128-ctr` with IV = nonce || 0.
    func testSampleDecryptMatchesAESCTR() throws {
        let key = bytes("9421ab8ec92c0bdc4acb12be21d2a1a3")
        let nonce = bytes("2bf3cd558de4bd6c")
        let plain = bytes("3dc1899ee4ff72a332d3c669faba911be3b0bde1646ca27fada1f824c82a89321b010e11eb")
        let cipher = bytes("ced93695293400fdb95e813081e4082348b9745143a7bbc89b136de04140d87b3402967bf4")
        XCTAssertEqual(try CencDecryptor.decryptSample(key: key, nonce: nonce[...], cipher: cipher[...]), plain)
    }

    func testDecryptsSyntheticCencMP4() throws {
        let key = bytes("0d8f3f1234b907cc449d7fa10b897bc1")
        let samples: [[UInt8]] = [Array("hello".utf8), Array("a second, longer sample!".utf8)]
        let ivs: [[UInt8]] = [bytes("0102030405060708"), bytes("1112131415161718")]
        let encrypted = try zip(samples, ivs).map { try CencDecryptor.decryptSample(key: key, nonce: $1[...], cipher: $0[...]) }

        func build(chunkOffset: Int) -> [UInt8] {
            let avcC = box("avcC", [1, 2, 3, 4])
            let sinf = box("sinf", box("frma", Array("avc1".utf8)) + full("schm", Array("cenc".utf8) + [0, 1, 0, 0]))
            let encv = box("encv", [UInt8](repeating: 0, count: 78) + avcC + sinf)
            let stsd = full("stsd", be32(1) + encv)
            let stsz = full("stsz", be32(0) + be32(samples.count) + samples.flatMap { be32($0.count) })
            let stsc = full("stsc", be32(1) + be32(1) + be32(samples.count) + be32(1))
            let stco = full("stco", be32(1) + be32(chunkOffset))
            let senc = full("senc", be32(ivs.count) + ivs.flatMap { $0 })
            let stbl = box("stbl", stsd + stsz + stsc + stco + senc)
            return box("moov", box("trak", box("mdia", box("minf", stbl))))
        }
        let ftyp = box("ftyp", Array("isom".utf8) + be32(0x200))
        let moovSize = build(chunkOffset: 0).count
        let moov = build(chunkOffset: ftyp.count + moovSize + 8)
        let mdat = box("mdat", encrypted.flatMap { $0 })
        let file = Data(ftyp + moov + mdat)

        let output = [UInt8](try CencDecryptor.decryptMP4(file, key: key))
        let top = CencDecryptor.parseBoxes(output, 0, output.count)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov", "mdat"])
        let all = CencDecryptor.walk(top)
        XCTAssertFalse(all.contains { $0.type == "senc" }, "encryption boxes must be removed")
        let stsd = try XCTUnwrap(all.first { $0.type == "stsd" })
        XCTAssertEqual(CencDecryptor.fourCC(output, stsd.offset + 16 + 4), "avc1")
        XCTAssertFalse(String(decoding: output[stsd.offset..<(stsd.offset + stsd.size)], as: UTF8.self).contains("sinf"))
        let stco = try XCTUnwrap(all.first { $0.type == "stco" })
        let offset = CencDecryptor.u32(output, stco.offset + 16)
        let mdatBox = try XCTUnwrap(top.first { $0.type == "mdat" })
        XCTAssertEqual(offset, mdatBox.offset + 8, "chunk offset must follow the shrunken moov")
        XCTAssertEqual(Array(output[offset..<(offset + samples[0].count + samples[1].count)]), samples.flatMap { $0 })
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func bytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

func be32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(payload.count + 8) + Array(type.utf8) + payload }
func full(_ type: String, _ payload: [UInt8]) -> [UInt8] { box(type, [0, 0, 0, 0] + payload) }

import XCTest
@testable import HongguoCore

/// Progressive decryption must produce exactly the bytes of the eager `decryptMP4` path,
/// for any byte range the player may ask for.
final class CencStreamTests: XCTestCase {
    private let key = bytes("0d8f3f1234b907cc449d7fa10b897bc1")

    /// ftyp + encrypted moov (one track, CENC) + mdat holding `samples` encrypted with `ivs`.
    private func makeFile(samples: [[UInt8]], ivs: [[UInt8]]) throws -> [UInt8] {
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
        return ftyp + moov + box("mdat", encrypted.flatMap { $0 })
    }

    private func sampleData() -> ([[UInt8]], [[UInt8]]) {
        var rng = SystemRandomNumberGenerator()
        let sizes = [5, 100, 37, 250, 16, 1]
        let samples = sizes.map { n in (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) } }
        let ivs = sizes.indices.map { i in (0..<8).map { UInt8(($0 * 31 + i * 7) & 0xff) } }
        return (samples, ivs)
    }

    func testHeaderStatus() throws {
        let (samples, ivs) = sampleData()
        let file = try makeFile(samples: samples, ivs: ivs)
        let total = Int64(file.count)
        let top = CencDecryptor.parseBoxes(file, 0, file.count)
        let moov = try XCTUnwrap(top.first { $0.type == "moov" })
        let moovEnd = moov.offset + moov.size
        XCTAssertEqual(CencStreamMap.headerStatus(Array(file[0..<4]), totalLength: total), .needMore(16))
        XCTAssertEqual(CencStreamMap.headerStatus(Array(file[0..<(moov.offset + 8)]), totalLength: total), .complete(moovEnd))
        XCTAssertEqual(CencStreamMap.headerStatus(file, totalLength: total), .complete(moovEnd))
        if case .needMore(let n) = CencStreamMap.headerStatus(Array(file[0..<(moov.offset + 3)]), totalLength: total) {
            XCTAssertGreaterThan(n, moov.offset + 3)
        } else {
            XCTFail("expected needMore")
        }
        // mdat before moov cannot be streamed.
        let ftyp = Array(file[0..<moov.offset])
        let reordered = ftyp + box("mdat", [1, 2, 3]) + Array(file[moov.offset..<moovEnd])
        XCTAssertEqual(CencStreamMap.headerStatus(reordered, totalLength: Int64(reordered.count)), .unsupported)
        // A box claiming more bytes than the file has is rejected.
        XCTAssertEqual(CencStreamMap.headerStatus(Array(file[0..<moovEnd]), totalLength: Int64(moov.offset + 10)), .unsupported)
    }

    func testStreamedRangesMatchEagerDecryption() throws {
        let (samples, ivs) = sampleData()
        let file = try makeFile(samples: samples, ivs: ivs)
        let eager = [UInt8](try CencDecryptor.decryptMP4(Data(file), key: key))

        guard case .complete(let moovEnd) = CencStreamMap.headerStatus(file, totalLength: Int64(file.count)) else {
            return XCTFail("header not found")
        }
        let map = try CencStreamMap(input: Array(file[0..<moovEnd]), inputLength: Int64(file.count), key: key)
        XCTAssertEqual(map.outputLength, Int64(eager.count))
        XCTAssertEqual(map.header, Array(eager[0..<map.header.count]))

        /// What the resource loader serves for output bytes `lo ..< hi`.
        func serve(_ lo: Int, _ hi: Int) throws -> [UInt8] {
            var out: [UInt8] = []
            var offset = lo
            if offset < map.header.count {
                let upper = min(hi, map.header.count)
                out += map.header[offset..<upper]
                offset = upper
            }
            if offset < hi {
                let inStart = Int(map.inputOffset(forOutput: Int64(offset)))
                let inEnd = Int(map.inputOffset(forOutput: Int64(hi)))
                var chunk = Array(file[inStart..<inEnd])
                // Feed in uneven network-sized pieces, as URLSession does.
                var cursor = inStart
                var decrypted: [UInt8] = []
                var pieces = chunk[...]
                var step = 1
                while !pieces.isEmpty {
                    var piece = Array(pieces.prefix(step))
                    pieces = pieces.dropFirst(piece.count)
                    try map.decrypt(&piece, atInputOffset: Int64(cursor))
                    cursor += piece.count
                    decrypted += piece
                    step = step * 3 % 41 + 1
                }
                chunk = decrypted
                out += chunk
            }
            return out
        }

        XCTAssertEqual(try serve(0, eager.count), eager, "whole file")
        for _ in 0..<300 {
            let a = Int.random(in: 0..<eager.count)
            let b = Int.random(in: a...eager.count)
            XCTAssertEqual(try serve(a, b), Array(eager[a..<b]), "range \(a)..<\(b)")
        }
    }

    func testRejectsSamplesInsideHeader() throws {
        let (samples, ivs) = sampleData()
        let file = try makeFile(samples: samples, ivs: ivs)
        guard case .complete(let moovEnd) = CencStreamMap.headerStatus(file, totalLength: Int64(file.count)) else {
            return XCTFail("header not found")
        }
        XCTAssertThrowsError(try CencStreamMap(input: Array(file[0..<moovEnd]), inputLength: Int64(file.count), key: [1, 2, 3]))
        XCTAssertThrowsError(try CencStreamMap(input: Array(file[0..<(moovEnd - 1)]), inputLength: Int64(file.count), key: key))
    }
}

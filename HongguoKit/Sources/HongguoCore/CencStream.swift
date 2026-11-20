import Foundation

/// Progressive ("decrypt while downloading") playback of CENC MP4 files whose `moov` precedes
/// `mdat`. The player sees a virtual clear file:
///
///     output = input[0 ..< moov.offset] + rebuiltMoov + input[moovEnd ...]
///
/// Bytes before `headerLength` come from memory; any later byte range maps to the input range
/// shifted by `delta` and is decrypted in place. AES-CTR keystream is position addressable, so
/// arbitrary ranges (seeks) can be decrypted without the rest of the sample.
public struct CencStreamMap: Sendable {
    /// Clear header served for output bytes `0 ..< header.count`.
    public let header: [UInt8]
    /// Input byte where the media after `moov` starts.
    public let inputHeaderLength: Int
    /// `inputOffset = outputOffset + delta` for output offsets at or after `header.count`.
    public let delta: Int
    public let inputLength: Int64
    public var outputLength: Int64 { inputLength - Int64(delta) }
    let samples: [CencDecryptor.Sample]
    let key: [UInt8]

    public enum HeaderStatus: Equatable {
        /// `moov` ends at this input offset; fetch exactly that many bytes.
        case complete(Int)
        /// Need at least this many bytes to see the next box header.
        case needMore(Int)
        /// `mdat` comes before `moov` (or the structure is unusable): download the whole file instead.
        case unsupported
    }

    /// Walks top-level boxes of a file prefix to find where `moov` ends.
    public static func headerStatus(_ prefix: [UInt8], totalLength: Int64) -> HeaderStatus {
        var off = 0
        while true {
            guard off + 8 <= prefix.count else { return .needMore(off + 16) }
            var size = CencDecryptor.u32(prefix, off)
            let type = CencDecryptor.fourCC(prefix, off + 4)
            if size == 1 {
                guard off + 16 <= prefix.count else { return .needMore(off + 16) }
                size = CencDecryptor.u64(prefix, off + 8)
            } else if size == 0 {
                return .unsupported
            }
            guard size >= 8, Int64(off) + Int64(size) <= totalLength else { return .unsupported }
            if type == "moov" { return .complete(off + size) }
            if type == "mdat" || type == "moof" { return .unsupported }
            off += size
        }
    }

    /// `input` must hold exactly the bytes `0 ..< moovEnd` of the encrypted file.
    public init(input: [UInt8], inputLength: Int64, key: [UInt8]) throws {
        guard key.count == 16 else { throw HongguoError(.decrypt, "片源密钥长度异常") }
        var d = input
        let top = CencDecryptor.parseBoxes(d, 0, d.count)
        guard let moov = top.first(where: { $0.type == "moov" }), moov.offset + moov.size == d.count else {
            throw HongguoError(.decrypt, "片源头部结构异常")
        }
        let samples = CencDecryptor.sampleTable(d, top).sorted { $0.offset < $1.offset }
        guard let first = samples.first, first.offset >= d.count else {
            // Samples inside the header would need the eager path.
            throw HongguoError(.decrypt, "片源样本位于头部之前，无法流式解密")
        }
        let newMoov = try CencDecryptor.rebuildMoov(&d, moov: moov)
        header = Array(d[0..<moov.offset]) + newMoov
        inputHeaderLength = d.count
        delta = d.count - header.count
        self.inputLength = inputLength
        self.samples = samples
        self.key = key
    }

    public func inputOffset(forOutput offset: Int64) -> Int64 { offset + Int64(delta) }

    /// Decrypts `data`, which holds input bytes starting at absolute `inputOffset`, in place.
    public func decrypt(_ data: inout [UInt8], atInputOffset inputOffset: Int64) throws {
        guard !data.isEmpty else { return }
        let start = Int(inputOffset)
        let end = start + data.count
        // First sample whose end is past `start`.
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].offset + samples[mid].size <= start { lo = mid + 1 } else { hi = mid }
        }
        var index = lo
        while index < samples.count, samples[index].offset < end {
            let sample = samples[index]
            let overlapStart = max(start, sample.offset)
            let overlapEnd = min(end, sample.offset + sample.size)
            if overlapStart < overlapEnd {
                let relative = overlapStart - sample.offset
                let firstBlock = relative / 16
                let lastBlock = (overlapEnd - sample.offset - 1) / 16
                let stream = try CencDecryptor.keystream(key: key, nonce: sample.nonce, firstBlock: firstBlock,
                                                         count: lastBlock - firstBlock + 1)
                var k = relative - firstBlock * 16
                for i in (overlapStart - start)..<(overlapEnd - start) {
                    data[i] ^= stream[k]
                    k += 1
                }
            }
            index += 1
        }
    }
}

extension CencDecryptor {
    /// AES-CTR keystream blocks `nonce(8) || BE64(firstBlock + i)`.
    static func keystream(key: [UInt8], nonce: [UInt8], firstBlock: Int, count: Int) throws -> [UInt8] {
        var counters = [UInt8](repeating: 0, count: count * 16)
        for i in 0..<count {
            let base = i * 16
            for j in 0..<min(8, nonce.count) { counters[base + j] = nonce[j] }
            var value = UInt64(firstBlock + i).bigEndian
            withUnsafeBytes(of: &value) { raw in
                for j in 0..<8 { counters[base + 8 + j] = raw[j] }
            }
        }
        return try aesECBEncrypt(key: key, counters)
    }
}

/// Fetches the header of an encrypted episode with ranged requests and builds a `CencStreamMap`.
public enum CencStreamLoader {
    public static func open(_ info: PlayInfo, http: HTTPClient = .shared, maxHeaderBytes: Int = 16 * 1024 * 1024) async throws -> CencStreamMap {
        guard let key = info.contentKey ?? info.spadeA.flatMap(CencDecryptor.deriveKey) else {
            throw HongguoError(.decrypt, "片源密钥无法解析")
        }
        var prefix: [UInt8] = []
        var total: Int64 = 0
        var want = 64 * 1024
        while true {
            if want > maxHeaderBytes { throw HongguoError(.unavailable, "片源头部过大，改用整集解密") }
            if want > prefix.count {
                let (bytes, length) = try await fetch(info, from: prefix.count, to: want - 1, http: http)
                prefix += bytes
                total = length
                if bytes.isEmpty { throw HongguoError(.unavailable, "片源头部不完整") }
            }
            switch CencStreamMap.headerStatus(prefix, totalLength: total) {
            case .complete(let end):
                if prefix.count >= end {
                    return try CencStreamMap(input: Array(prefix[0..<end]), inputLength: total, key: key)
                }
                want = end
            case .needMore(let n):
                want = max(n, prefix.count + 64 * 1024)
            case .unsupported:
                throw HongguoError(.unavailable, "片源不支持边下边播，改用整集解密")
            }
        }
    }

    /// GET `bytes=from-to`; returns the bytes and the full resource length from Content-Range.
    static func fetch(_ info: PlayInfo, from: Int, to: Int, http: HTTPClient) async throws -> ([UInt8], Int64) {
        var options = HTTPClient.Options()
        options.headers = info.httpHeaders.merging(["Range": "bytes=\(from)-\(to)"]) { $1 }
        options.timeout = 20
        options.maxBytes = to - from + 1 + 1024
        let response = try await http.get(info.url, options: options)
        guard response.status == 206,
              let range = response.header("Content-Range"),
              let totalText = range.split(separator: "/").last, let total = Int64(totalText),
              range.hasPrefix("bytes \(from)-") else {
            throw HongguoError(.unavailable, "片源服务器不支持分段请求，改用整集解密")
        }
        return ([UInt8](response.data), total)
    }
}

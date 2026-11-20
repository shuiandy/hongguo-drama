import Foundation
import HongguoPlayback
import XCTest

final class LocalCastServerTests: XCTestCase {
    func testServesFileWithHeadGetAndByteRange() async throws {
        let server = LocalCastServer()
        defer { Task { await server.stop() } }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cast-test-\(UUID().uuidString).mp4")
        let payload = Data((0..<1024).map { UInt8($0 % 251) })
        try payload.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let url = try await server.publish(.file(url: tempURL, size: Int64(payload.count)), useLoopbackForTesting: true)

        // 1. HEAD
        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        let (headData, headResp) = try await URLSession.shared.data(for: headReq)
        let headHTTP = try XCTUnwrap(headResp as? HTTPURLResponse)
        XCTAssertEqual(headHTTP.statusCode, 200)
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Content-Length"), "1024")
        XCTAssertTrue(headData.isEmpty)

        // 2. Range 206 Partial Content
        var rangeReq = URLRequest(url: url)
        rangeReq.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (rangeData, rangeResp) = try await URLSession.shared.data(for: rangeReq)
        let rangeHTTP = try XCTUnwrap(rangeResp as? HTTPURLResponse)
        XCTAssertEqual(rangeHTTP.statusCode, 206)
        XCTAssertEqual(rangeHTTP.value(forHTTPHeaderField: "Content-Range"), "bytes 100-199/1024")
        XCTAssertEqual(rangeData, payload[100..<200])

        // 3. Invalid token returns 404
        let badURL = url.deletingLastPathComponent().appendingPathComponent("invalid.mp4")
        let (_, badResp) = try await URLSession.shared.data(from: badURL)
        XCTAssertEqual((badResp as? HTTPURLResponse)?.statusCode, 404)
    }
}

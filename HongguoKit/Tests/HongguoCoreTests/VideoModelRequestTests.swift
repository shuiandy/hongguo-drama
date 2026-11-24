// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

final class VideoModelRequestTests: XCTestCase {
    private let identity = PlaybackIdentity(deviceId: "1234567890123456789", iid: "9876543210987654321", cdid: "abcd-ef")

    func testRequestShapeAndHeaders() throws {
        let req = try VideoModelRequest.request(
            vid: "7694243705045126169",
            identity: identity,
            openudid: "00ff",
            guest: ["ttreq": "1$abc", "store-region": "cn-gd", "store-region-src": "did"],
            dToken: "dt_real_token_123",
            installMillis: 1_795_000_000_000,
            nowMillis: 1_795_543_000_000
        )
        XCTAssertTrue(req.url.hasPrefix("https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/?iid=9876543210987654321&device_id="))
        let query = String(req.url.split(separator: "?", maxSplits: 1)[1])
        let keys = query.split(separator: "&").map { String($0.split(separator: "=")[0]) }
        XCTAssertEqual(keys.suffix(3), ["openudid", "ts", "_rticket"])
        XCTAssertEqual(AppCrypto.queryParam(query, "version_name"), "7.3.9.32")
        XCTAssertEqual(AppCrypto.queryParam(query, "device_platform"), "android")
        let headers = Dictionary(req.headers, uniquingKeysWith: { a, _ in a })
        for name in ["x-gorgon", "x-helios", "x-medusa", "x-khronos", "x-ss-stub"] {
            XCTAssertFalse(headers[name, default: ""].isEmpty, name)
        }
        XCTAssertNil(headers["x-argus"], "legacy 551 x-argus must not be sent")
        XCTAssertNil(headers["x-ladon"], "legacy 551 x-ladon must not be sent")
        XCTAssertEqual(headers["x-tt-dt"], "dt_real_token_123")
        XCTAssertEqual(headers["x-ss-stub"], AppCrypto.hex(AppCrypto.md5(req.body)).uppercased())
        XCTAssertEqual(headers["x-khronos"], AppCrypto.queryParam(query, "ts"))
        XCTAssertEqual(headers["x-ss-req-ticket"], AppCrypto.queryParam(query, "_rticket"))
        XCTAssertEqual(String(headers["x-gorgon"]!.dropFirst(8).prefix(4)), "0405")
        XCTAssertEqual(headers["Cookie"], "passport_csrf_token=; passport_csrf_token_default=; store-region=cn-gd; store-region-src=did; install_id=9876543210987654321; ttreq=1$abc")
        XCTAssertEqual(req.body.first, UInt8(ascii: "{"))
        XCTAssertNil(headers["Content-Encoding"])
        let body = try JSONValue.parse(Data(req.body))
        XCTAssertEqual(body["video_id"].string, "7694243705045126169")
        XCTAssertEqual(body["biz_param"]["device_level"].signedInt, 1)
        XCTAssertEqual(body["biz_param"]["video_platform"].signedInt, 3)
    }

    func testNoCookieWithoutTicketAndRejectsInvalidVid() throws {
        let req = try VideoModelRequest.request(vid: "7694243705045126169", identity: identity, openudid: "", guest: nil)
        XCTAssertFalse(req.headers.contains { $0.0 == "Cookie" })
        XCTAssertNil(VideoModelRequest.cookie(iid: "1", guest: ["store-region": "cn"]))
        XCTAssertThrowsError(try VideoModelRequest.payload(vid: "12\"}"))
    }

    func testGuestCookiesFromFoldedHeader() {
        let header = "store-region=cn-gd; Path=/; Domain=fqnovel.com; Max-Age=31536000, store-region-src=did; Path=/, "
            + "ttreq=1$0b2a9e; Path=/; Domain=fqnovel.com, install_id=7; Path=/"
        XCTAssertEqual(PersistentAppDevice.guestCookies(fromSetCookie: header),
                       ["store-region": "cn-gd", "store-region-src": "did", "ttreq": "1$0b2a9e"])
        XCTAssertEqual(PersistentAppDevice.guestCookies(fromSetCookie: ""), [:])
    }

    func testGorgonKeepsLegacyVector() {
        let legacy = AppLegacySigner.xGorgon(query: "a=1", body: nil, ts: 1_700_000_000, random: 0x1234)
        let explicit = AppLegacySigner.xGorgon(query: "a=1", body: nil, ts: 1_700_000_000, random: 0x1234,
                                               flags: (0x40, 0x01), sdkCode: 67503104)
        XCTAssertEqual(legacy, explicit)
        XCTAssertTrue(legacy.hasPrefix("840434124001"))
    }

    func testDeviceTraitsAndFingerprintArePerDeviceAndDeterministic() throws {
        let ref: Int64 = 1_800_000_000_000
        let a = MedusaProcess.traits(deviceId: "1234567890123456789", referenceMillis: ref)
        let a2 = MedusaProcess.traits(deviceId: "1234567890123456789", referenceMillis: ref)
        let b = MedusaProcess.traits(deviceId: "1234567890123456780", referenceMillis: ref)
        XCTAssertEqual(a, a2)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue((100...500).contains(a.storage))
        XCTAssertLessThan(a.storageFree, a.storage)
        XCTAssertLessThan(a.installMillis, ref)

        let fpA = MedusaProcess.fingerprintJSON(deviceId: "1234567890123456789")
        let fpB = MedusaProcess.fingerprintJSON(deviceId: "1234567890123456780")
        XCTAssertEqual(fpA, MedusaProcess.fingerprintJSON(deviceId: "1234567890123456789"))
        XCTAssertNotEqual(fpA, fpB)
        let parsed = try JSONValue.parse(Data(fpA.utf8))
        XCTAssertEqual(parsed["cmr"].signedInt, 16777216)
        XCTAssertEqual(parsed["sts"].signedInt, 27)
        XCTAssertEqual(parsed["tk"].bool, true)
        XCTAssertFalse((parsed["lp"].string ?? "").isEmpty)
        XCTAssertFalse((parsed["fl"].string ?? "").isEmpty)
    }
}

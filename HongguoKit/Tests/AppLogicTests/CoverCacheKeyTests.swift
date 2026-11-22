import AppLogic
import XCTest

final class CoverCacheKeyTests: XCTestCase {
    func testRotatingSignatureParametersShareSameKey() {
        let urlA = "https://p3-reading-sign.fqnovelpic.com/novel-pic/899ba52ee34a534d9be948a093468ed1~tplv-81nmtwyey9-superreso-aifit:400:0.heic?lk3s=64477e16&x-expires=1800232737&x-signature=AAA"
        let urlB = "https://p3-reading-sign.fqnovelpic.com/novel-pic/899ba52ee34a534d9be948a093468ed1~tplv-81nmtwyey9-superreso-aifit:400:0.heic?lk3s=64477e16&x-expires=1800999999&x-signature=BBB"
        XCTAssertEqual(CoverCacheKey.normalizedKey(for: urlA), CoverCacheKey.normalizedKey(for: urlB))
        XCTAssertEqual(CoverCacheKey.diskFilename(for: urlA), CoverCacheKey.diskFilename(for: urlB))
    }

    func testDifferentCDNEdgeSubdomainsShareSameKey() {
        let p3 = "https://p3-reading-sign.fqnovelpic.com/novel-pic/3edbd9c6ab15ebff3fd0853ec74a4f27~tplv-shrink:400:0.heic?x-signature=1"
        let p6 = "https://p6-reading-sign.fqnovelpic.com/novel-pic/3edbd9c6ab15ebff3fd0853ec74a4f27~tplv-shrink:400:0.heic?x-signature=2"
        XCTAssertEqual(CoverCacheKey.normalizedKey(for: p3), CoverCacheKey.normalizedKey(for: p6))
    }

    func testDifferentCoversProduceDifferentKeys() {
        let a = "https://p3-reading-sign.fqnovelpic.com/novel-pic/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~tplv-shrink:400:0.heic"
        let b = "https://p3-reading-sign.fqnovelpic.com/novel-pic/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb~tplv-shrink:400:0.heic"
        XCTAssertNotEqual(CoverCacheKey.normalizedKey(for: a), CoverCacheKey.normalizedKey(for: b))
        XCTAssertNotEqual(CoverCacheKey.diskFilename(for: a), CoverCacheKey.diskFilename(for: b))
    }

    func testResourceAndTransformSurviveRotatingSignatures() {
        let base = "https://p3-reading-sign.fqnovelpic.com/cover?id=101&width=100&x-signature=a"
        for changed in [base.replacingOccurrences(of: "101", with: "202"),
                        base.replacingOccurrences(of: "width=100", with: "width=200")] {
            XCTAssertNotEqual(CoverCacheKey.diskFilename(for: base), CoverCacheKey.diskFilename(for: changed))
        }
        let unknownHost = "https://example.com/cover?id=101&expires=1"
        XCTAssertNotEqual(CoverCacheKey.normalizedKey(for: unknownHost),
                          CoverCacheKey.normalizedKey(for: unknownHost.replacingOccurrences(of: "101", with: "202")))
    }

    func testGenericURLPreservesMeaningfulQuery() {
        let a = "https://example.com/img?id=1"
        let b = "https://example.com/img?id=2"
        XCTAssertNotEqual(CoverCacheKey.normalizedKey(for: a), CoverCacheKey.normalizedKey(for: b))
    }
}

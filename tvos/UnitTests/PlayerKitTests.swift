import XCTest
import HongguoPlayerKit

// The shared player as the tvOS app gets it (no hooks), on the Apple TV simulator.

@MainActor
final class PlayerKitTests: XCTestCase {
    /// Without hooks (the tvOS app) there is no little window and no casting, whatever the
    /// device or the audio route would allow.
    func testNoHooksMeansNoLittleWindowAndNoCasting() async {
        let engine = PlayerEngine()
        XCTAssertFalse(engine.supportsPictureInPicture)
        XCTAssertNil(engine.hooks.localFiles)
        XCTAssertNil(engine.hooks.convertedStreams)
        do {
            _ = try await engine.prepareForAirPlay()
            XCTFail("casting without the hook")
        } catch {
            // Matched by text: this test bundle links its own copy of the package's modules.
            XCTAssertTrue(String(describing: error).contains("当前设备不支持局域网投屏"), "\(error)")
        }
    }

    /// The emoticon pictures are a resource of this package now (Bundle.module).
    func testEmoticonsLoadFromThePackage() {
        let catalog = EmoticonCatalog.shared
        XCTAssertFalse(catalog.pickerItems.isEmpty)
        XCTAssertFalse(catalog.knownTokens.isEmpty)
        let first = catalog.pickerItems[0]
        XCTAssertNotNil(catalog.pickerIcon(filename: first.filename))
    }

    func testCountText() {
        XCTAssertEqual(CountText.short(9_800), "9800")
        XCTAssertEqual(CountText.short(146_000), "14.6万")
        XCTAssertEqual(CountText.short(44_940_000), "4494万")
        XCTAssertEqual(CountText.short(250_000_000), "2.5亿")
    }
}

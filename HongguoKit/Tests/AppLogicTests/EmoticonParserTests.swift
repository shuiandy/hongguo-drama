import AppLogic
import XCTest

final class EmoticonParserTests: XCTestCase {
    private let map: [String: String] = [
        "[笑哭]": "emoji_dr_20.webp",
        "[捂脸]": "emoji_dr_25.webp",
        "[OK]": "emoji_dr_31.webp",
    ]

    func testPlainTextWithoutBracketsPassesThrough() {
        XCTAssertEqual(EmoticonParser.parse("好看爱看", mapping: map), [.text("好看爱看")])
    }

    func testParsesMixedTextAndMultipleEmoticons() {
        let out = EmoticonParser.parse("懂你意思[捂脸][笑哭] × 2", mapping: map)
        XCTAssertEqual(out, [
            .text("懂你意思"),
            .emoticon(token: "[捂脸]", filename: "emoji_dr_25.webp"),
            .emoticon(token: "[笑哭]", filename: "emoji_dr_20.webp"),
            .text(" × 2"),
        ])
    }

    func testUnknownBracketStaysPlainText() {
        let out = EmoticonParser.parse("哈哈[不存在]好笑[笑哭]", mapping: map)
        XCTAssertEqual(out, [
            .text("哈哈[不存在]好笑"),
            .emoticon(token: "[笑哭]", filename: "emoji_dr_20.webp"),
        ])
    }

    func testNestedOpenBracketRecoversInnerToken() {
        let out = EmoticonParser.parse("前面[未闭合[捂脸]后面", mapping: map)
        XCTAssertEqual(out, [
            .text("前面[未闭合"),
            .emoticon(token: "[捂脸]", filename: "emoji_dr_25.webp"),
            .text("后面"),
        ])
    }

    func testCaseInsensitiveASCIITokenMatches() {
        let out = EmoticonParser.parse("好的[ok]!", mapping: map)
        XCTAssertEqual(out, [
            .text("好的"),
            .emoticon(token: "[ok]", filename: "emoji_dr_31.webp"),
            .text("!"),
        ])
    }
}

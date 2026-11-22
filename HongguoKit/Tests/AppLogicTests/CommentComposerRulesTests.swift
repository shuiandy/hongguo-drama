import AppLogic
import XCTest

final class CommentComposerRulesTests: XCTestCase {
    private let tokens: Set<String> = ["[微笑]", "[笑哭]", "[捂脸]", "[OK]", "[KISS]"]

    func testCanSubmitRequiresNonBlankEpisodeAndLengthLimit() {
        XCTAssertFalse(CommentComposerRules.canSubmit("", isSubmitting: false, hasEpisode: true))
        XCTAssertFalse(CommentComposerRules.canSubmit("   \n\t ", isSubmitting: false, hasEpisode: true))
        XCTAssertFalse(CommentComposerRules.canSubmit("好看", isSubmitting: true, hasEpisode: true))
        XCTAssertFalse(CommentComposerRules.canSubmit("好看", isSubmitting: false, hasEpisode: false))
        XCTAssertTrue(CommentComposerRules.canSubmit(" 好看[微笑] ", isSubmitting: false, hasEpisode: true))

        let tooLong = String(repeating: "好", count: CommentComposerRules.maxLength + 1)
        XCTAssertFalse(CommentComposerRules.canSubmit(tooLong, isSubmitting: false, hasEpisode: true))
        // Image-only comments are valid, while over-limit text still blocks submission.
        XCTAssertTrue(CommentComposerRules.canSubmit("", hasImage: true, isSubmitting: false, hasEpisode: true))
        XCTAssertTrue(CommentComposerRules.canSubmit("   ", hasImage: true, isSubmitting: false, hasEpisode: true))
        XCTAssertFalse(CommentComposerRules.canSubmit("", hasImage: true, isSubmitting: true, hasEpisode: true))
        XCTAssertFalse(CommentComposerRules.canSubmit("", hasImage: true, isSubmitting: false, hasEpisode: false))
        XCTAssertFalse(CommentComposerRules.canSubmit(tooLong, hasImage: true, isSubmitting: false, hasEpisode: true))
    }

    func testAppendingEmoticonRespectsLimit() {
        XCTAssertEqual(CommentComposerRules.appendingEmoticon("[微笑]", to: "太爽了"), "太爽了[微笑]")
        XCTAssertEqual(CommentComposerRules.appendingEmoticon("[微笑]", to: "12345", limit: 8), "12345")
        XCTAssertEqual(CommentComposerRules.appendingEmoticon("[微笑]", to: "1234", limit: 8), "1234[微笑]")
    }

    func testDeletingBackwardRemovesWholeKnownEmoticonToken() {
        XCTAssertEqual(CommentComposerRules.deletingBackward(from: "太爽了[微笑]", knownTokens: tokens), "太爽了")
        XCTAssertEqual(CommentComposerRules.deletingBackward(from: "[微笑][笑哭]", knownTokens: tokens), "[微笑]")
        XCTAssertEqual(CommentComposerRules.deletingBackward(from: "哈哈[ok]", knownTokens: tokens), "哈哈")
        // Unknown bracketed text deletes only the trailing bracket.
        XCTAssertEqual(CommentComposerRules.deletingBackward(from: "测试[未知]", knownTokens: tokens), "测试[未知")
        XCTAssertEqual(CommentComposerRules.deletingBackward(from: "你好", knownTokens: tokens), "你")
        XCTAssertEqual(CommentComposerRules.deletingBackward(from: "", knownTokens: tokens), "")
    }
}

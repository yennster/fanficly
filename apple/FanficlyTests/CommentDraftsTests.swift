import XCTest
@testable import Fanficly

/// #204: a comment draft outlives the comments sheet, and a failed post says
/// what went wrong without inviting a double post. Same cases as the Windows
/// app's `CommentDraftsTests`.
@MainActor
final class CommentDraftsTests: XCTestCase {
    func test_keepsADraftPerWorkAndChapter() {
        let drafts = CommentDrafts()
        drafts.set("Chapter ten was lovely.", workId: 1, chapterId: 10)
        drafts.set("The whole work!", workId: 1, chapterId: nil)

        XCTAssertEqual(drafts.text(workId: 1, chapterId: 10), "Chapter ten was lovely.")
        XCTAssertEqual(drafts.text(workId: 1, chapterId: nil), "The whole work!")
        XCTAssertEqual(drafts.text(workId: 1, chapterId: 11), "")
        XCTAssertEqual(drafts.text(workId: 2, chapterId: 10), "")
    }

    func test_blankTextAndClearForgetTheDraft() {
        let drafts = CommentDrafts()
        drafts.set("Draft", workId: 1, chapterId: 10)
        drafts.set("  \n ", workId: 1, chapterId: 10)
        XCTAssertEqual(drafts.text(workId: 1, chapterId: 10), "")

        drafts.set("Draft", workId: 1, chapterId: 10)
        drafts.clear(workId: 1, chapterId: 10)
        XCTAssertEqual(drafts.text(workId: 1, chapterId: 10), "")
    }

    func test_aRefusalIsAO3sOwnSentence() {
        XCTAssertEqual(
            CommentPostError.message(for: AO3Error.commentRejected(message: "Couldn't save comment! Comment content can't be blank.")),
            "Couldn't save comment! Comment content can't be blank.")
        XCTAssertEqual(
            CommentPostError.message(for: AO3Error.commentRejected(message: CommentPostOutcome.unconfirmed)),
            CommentPostOutcome.unconfirmed)
        XCTAssertFalse(CommentPostError.message(for: AO3Error.commentRejected(message: "Nope")).contains("moderation"))
    }

    func test_failuresAfterSendingWarnAgainstADoublePost() {
        let errors: [Error] = [
            AO3Error.network(underlying: "The request timed out."),
            AO3Error.http(status: 503),
            AO3Error.http(status: 500),
            URLError(.timedOut),
        ]
        for error in errors {
            let message = CommentPostError.message(for: error)
            XCTAssertTrue(message.hasPrefix("Couldn't post. "), message)
            XCTAssertTrue(message.hasSuffix(CommentPostError.mayHavePosted), message)
            XCTAssertFalse(message.contains(".."), message)
            XCTAssertFalse(message.contains("moderation"), message)
        }
        XCTAssertEqual(CommentPostError.message(for: AO3Error.network(underlying: "The request timed out.")),
                       "Couldn't post. Couldn't reach AO3: The request timed out. " + CommentPostError.mayHavePosted)
    }

    func test_failuresBeforeAO3TakesItDontWarn() {
        let errors: [AO3Error] = [.rateLimited, .forbidden, .blockedByProtection, .parseFailed(reason: "comment form not found")]
        for error in errors {
            let message = CommentPostError.message(for: error)
            XCTAssertTrue(message.hasPrefix("Couldn't post. "), message)
            XCTAssertFalse(message.contains(CommentPostError.mayHavePosted), message)
            XCTAssertFalse(message.contains(".."), message)
        }
    }

    func test_sentenceAddsOneFullStop() {
        XCTAssertEqual(CommentPostError.sentence("Something odd"), "Something odd.")
        XCTAssertEqual(CommentPostError.sentence("Done."), "Done.")
        XCTAssertEqual(CommentPostError.sentence("Wow!"), "Wow!")
        XCTAssertEqual(CommentPostError.sentence(" "), "Something went wrong.")
    }
}

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

    func test_keepsANewerDraftWhenAnOlderPostLands() {
        let drafts = CommentDrafts()
        drafts.set("First comment", workId: 1, chapterId: 10)
        drafts.set("A newer comment", workId: 1, chapterId: 10)
        drafts.clearIfPosted("First comment", workId: 1, chapterId: 10)
        XCTAssertEqual(drafts.text(workId: 1, chapterId: 10), "A newer comment")

        drafts.clearIfPosted("A newer comment", workId: 1, chapterId: 10)
        XCTAssertEqual(drafts.text(workId: 1, chapterId: 10), "")
    }

    func test_aPostThatMayHaveReachedAO3WarnsAgainstADoublePost() {
        for error in [AO3Error.network(underlying: "The request timed out."), .http(status: 503), .http(status: 500)] {
            XCTAssertTrue(CommentPostUncertain.mayHaveReachedAO3(error))
            let message = CommentPostError.message(for: CommentPostUncertain(underlying: error))
            XCTAssertTrue(message.hasPrefix("Couldn't post. "), message)
            XCTAssertTrue(message.hasSuffix(CommentPostError.mayHavePosted), message)
            XCTAssertFalse(message.contains(".."), message)
            XCTAssertFalse(message.contains("moderation"), message)
        }
        XCTAssertEqual(
            CommentPostError.message(for: CommentPostUncertain(underlying: .network(underlying: "The request timed out."))),
            "Couldn't post. Couldn't reach AO3: The request timed out. " + CommentPostError.mayHavePosted)
    }

    func test_aPOSTTurnedDownIsNotUncertain() {
        for error in [AO3Error.http(status: 404), .http(status: 422), .rateLimited, .forbidden, .blockedByProtection, .unauthorized] {
            XCTAssertFalse(CommentPostUncertain.mayHaveReachedAO3(error), "\(error)")
        }
    }

    func test_failuresBeforeThePOSTDontWarn() {
        // The comment page's GET failing: nothing was sent.
        let errors: [AO3Error] = [.network(underlying: "The Internet connection appears to be offline."), .http(status: 503),
                                  .rateLimited, .forbidden, .blockedByProtection, .parseFailed(reason: "comment form not found")]
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

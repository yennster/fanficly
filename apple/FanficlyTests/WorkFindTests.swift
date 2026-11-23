import XCTest
@testable import Fanficly

/// Find in this work (#183): on-device search of the loaded chapters.
final class WorkFindTests: XCTestCase {
    private func chapter(_ index: Int, _ paragraphs: [String], title: String = "") -> WorkFind.Chapter {
        WorkFind.Chapter(index: index, title: title, paragraphs: paragraphs)
    }

    func test_emptyQueryFindsNothing() {
        let chapters = [chapter(1, ["The ring was gold."])]
        XCTAssertEqual(WorkFind.search("", in: chapters), WorkFind.Result())
        XCTAssertEqual(WorkFind.search("   ", in: chapters), WorkFind.Result())
    }

    func test_findsParagraphsInReadingOrder_withTheirChapterAndIndex() {
        let chapters = [
            chapter(2, ["Nothing here.", "She took off the ring."]),
            chapter(1, ["The Ring was gold.", "No match.", "A ring, another ring."]),
        ]
        let result = WorkFind.search("ring", in: chapters)
        XCTAssertEqual(result.matches.map(\.anchor), [
            ReadingAnchor(chapter: 1, paragraph: 0),
            ReadingAnchor(chapter: 1, paragraph: 2),
            ReadingAnchor(chapter: 2, paragraph: 1),
        ])
        XCTAssertEqual(result.matches.map(\.count), [1, 2, 1])
        XCTAssertEqual(result.total, 4)
        XCTAssertFalse(result.truncated)
    }

    func test_ignoresCaseAccentsAndCurlyQuotes() {
        let chapters = [chapter(1, ["“Don’t,” said Zoë.", "Plain text."])]
        XCTAssertEqual(WorkFind.search("don't", in: chapters).matches.count, 1)
        XCTAssertEqual(WorkFind.search("\"Don't,\"", in: chapters).matches.count, 1)
        XCTAssertEqual(WorkFind.search("ZOE", in: chapters).matches.count, 1)
        XCTAssertEqual(WorkFind.search("  zoë  ", in: chapters).matches.count, 1)
    }

    func test_queryOfOnlyIgnorableMarksFindsNothing() {
        // A lone accent or a soft hyphen would otherwise match everywhere.
        let chapters = [chapter(1, ["The ring.", "Another line."])]
        XCTAssertTrue(WorkFind.search("\u{0301}", in: chapters).matches.isEmpty)
        XCTAssertTrue(WorkFind.search("\u{00AD}", in: chapters).matches.isEmpty)
    }

    func test_matchKnowsWhereTheWordsStartInTheParagraph() {
        // Page by page uses it to show the page with the words.
        let match = try! XCTUnwrap(WorkFind.search("ring", in: [chapter(1, ["One. Two. The ring."])]).matches.first)
        XCTAssertEqual(match.offset, 14)
    }

    func test_skipsImageSlots() {
        // Image slots are "" in speechParagraphs; they keep their index.
        let chapters = [chapter(1, ["", "a ring"])]
        XCTAssertEqual(WorkFind.search("ring", in: chapters).matches.map(\.paragraph), [1])
    }

    func test_limitListsTheFirstParagraphs_butCountsEveryMatch() {
        let chapters = [chapter(1, Array(repeating: "ring ring", count: 10))]
        let result = WorkFind.search("ring", in: chapters, limit: 3)
        XCTAssertEqual(result.matches.map(\.paragraph), [0, 1, 2])
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.total, 20)
    }

    func test_snippetHighlightsTheMatch() {
        let text = "“Don’t,” she said."
        let result = WorkFind.search("don't", in: [chapter(1, [text])])
        let match = try! XCTUnwrap(result.matches.first)
        XCTAssertEqual(match.snippet, text)
        let chars = Array(match.snippet)
        XCTAssertEqual(String(chars[match.highlight]), "Don’t")
    }

    func test_longParagraphSnippetStartsAtAWordAndMarksCuts() {
        let before = String(repeating: "lorem ipsum dolor ", count: 10)
        let after = String(repeating: " sit amet consectetur", count: 20)
        let text = before + "the ring" + after
        let match = try! XCTUnwrap(WorkFind.search("ring", in: [chapter(1, [text])]).matches.first)
        XCTAssertTrue(match.snippet.hasPrefix("…"))
        XCTAssertTrue(match.snippet.hasSuffix("…"))
        XCTAssertFalse(match.snippet.dropFirst().hasPrefix(" "))
        // The first word kept is whole.
        let firstWord = match.snippet.dropFirst().split(separator: " ").first.map(String.init)
        XCTAssertTrue(["lorem", "ipsum", "dolor"].contains(firstWord ?? ""), firstWord ?? "nil")
        let chars = Array(match.snippet)
        XCTAssertEqual(String(chars[match.highlight]), "ring")
        XCTAssertLessThanOrEqual(match.snippet.count, WorkFind.snippetLength + 2)
    }

    func test_paragraphsMatchTheReadersOwn() {
        // The reader's paragraph indices: speechParagraphs is index-aligned
        // with the rendered paragraphs every mode anchors to.
        let html = "<p>First.</p><p>The ring.</p><p>Last.</p>"
        let chapters = WorkFind.chapters(
            from: [AO3ChapterPayload(index: 1, title: "", bodyHTML: html, aoId: nil)], includeImages: false)
        XCTAssertEqual(WorkFind.search("ring", in: chapters).matches.map(\.paragraph), [1])
        XCTAssertEqual(HTMLToAttributed.convertParagraphs(html).count, chapters[0].paragraphs.count)
    }

    func test_chapterLabel() {
        XCTAssertEqual(WorkFind.chapterLabel(index: 3, title: ""), "Chapter 3")
        XCTAssertEqual(WorkFind.chapterLabel(index: 3, title: "The Ring"), "Chapter 3: The Ring")
    }
}

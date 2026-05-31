import XCTest
@testable import Fanficly

final class HTMLToAttributedTests: XCTestCase {
    func test_plainParagraphsHaveBreaks() {
        let out = HTMLToAttributed.convert("<p>Hello.</p><p>World.</p>")
        let s = String(out.characters)
        XCTAssertTrue(s.contains("Hello."))
        XCTAssertTrue(s.contains("World."))
        XCTAssertTrue(s.contains("\n\n"))
    }

    func test_italicHasInlineIntent() {
        let out = HTMLToAttributed.convert("<p>He said <em>hello</em>.</p>")
        let italic = out.runs.first { $0.inlinePresentationIntent?.contains(.emphasized) == true }
        XCTAssertNotNil(italic)
        XCTAssertEqual(String(out[italic!.range].characters), "hello")
    }

    func test_boldHasInlineIntent() {
        let out = HTMLToAttributed.convert("<p>Run <strong>fast</strong>.</p>")
        let bold = out.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertNotNil(bold)
        XCTAssertEqual(String(out[bold!.range].characters), "fast")
    }

    func test_brBecomesNewline() {
        let out = HTMLToAttributed.convert("Line 1<br>Line 2")
        let s = String(out.characters)
        XCTAssertTrue(s.contains("Line 1\nLine 2"))
    }

    func test_blockquoteIsBlockLevel() {
        let out = HTMLToAttributed.convert("Before<blockquote>Quote</blockquote>After")
        let s = String(out.characters)
        XCTAssertTrue(s.contains("Before"))
        XCTAssertTrue(s.contains("Quote"))
        XCTAssertTrue(s.contains("After"))
        XCTAssertTrue(s.contains("\n\nQuote\n\n") || s.contains("Before\n\nQuote"))
    }

    func test_stripsHtmlTagsWhenUnknown() {
        let out = HTMLToAttributed.convert("<span class='foo'>Visible</span>")
        XCTAssertTrue(String(out.characters).contains("Visible"))
    }

    func test_emptyParagraphsDoNotStackBlankLines() {
        // AO3 fics use empty <p> / whitespace paragraphs for scene breaks.
        let out = HTMLToAttributed.convert("<p>First.</p><p></p><p>&nbsp;</p><p>Second.</p>")
        let s = String(out.characters)
        XCTAssertTrue(s.contains("First."))
        XCTAssertTrue(s.contains("Second."))
        XCTAssertFalse(s.contains("\n\n\n"), "should never have 3+ consecutive newlines")
    }

    func test_sourceWhitespaceCollapsed() {
        let out = HTMLToAttributed.convert("<p>Hello    \n    world.</p>")
        XCTAssertTrue(String(out.characters).contains("Hello world."))
    }

    func test_nestedFormatting() {
        let out = HTMLToAttributed.convert("<p><strong><em>both</em></strong></p>")
        let r = out.runs.first { run in
            let intent = run.inlinePresentationIntent
            return intent?.contains(.stronglyEmphasized) == true && intent?.contains(.emphasized) == true
        }
        XCTAssertNotNil(r)
    }
}

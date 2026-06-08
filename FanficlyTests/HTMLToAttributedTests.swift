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

    func test_speechParagraphsSplitsAndCleans() {
        let paras = HTMLToAttributed.speechParagraphs("<p>Hello.</p><p>World.</p>")
        XCTAssertEqual(paras, ["Hello.", "World."])
    }

    func test_speechParagraphsStaysIndexAlignedWithRenderedParagraphs() {
        let html = "<p>One.</p><hr><ul><li>a</li><li>b</li></ul>"
        let rendered = HTMLToAttributed.convertParagraphs(html)
        let speech = HTMLToAttributed.speechParagraphs(html)
        // Same count as what the reader renders — the karaoke highlight relies
        // on a 1:1 paragraph index.
        XCTAssertEqual(speech.count, rendered.count)
        // The "· · ·" scene break becomes an empty (unspoken) entry; bullets
        // are stripped but the paragraph keeps its slot.
        XCTAssertFalse(speech.contains { $0.contains("•") })
        XCTAssertFalse(speech.contains("· · ·"))
        XCTAssertTrue(speech.contains(""))   // the separator's slot
        XCTAssertTrue(speech.contains("One."))
        XCTAssertTrue(speech.contains("a"))
    }

    func test_speechParagraphsFlattensSoftBreaks() {
        let paras = HTMLToAttributed.speechParagraphs("<p>Line 1<br>Line 2</p>")
        XCTAssertEqual(paras, ["Line 1 Line 2"])
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

    func test_headingBecomesItsOwnParagraph() {
        let out = HTMLToAttributed.convert("<h2>Title</h2><p>Body.</p>")
        let s = String(out.characters)
        XCTAssertTrue(s.contains("Title"))
        XCTAssertTrue(s.contains("Body."))
        XCTAssertTrue(s.contains("Title\n\nBody."))
    }

    func test_listItemsBullet() {
        let out = HTMLToAttributed.convert("<ul><li>One</li><li>Two</li></ul>")
        let s = String(out.characters)
        XCTAssertTrue(s.contains("•"))
        XCTAssertTrue(s.contains("One"))
        XCTAssertTrue(s.contains("Two"))
    }

    func test_horizontalRuleSceneBreak() {
        let out = HTMLToAttributed.convert("<p>Before</p><hr><p>After</p>")
        let s = String(out.characters)
        XCTAssertTrue(s.contains("·"))
        XCTAssertTrue(s.contains("Before"))
        XCTAssertTrue(s.contains("After"))
    }

    func test_underlineAndStrike() {
        let u = HTMLToAttributed.convert("<u>under</u>")
        XCTAssertTrue(u.runs.contains { $0.underlineStyle != nil })
        let s = HTMLToAttributed.convert("<s>strike</s>")
        XCTAssertTrue(s.runs.contains { $0.strikethroughStyle != nil })
    }

    func test_convertParagraphsSplitsBlocks() {
        let paras = HTMLToAttributed.convertParagraphs("<p>First.</p><p>Second.</p><p>Third.</p>")
        XCTAssertEqual(paras.count, 3)
        XCTAssertEqual(String(paras[0].characters), "First.")
        XCTAssertEqual(String(paras[2].characters), "Third.")
    }

    func test_emptyHTMLProducesNoParagraphs() {
        XCTAssertTrue(HTMLToAttributed.convertParagraphs("").isEmpty)
        XCTAssertTrue(HTMLToAttributed.convertParagraphs("<p></p><p>  </p>").isEmpty)
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

    func test_splitIntoSentencesPreservesFormatting() {
        let text = HTMLToAttributed.convert("<p>First sentence. <em>Second sentence is italicized.</em> Third sentence.</p>")
        let sentences = HTMLToAttributed.splitIntoSentences(text)
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(String(sentences[0].characters), "First sentence. ")
        XCTAssertEqual(String(sentences[1].characters), "Second sentence is italicized. ")
        XCTAssertEqual(String(sentences[2].characters), "Third sentence.")
        
        let italicRun = sentences[1].runs.first { $0.inlinePresentationIntent?.contains(.emphasized) == true }
        XCTAssertNotNil(italicRun)
    }
}


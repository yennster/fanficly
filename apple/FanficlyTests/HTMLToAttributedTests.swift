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

    // MARK: - Embedded images (the "Show images in stories" setting)

    func test_imagesDroppedByDefault() {
        // includeImages defaults to false — the historical behavior.
        let html = "<p>Before.</p><img src=\"https://example.com/a.png\"><p>After.</p>"
        let paras = HTMLToAttributed.convertParagraphs(html)
        XCTAssertEqual(paras.count, 2)
        XCTAssertTrue(paras.allSatisfy { HTMLToAttributed.imageAttachmentURL(in: $0) == nil })
    }

    func test_imageBecomesStandaloneSlotWhenEnabled() {
        let html = "<p>Before.</p><img src=\"https://example.com/a.png\"><p>After.</p>"
        let paras = HTMLToAttributed.convertParagraphs(html, includeImages: true)
        XCTAssertEqual(paras.count, 3)
        XCTAssertEqual(String(paras[0].characters), "Before.")
        XCTAssertEqual(HTMLToAttributed.imageAttachmentURL(in: paras[1]),
                       URL(string: "https://example.com/a.png"))
        XCTAssertEqual(String(paras[2].characters), "After.")
    }

    func test_inlineImageSplitsItsParagraph() {
        let html = "<p>Look: <img src=\"https://example.com/a.png\"> amazing.</p>"
        let paras = HTMLToAttributed.convertParagraphs(html, includeImages: true)
        XCTAssertEqual(paras.count, 3)
        XCTAssertEqual(String(paras[0].characters), "Look:")
        XCTAssertNotNil(HTMLToAttributed.imageAttachmentURL(in: paras[1]))
        XCTAssertEqual(String(paras[2].characters), "amazing.")
    }

    func test_speechSkipsImageSlotsAndStaysAligned() {
        let html = "<p>Before.</p><img src=\"https://example.com/a.png\"><p>After.</p>"
        let rendered = HTMLToAttributed.convertParagraphs(html, includeImages: true)
        let speech = HTMLToAttributed.speechParagraphs(html, includeImages: true)
        XCTAssertEqual(speech.count, rendered.count, "speech must stay index-aligned")
        XCTAssertEqual(speech, ["Before.", "", "After."], "image slots are unspoken")
    }

    func test_imageCacheKeysDoNotCollide() {
        // The same HTML converted with and without images must not share a
        // cache entry (regression: keying the cache on the HTML alone).
        let html = "<p>Text.</p><img src=\"https://example.com/b.png\">"
        XCTAssertEqual(HTMLToAttributed.convertParagraphs(html, includeImages: true).count, 2)
        XCTAssertEqual(HTMLToAttributed.convertParagraphs(html, includeImages: false).count, 1)
        XCTAssertEqual(HTMLToAttributed.convertParagraphs(html, includeImages: true).count, 2)
    }

    func test_imageURLResolution() {
        XCTAssertEqual(HTMLToAttributed.resolvedImageURL(fromSrc: "https://example.com/a.png"),
                       URL(string: "https://example.com/a.png"))
        // Protocol-relative sources get https.
        XCTAssertEqual(HTMLToAttributed.resolvedImageURL(fromSrc: "//example.com/a.png"),
                       URL(string: "https://example.com/a.png"))
        // Plain http upgrades to https (ATS would block it anyway).
        XCTAssertEqual(HTMLToAttributed.resolvedImageURL(fromSrc: "http://example.com/a.png"),
                       URL(string: "https://example.com/a.png"))
        // Non-fetchable sources are rejected.
        XCTAssertNil(HTMLToAttributed.resolvedImageURL(fromSrc: "data:image/png;base64,AAAA"))
        XCTAssertNil(HTMLToAttributed.resolvedImageURL(fromSrc: "javascript:alert(1)"))
        XCTAssertNil(HTMLToAttributed.resolvedImageURL(fromSrc: ""))
        XCTAssertNil(HTMLToAttributed.resolvedImageURL(fromSrc: "   "))
        XCTAssertNil(HTMLToAttributed.resolvedImageURL(fromSrc: "https://"))
        // AO3 itself is never an image target: image loads bypass the AO3
        // throttle and User-Agent while carrying the session cookie, so
        // root-relative paths and archiveofourown.org hosts are rejected.
        XCTAssertNil(HTMLToAttributed.resolvedImageURL(fromSrc: "/attachments/a.png"))
        XCTAssertNil(HTMLToAttributed.resolvedImageURL(fromSrc: "https://archiveofourown.org/a.png"))
    }

    func test_imageWithUnusableSrcIsDroppedEvenWhenEnabled() {
        let html = "<p>Before.</p><img src=\"data:image/png;base64,AAAA\"><p>After.</p>"
        let paras = HTMLToAttributed.convertParagraphs(html, includeImages: true)
        XCTAssertEqual(paras.count, 2)
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

    func test_convertCachingIsTransparent() {
        let html = "<p>Test caching <strong>formatting</strong>.</p>"
        let firstResult = HTMLToAttributed.convert(html)
        let secondResult = HTMLToAttributed.convert(html)
        XCTAssertEqual(firstResult, secondResult)
    }

    // MARK: - Hyperlinks

    func test_anchorCarriesLinkInConvert() {
        let out = HTMLToAttributed.convert(
            "<p>See <a href=\"https://example.com/fic\">this fic</a> too.</p>")
        let linkRun = out.runs.first { $0.link != nil }
        XCTAssertNotNil(linkRun)
        XCTAssertEqual(linkRun?.link, URL(string: "https://example.com/fic"))
        XCTAssertEqual(String(out[linkRun!.range].characters), "this fic")
        // Link runs are underlined so a themed foreground can't hide them.
        XCTAssertNotNil(linkRun?.underlineStyle)
    }

    func test_linkURLResolution() {
        XCTAssertEqual(HTMLToAttributed.resolvedLinkURL(fromHref: "https://example.com/a"),
                       URL(string: "https://example.com/a"))
        // http upgrades to https.
        XCTAssertEqual(HTMLToAttributed.resolvedLinkURL(fromHref: "http://example.com/a"),
                       URL(string: "https://example.com/a"))
        // Protocol-relative gets https.
        XCTAssertEqual(HTMLToAttributed.resolvedLinkURL(fromHref: "//example.com/a"),
                       URL(string: "https://example.com/a"))
        // Root-relative resolves against AO3 (work/user links in notes).
        XCTAssertEqual(HTMLToAttributed.resolvedLinkURL(fromHref: "/works/123"),
                       URL(string: "https://archiveofourown.org/works/123"))
        // Unusable hrefs are rejected.
        XCTAssertNil(HTMLToAttributed.resolvedLinkURL(fromHref: "javascript:alert(1)"))
        XCTAssertNil(HTMLToAttributed.resolvedLinkURL(fromHref: "data:text/html,hi"))
        XCTAssertNil(HTMLToAttributed.resolvedLinkURL(fromHref: "mailto:a@b.c"))
        XCTAssertNil(HTMLToAttributed.resolvedLinkURL(fromHref: "#footnote1"))
        XCTAssertNil(HTMLToAttributed.resolvedLinkURL(fromHref: "works/123"))
        XCTAssertNil(HTMLToAttributed.resolvedLinkURL(fromHref: ""))
    }

    func test_rejectedAnchorStillRendersItsText() {
        let out = HTMLToAttributed.convert(
            "<p>Click <a href=\"javascript:alert(1)\">here</a> now.</p>")
        XCTAssertTrue(String(out.characters).contains("Click here now."))
        XCTAssertFalse(out.runs.contains { $0.link != nil })
    }

    func test_chapterBodyPathDropsLinksAndStaysAligned() {
        let html = "<p>Read <a href=\"https://example.com\">this</a>.</p><p>Next.</p>"
        // The reader's chapter-body path (convertParagraphs default) must not
        // produce tappable links — they'd fight the tap-to-turn zones.
        let rendered = HTMLToAttributed.convertParagraphs(html)
        XCTAssertFalse(rendered.contains { para in para.runs.contains { $0.link != nil } })
        // The anchor's text still renders and speech stays index-aligned.
        XCTAssertEqual(String(rendered[0].characters), "Read this.")
        XCTAssertEqual(HTMLToAttributed.speechParagraphs(html), ["Read this.", "Next."])
    }

    func test_linkCacheKeysDoNotCollide() {
        let html = "<p><a href=\"https://example.com\">link</a></p>"
        let without = HTMLToAttributed.convertParagraphs(html)
        let with = HTMLToAttributed.convertParagraphs(html, includeLinks: true)
        XCTAssertFalse(without[0].runs.contains { $0.link != nil })
        XCTAssertTrue(with[0].runs.contains { $0.link != nil })
        // Ask again in the original mode — must not get the linked variant back.
        let again = HTMLToAttributed.convertParagraphs(html)
        XCTAssertFalse(again[0].runs.contains { $0.link != nil })
    }
}


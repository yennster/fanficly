import XCTest
@testable import Fanficly

/// Chapter titles and openings as the reader shows them (ReaderChapterText).
final class ReaderChapterTextTests: XCTestCase {
    func test_title_decodesEntitiesLeftByDoubleEscaping() {
        XCTAssertEqual(ReaderChapterText.title("Chapter 2: The Decree &amp; Draco's Hunt", index: 2),
                       "The Decree & Draco's Hunt")
        XCTAssertEqual(ReaderChapterText.title("Tea &amp;amp; Sympathy", index: 1), "Tea & Sympathy")
        XCTAssertEqual(ReaderChapterText.title("&quot;Hello,&quot; she said &#8212; &#x201C;bye&#x201D;", index: 1),
                       "\"Hello,\" she said \u{2014} \u{201C}bye\u{201D}")
        XCTAssertEqual(ReaderChapterText.title("Fish & Chips", index: 1), "Fish & Chips")
        XCTAssertEqual(ReaderChapterText.title("AT&T; and &unknown;", index: 1), "AT&T; and &unknown;")
        XCTAssertEqual(ReaderChapterText.title("Chapter 4", index: 4), "")
        XCTAssertEqual(ReaderChapterText.title("Chapter 2: Homecoming", index: 2), "Homecoming")
        XCTAssertEqual(ReaderChapterText.title("Chapter 2: Chapter 2 - Homecoming", index: 2), "Homecoming")
        // Another chapter's number is the author's (a prologue shifts them).
        XCTAssertEqual(ReaderChapterText.title("Chapter 1", index: 2), "Chapter 1")
        XCTAssertEqual(ReaderChapterText.title("Chapter 1 - Arrival", index: 2), "Chapter 1 - Arrival")
        XCTAssertEqual(ReaderChapterText.title("Chapter 11 of Our Lives", index: 1), "Chapter 11 of Our Lives")
    }

    func test_cleaned_dropsAnOpeningParagraphThatRepeatsTheTitle() {
        let chapter = AO3ChapterPayload(
            index: 2, title: "Chapter 2: The Decree &amp; Draco's Hunt",
            bodyHTML: "<p>Chapter 2: The Decree &amp;amp; Draco's Hunt</p>\n<p>The world did not end with a bang.</p>",
            aoId: 7)
        let cleaned = ReaderChapterText.cleaned(chapter)
        XCTAssertEqual(cleaned.title, "The Decree & Draco's Hunt")
        XCTAssertEqual(cleaned.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines),
                       "<p>The world did not end with a bang.</p>")
        XCTAssertEqual(cleaned.index, 2)
        XCTAssertEqual(cleaned.aoId, 7)
    }

    func test_cleaned_dropsTheRepeatedTitleInsideWrappersAndEmphasis() {
        let chapter = AO3ChapterPayload(
            index: 3, title: "Landfall",
            bodyHTML: "<div class=\"userstuff\">\n <h2><strong>Chapter Three &ndash;</strong></h2><p>x</p></div>")
        // "Chapter Three" isn't "Chapter 3": kept.
        XCTAssertEqual(ReaderChapterText.cleaned(chapter).bodyHTML, chapter.bodyHTML)

        for opening in ["<p><b>Landfall</b></p>", "<h3>LANDFALL</h3>", "<p>3. Landfall</p>",
                        "<p align=\"center\">Chapter 3</p>", "<center>Chapter 3 - Landfall</center>"] {
            let body = "<div>\(opening)<p>The ship came in.</p></div>"
            XCTAssertEqual(ReaderChapterText.cleaned(AO3ChapterPayload(index: 3, title: "Landfall", bodyHTML: body)).bodyHTML,
                           "<div><p>The ship came in.</p></div>", opening)
        }
    }

    func test_cleaned_keepsTextThatOnlyStartsLikeTheTitle() {
        let bodies = [
            // More than the title.
            "<p>Landfall was three days away.</p><p>More.</p>",
            // Story text comes first.
            "Before anything else.<p>Landfall</p>",
            "<p>Before anything else.</p><p>Landfall</p>",
            // An empty paragraph isn't a title.
            "<p> </p><p>The ship came in.</p>",
            // A plain line that equals the title can be the story's first words.
            "<p>Landfall.</p><p>The ship came in.</p>",
        ]
        for body in bodies {
            let chapter = AO3ChapterPayload(index: 3, title: "Landfall", bodyHTML: body)
            XCTAssertEqual(ReaderChapterText.cleaned(chapter).bodyHTML, body, body)
        }
    }

    func test_cleaned_keepsAPrologueShiftedChapterNumber() {
        let chapter = AO3ChapterPayload(index: 2, title: "Chapter 1", bodyHTML: "<p>Chapter 1</p><p>One.</p>")
        let cleaned = ReaderChapterText.cleaned(chapter)
        XCTAssertEqual(cleaned.title, "Chapter 1")
        // A plain line, without this chapter's number: kept.
        XCTAssertEqual(cleaned.bodyHTML, chapter.bodyHTML)
    }

    func test_cleaned_untitledChapterDropsOnlyItsNumber() {
        let chapter = AO3ChapterPayload(index: 5, title: "", bodyHTML: "<p>Chapter 5</p><p>Five.</p>")
        XCTAssertEqual(ReaderChapterText.cleaned(chapter).bodyHTML, "<p>Five.</p>")
        let other = AO3ChapterPayload(index: 5, title: "", bodyHTML: "<p>Chapter 6</p><p>Five.</p>")
        XCTAssertEqual(ReaderChapterText.cleaned(other).bodyHTML, other.bodyHTML)
    }
}

import XCTest
@testable import Fanficly

final class WorkMetadataParserTests: XCTestCase {
    func test_parsesChapterCountAndStatus() throws {
        let html = """
        <html><body>
        <dl class="stats">
          <dt class="chapters">Chapters:</dt><dd class="chapters">12/20</dd>
          <dt class="status">Updated:</dt><dd class="status">2024-03-12</dd>
        </dl>
        </body></html>
        """
        let meta = try WorkMetadataParser.parse(html: html, workId: 5)
        XCTAssertEqual(meta.id, 5)
        XCTAssertEqual(meta.chapterCount, 12)
        XCTAssertEqual(meta.totalChapters, 20)
        XCTAssertNotNil(meta.updatedAt)
    }

    func test_wipWithUnknownTotal() throws {
        let html = """
        <html><body><dl class="stats">
          <dt class="chapters">Chapters:</dt><dd class="chapters">3/?</dd>
        </dl></body></html>
        """
        let meta = try WorkMetadataParser.parse(html: html, workId: 1)
        XCTAssertEqual(meta.chapterCount, 3)
        XCTAssertNil(meta.totalChapters)
    }

    func test_missingStatsDefaults() throws {
        let meta = try WorkMetadataParser.parse(html: "<html></html>", workId: 2)
        XCTAssertEqual(meta.chapterCount, 1)
    }
}

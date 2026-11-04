import XCTest
import SwiftData
@testable import Fanficly

/// #173: Export → EPUB works offline for a story saved on this device, from
/// AO3's saved file or, without one, an EPUB built from the saved text; the
/// Downloaded badge means saved text; Settings → Storage removes the saved
/// EPUBs and keeps the text.
@MainActor
final class EPUBBuilderTests: XCTestCase {
    private static let book = EPUBBuilder.Book(
        workId: 12345,
        title: "The Long Way <Home> & Back",
        author: "Quill Writer",
        summary: "<p>Two friends drive home.</p>",
        language: "English",
        chapters: [
            .init(title: "Chapter 1: Hello", html: "<p>It was a dark &amp; stormy night.<br>Rain fell.</p><script>alert(1)</script><img src=\"https://example.com/a.png\">"),
            .init(title: "", html: "<p>They reached Ohio.</p>"),
        ])

    func testBuiltBookImportsBackWithTheSameStory() throws {
        let data = EPUBBuilder.build(Self.book)
        let payload = try EPUBImport.parse(data: data)

        XCTAssertEqual(payload.summary.id, 12345)
        XCTAssertEqual(payload.summary.title, "The Long Way <Home> & Back")
        XCTAssertEqual(payload.summary.author, "Quill Writer")
        // The title page isn't in the contents, so it isn't a chapter.
        XCTAssertEqual(payload.chapters.map(\.title), ["Chapter 1: Hello", "Chapter 2"])
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("stormy night."))
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("Rain fell."))
        XCTAssertFalse(payload.chapters[0].bodyHTML.contains("alert(1)"))
        XCTAssertFalse(payload.chapters[0].bodyHTML.contains("<img"))
        XCTAssertTrue(payload.chapters[1].bodyHTML.contains("They reached Ohio."))
    }

    func testZipStartsWithAStoredMimetype() {
        let data = EPUBBuilder.build(Self.book)
        // Local file header, method 0, and "mimetype" as the first name.
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(data[8], 0)
        XCTAssertEqual(String(decoding: data[30..<38], as: UTF8.self), "mimetype")
        XCTAssertEqual(String(decoding: data[38..<58], as: UTF8.self), "application/epub+zip")
        XCTAssertTrue(AO3Client.isEbook(data))
    }

    func testChapterHTMLBecomesWellFormedXHTML() throws {
        let body = EPUBBuilder.xhtmlBody(fromHTML: "<p bad\"name=1 class=x>One<br>two &amp; <i>three</p><hr>")
        XCTAssertTrue(body.contains("<br />") || body.contains("<br/>"))
        XCTAssertFalse(body.contains("bad"))
        let parser = XMLParser(data: Data("<body>\(body)</body>".utf8))
        XCTAssertTrue(parser.parse(), "\(body): \(String(describing: parser.parserError))")
    }

    func testEscapesAndLanguageTags() {
        XCTAssertEqual(EPUBBuilder.escape("a<b>&\"c'\u{1}"), "a&lt;b&gt;&amp;&quot;c&#39;")
        XCTAssertEqual(EPUBBuilder.languageTag("English"), "en")
        XCTAssertEqual(EPUBBuilder.languageTag("pt-BR"), "pt-BR")
        XCTAssertEqual(EPUBBuilder.identifier(Self.book), "https://archiveofourown.org/works/12345")
        var local = Self.book
        local.workId = -7
        XCTAssertEqual(EPUBBuilder.identifier(local), "urn:fanficly:-7")
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - Export, Downloaded and Storage

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, CustomFolder.self, FollowedAuthor.self,
            ReadingStat.self, BlockedTerm.self, HiddenWork.self, SavedFilter.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func testExportWithoutSavedFileBuildsFromTextAndNeverAsksAO3() async throws {
        let context = try makeContext()
        let id = 987_650_173
        let work = Work(ao3Id: id, title: "Offline Fic", authorName: "Writer")
        context.insert(work)
        context.insert(Chapter(work: work, index: 1, title: "One", bodyHTML: "<p>Saved words.</p>"))
        try context.save()
        XCTAssertNil(WorkPersistence.epubURL(workId: id))
        XCTAssertTrue(WorkPersistence.isDownloaded(work))
        XCTAssertTrue(WorkPersistence.isDownloaded(workId: id, in: context))

        let client = StubAO3Client()
        client.exportError = AO3Error.http(status: 503)  // offline: AO3 can't be reached
        let exporter = WorkExporter()
        await exporter.export(workId: id, title: "Offline Fic", format: .epub, client: client, context: context)

        XCTAssertNil(exporter.errorMessage)
        let url = try XCTUnwrap(exporter.shareItem?.url)
        XCTAssertEqual(url.lastPathComponent, "Offline Fic.epub")
        let payload = try EPUBImport.parse(data: Data(contentsOf: url))
        XCTAssertTrue(payload.chapters.first?.bodyHTML.contains("Saved words.") == true)

        // Other formats still come from AO3.
        let pdf = WorkExporter()
        await pdf.export(workId: id, title: "Offline Fic", format: .pdf, client: client, context: context)
        XCTAssertNil(pdf.shareItem)
        XCTAssertNotNil(pdf.errorMessage)
    }

    func testWorkWithoutTextIsNotDownloadedAndExportDownloads() async throws {
        let context = try makeContext()
        let work = Work(ao3Id: 987_650_174, title: "Bookmarked", authorName: "Writer")
        context.insert(work)
        try context.save()
        XCTAssertFalse(WorkPersistence.isDownloaded(work))
        XCTAssertEqual(RestoreDownloadCenter.folderDownloadCandidates([work]), [987_650_174])

        let exporter = WorkExporter()
        await exporter.export(workId: 987_650_174, title: "Bookmarked", format: .epub,
                              client: StubAO3Client(), context: context)
        XCTAssertNotNil(exporter.shareItem)  // StubAO3Client's download
    }

    func testRemovingSavedEPUBsKeepsOtherFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 100).write(to: dir.appendingPathComponent("1.epub"))
        try Data(count: 50).write(to: dir.appendingPathComponent("2.EPUB"))
        try Data(count: 10).write(to: dir.appendingPathComponent("notes.txt"))

        XCTAssertEqual(WorkPersistence.savedEPUBStorage(directory: dir),
                       WorkPersistence.EPUBStorage(count: 2, bytes: 150))
        XCTAssertEqual(WorkPersistence.removeAllSavedEPUBs(directory: dir), 2)
        XCTAssertEqual(WorkPersistence.savedEPUBStorage(directory: dir).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }
}

import XCTest
import SwiftData
@testable import Fanficly

/// #417: Export All My Data. The library as a CSV spreadsheet (the same
/// columns as the Windows app's `LibraryCsvTests` pin), and every downloaded
/// story as its own EPUB, made offline.
@MainActor
final class LibraryExportTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: AppSchema.schema, configurations: [config]))
    }

    // MARK: - Row summaries

    /// A work page's summary is HTML, and the Library and Recently Viewed
    /// keep it so: a row shows it as text, never its tags.
    func testRowSummaryDropsAWorkPagesHTML() {
        XCTAssertEqual(AO3WorkSummary.plainSummary("<p>COMPLETE</p>\n<p>Hermione &amp; Draco.</p>"),
                       "COMPLETE\nHermione & Draco.")
        XCTAssertEqual(AO3WorkSummary.plainSummary("<p>One<br/>two <i>three</i></p>"), "One\ntwo three")
    }

    /// Search results already carry text: it stays exactly as it is.
    func testRowSummaryLeavesPlainTextAlone() {
        XCTAssertEqual(AO3WorkSummary.plainSummary("I <3 this & that > the rest"), "I <3 this & that > the rest")
        XCTAssertEqual(AO3WorkSummary.plainSummary(""), "")
    }

    // MARK: - CSV

    /// The Windows app's `LibraryCsvTests.ColumnsMatchTheAppleApp` pins the
    /// same list: change both together.
    func testColumnsAreTheSharedList() {
        XCTAssertEqual(LibraryCSV.columns, [
            "ao3_url", "work_id", "title", "author", "author_url", "fandoms", "relationships",
            "characters", "additional_tags", "rating", "warnings", "categories", "language",
            "words", "chapters", "complete", "published", "updated", "kudos", "hits",
            "bookmarks", "comments", "summary", "saved_at", "last_read_at", "last_read_chapter",
            "progress_percent", "starred", "pinned", "following", "folders", "personal_tags",
            "note", "downloaded",
        ])
        XCTAssertTrue(LibraryCSV.textColumns.isSubset(of: Set(LibraryCSV.columns)))
    }

    func testEscapingFollowsRFC4180() {
        XCTAssertEqual(LibraryCSV.escape("plain"), "plain")
        XCTAssertEqual(LibraryCSV.escape("a, b"), "\"a, b\"")
        XCTAssertEqual(LibraryCSV.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(LibraryCSV.escape("one\ntwo"), "\"one\ntwo\"")
        XCTAssertEqual(LibraryCSV.escape("one\r\ntwo"), "\"one\r\ntwo\"")
        XCTAssertEqual(LibraryCSV.escape("🦊 狐狸の嫁入り"), "🦊 狐狸の嫁入り")
        XCTAssertEqual(LibraryCSV.escape(""), "")
    }

    func testFileHasABOMHeaderAndCRLFLines() {
        let data = LibraryCSV.data(rows: [Array(repeating: "x", count: LibraryCSV.columns.count)])
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("ao3_url,work_id,title,"))
        XCTAssertTrue(text.hasSuffix(",x\r\n"))
        XCTAssertEqual(text.components(separatedBy: "\r\n").count, 3)  // header, row, ""
    }

    func testRoundTripThroughACSVParserGivesBackTheSameValues() {
        let tricky = [
            "Commas, everywhere, really",
            "\"Quoted\" and \"\"doubled\"\"",
            "Line one\nLine two\r\nLine three",
            "Emoji 🦊🏳️‍🌈 and Ελληνικά, Русский, 日本語, العربية",
            "",
            "trailing space ",
        ]
        var rows: [[String]] = []
        for (i, value) in tricky.enumerated() {
            var row = Array(repeating: "", count: LibraryCSV.columns.count)
            row[0] = "https://archiveofourown.org/works/\(i)"
            row[2] = value  // title
            row[22] = value  // summary
            row[32] = value  // note
            rows.append(row)
        }
        let text = String(decoding: LibraryCSV.data(rows: rows).dropFirst(3), as: UTF8.self)
        let parsed = Self.parseCSV(text)
        XCTAssertEqual(parsed.first, LibraryCSV.columns)
        XCTAssertEqual(Array(parsed.dropFirst()), rows)
    }

    func testFormulaLikeTextIsKeptAsText() {
        XCTAssertEqual(LibraryCSV.guarded("=HYPERLINK(\"http://x\")"), "'=HYPERLINK(\"http://x\")")
        XCTAssertEqual(LibraryCSV.guarded("+1"), "'+1")
        XCTAssertEqual(LibraryCSV.guarded("-dash"), "'-dash")
        XCTAssertEqual(LibraryCSV.guarded("@me"), "'@me")
        XCTAssertEqual(LibraryCSV.guarded("Normal"), "Normal")
        var row = Array(repeating: "", count: LibraryCSV.columns.count)
        row[2] = "=1+1"  // title: guarded
        row[13] = "-5"  // words: a number column, left alone
        let parsed = Self.parseCSV(LibraryCSV.text(rows: [row]))
        XCTAssertEqual(parsed[1][2], "'=1+1")
        XCTAssertEqual(parsed[1][13], "-5")
    }

    func testRowForAWork() throws {
        let context = try makeContext()
        let work = Work(ao3Id: 4242, title: "The Long Way, Home", authorName: "Quill (quill_writer)",
                        summary: "<p>Two friends &amp; a car.<br/>Road trip!</p><p>  Second   para. </p>",
                        rating: "Teen And Up Audiences", warnings: ["No Archive Warnings Apply"],
                        categories: ["F/M", "Gen"], fandoms: ["Teen Wolf", "Supernatural"],
                        characters: ["Stiles"], relationships: ["Derek/Stiles"],
                        freeforms: ["Fluff", "Road Trip"], language: "English", wordCount: 12345,
                        chapterCount: 12, totalChapters: nil, kudos: 10, hits: 200,
                        bookmarksCount: 3, commentsCount: 4, isComplete: false,
                        publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        updatedAt: nil, savedAt: Date(timeIntervalSince1970: 1_750_000_000))
        work.authorUsername = "quill_writer"
        work.lastReadAt = Date(timeIntervalSince1970: 1_760_000_000)
        work.lastReadChapter = 3
        work.lastReadProgress = 0.256
        work.isStarred = true
        work.isFollowed = true
        work.note = "for a bad day"
        work.personalTags = ["comfort", "reread"]
        context.insert(work)
        let a = CustomFolder(name: "Zed"), b = CustomFolder(name: "Alpha")
        context.insert(a); context.insert(b)
        work.folders = [a, b]
        context.insert(Chapter(work: work, index: 1, title: "One", bodyHTML: "<p>Hi</p>"))
        try context.save()

        let row = LibraryCSV.row(for: work)
        let cell = { (name: String) in row[LibraryCSV.columns.firstIndex(of: name)!] }
        XCTAssertEqual(row.count, LibraryCSV.columns.count)
        XCTAssertEqual(cell("ao3_url"), "https://archiveofourown.org/works/4242")
        XCTAssertEqual(cell("work_id"), "4242")
        XCTAssertEqual(cell("title"), "The Long Way, Home")
        XCTAssertEqual(cell("author_url"), "https://archiveofourown.org/users/quill_writer")
        XCTAssertEqual(cell("fandoms"), "Teen Wolf; Supernatural")
        XCTAssertEqual(cell("additional_tags"), "Fluff; Road Trip")
        XCTAssertEqual(cell("categories"), "F/M; Gen")
        XCTAssertEqual(cell("words"), "12345")
        XCTAssertEqual(cell("chapters"), "12/?")
        XCTAssertEqual(cell("complete"), "no")
        XCTAssertEqual(cell("published"), "2023-11-14T22:13:20Z")
        XCTAssertEqual(cell("updated"), "")
        XCTAssertEqual(cell("saved_at"), "2025-06-15T15:06:40Z")
        XCTAssertEqual(cell("summary"), "Two friends & a car.\nRoad trip!\nSecond para.")
        XCTAssertEqual(cell("last_read_chapter"), "3")
        XCTAssertEqual(cell("progress_percent"), "26")
        XCTAssertEqual(cell("starred"), "yes")
        XCTAssertEqual(cell("pinned"), "no")
        XCTAssertEqual(cell("following"), "yes")
        XCTAssertEqual(cell("folders"), "Alpha; Zed")
        XCTAssertEqual(cell("personal_tags"), "comfort; reread")
        XCTAssertEqual(cell("note"), "for a bad day")
        XCTAssertEqual(cell("downloaded"), "yes")

        work.totalChapters = 20
        work.isComplete = true
        work.lastReadProgress = nil
        XCTAssertEqual(LibraryCSV.row(for: work)[14], "12/20")
        XCTAssertEqual(LibraryCSV.row(for: work)[15], "yes")
        XCTAssertEqual(LibraryCSV.row(for: work)[26], "")
    }

    func testImportedBooksHaveNoAO3Link() throws {
        let context = try makeContext()
        let work = Work(ao3Id: -77, title: "My Own Book", authorName: "Me")
        work.authorUsername = "me"
        context.insert(work)
        let row = LibraryCSV.row(for: work)
        XCTAssertEqual(row[0], "")
        XCTAssertEqual(row[1], "")
        XCTAssertEqual(row[4], "")
        XCTAssertEqual(row[2], "My Own Book")
        XCTAssertEqual(row[33], "no")
    }

    func testWritesEveryWorkToANamedFile() throws {
        let context = try makeContext()
        context.insert(Work(ao3Id: 1, title: "First", authorName: "A", savedAt: Date(timeIntervalSince1970: 1)))
        context.insert(Work(ao3Id: 2, title: "Second", authorName: "B", savedAt: Date(timeIntervalSince1970: 2)))
        try context.save()
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let url = try LibraryCSV.writeTemporaryFile(context: context, now: now)
        XCTAssertEqual(url.lastPathComponent, LibraryCSV.fileName(on: now))
        XCTAssertEqual(LibraryCSV.fileName(on: now, timeZone: TimeZone(identifier: "UTC")!),
                       "Fanficly Library 2026-11-18.csv")
        let parsed = Self.parseCSV(String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self))
        XCTAssertEqual(parsed.dropFirst().map { $0[2] }, ["First", "Second"])
    }

    // MARK: - Every downloaded EPUB

    func testFileNamesAddTheWorkIdOnlyWhenNamesCollide() {
        let names = BulkEPUBExporter.fileNames([
            (1, "Stay"), (2, "stay"), (3, "Gone: Again?"), (4, ""), (5, "Unique"),
        ])
        XCTAssertEqual(names[1], "Stay (1)")
        XCTAssertEqual(names[2], "stay (2)")
        XCTAssertEqual(names[3], "Gone- Again-")
        XCTAssertEqual(names[4], "work-4")
        XCTAssertEqual(names[5], "Unique")
    }

    func testExportsOneValidEPUBPerDownloadedWorkWithoutAO3() async throws {
        let context = try makeContext()
        let epubs = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-epubs-\(UUID().uuidString)", isDirectory: true)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: epubs, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: epubs)
            try? FileManager.default.removeItem(at: out)
        }

        // Text only: built from the text.
        let textOnly = Work(ao3Id: 917_001, title: "Same Name", authorName: "A")
        context.insert(textOnly)
        context.insert(Chapter(work: textOnly, index: 1, title: "One", bodyHTML: "<p>Text-only words.</p>"))
        // A saved AO3 EPUB as well as text: the saved file is shared.
        let saved = Work(ao3Id: 917_002, title: "Same Name", authorName: "B")
        context.insert(saved)
        context.insert(Chapter(work: saved, index: 1, title: "One", bodyHTML: "<p>Old text.</p>"))
        let savedBook = EPUBBuilder.Book(workId: 917_002, title: "Same Name", author: "B", summary: "",
                                         language: "en", chapters: [.init(title: "One", html: "<p>From the saved file.</p>")])
        try EPUBBuilder.build(savedBook).write(to: epubs.appendingPathComponent("917002.epub"))
        // Not downloaded: left out.
        context.insert(Work(ao3Id: 917_003, title: "Bookmark Only", authorName: "C"))
        try context.save()

        let plan = BulkEPUBExporter.plan(in: context, epubDirectory: epubs)
        XCTAssertEqual(Set(plan.workIds), [917_001, 917_002])
        XCTAssertGreaterThan(plan.estimatedBytes, 0)

        // No client is involved at all: the export never reaches AO3.
        let exporter = BulkEPUBExporter()
        let result = try await exporter.export(plan, context: context, epubDirectory: epubs, outputDirectory: out)
        let urls = try XCTUnwrap(result)
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)),
                       ["Same Name (917001).epub", "Same Name (917002).epub"])
        for url in urls {
            let data = try Data(contentsOf: url)
            XCTAssertTrue(AO3Client.isEbook(data))
            let payload = try EPUBImport.parse(data: data)
            if url.lastPathComponent.contains("917001") {
                XCTAssertEqual(payload.summary.id, 917_001)
                XCTAssertTrue(payload.chapters.first?.bodyHTML.contains("Text-only words.") == true)
            } else {
                XCTAssertEqual(payload.summary.id, 917_002)
                XCTAssertTrue(payload.chapters.first?.bodyHTML.contains("From the saved file.") == true)
            }
        }
    }

    func testNothingDownloadedMakesAnEmptyPlan() throws {
        let context = try makeContext()
        context.insert(Work(ao3Id: 917_010, title: "Bookmark Only", authorName: "C"))
        try context.save()
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        XCTAssertEqual(BulkEPUBExporter.plan(in: context, epubDirectory: empty).count, 0)
    }

    // MARK: - A small RFC 4180 reader, for the round trips

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\r\n" || c == "\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

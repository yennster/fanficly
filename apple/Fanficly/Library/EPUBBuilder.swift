import Foundation
import SwiftData
import SwiftSoup

/// Makes an EPUB from a saved work's chapter text, so Export → EPUB works
/// offline for every story saved on this device, including ones whose AO3
/// EPUB was never fetched (a restore) or was removed in Settings → Storage
/// (#173). When AO3's own file is saved, Export shares that instead
/// (`WorkExporter`).
///
/// The book is EPUB 3 with an EPUB 2 table of contents (`toc.ncx`) for older
/// readers: a title page (title, author, AO3 link, summary), then one XHTML
/// file per chapter. The contents list only the chapters, so importing the
/// file back (`EPUBImport`, which leaves out what comes before the first
/// entry) gives the same chapters. Images are left out, as the reader leaves them out
/// offline. The zip is written by hand with every entry stored (no
/// compression), which the EPUB spec allows and every reader accepts; the
/// `mimetype` entry must be first and stored anyway.
enum EPUBBuilder {
    struct Book: Equatable, Sendable {
        var workId: Int
        var title: String
        var author: String
        /// HTML, as AO3 shows it.
        var summary: String
        var language: String
        var chapters: [Chapter]
    }

    struct Chapter: Equatable, Sendable {
        var title: String
        /// HTML, as saved.
        var html: String
    }

    /// The book for a saved work, chapters in reading order.
    @MainActor
    static func book(from work: Work) -> Book {
        Book(workId: work.ao3Id,
             title: work.title,
             author: work.authorName,
             summary: work.summary,
             language: work.language,
             chapters: work.chapters.sorted { $0.index < $1.index }
                .map { Chapter(title: $0.title, html: $0.bodyHTML) })
    }

    /// Writes the book to a temporary file named after its title, ready for
    /// the share sheet. Throws only when the file can't be written.
    static func writeTemporaryFile(_ book: Book) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = AO3Client.sanitizeFilename(book.title)
        let url = dir.appendingPathComponent("\(name.isEmpty ? "work-\(book.workId)" : name).epub")
        try? FileManager.default.removeItem(at: url)
        try build(book).write(to: url, options: .atomic)
        return url
    }

    /// The EPUB file's bytes.
    static func build(_ book: Book) -> Data {
        var zip = StoredZip()
        zip.add("mimetype", "application/epub+zip")
        zip.add("META-INF/container.xml", containerXML)
        zip.add("OEBPS/content.opf", packageDocument(book))
        zip.add("OEBPS/nav.xhtml", navDocument(book))
        zip.add("OEBPS/toc.ncx", ncx(book))
        zip.add("OEBPS/style.css", stylesheet)
        zip.add("OEBPS/title.xhtml", titlePage(book))
        for (i, chapter) in book.chapters.enumerated() {
            zip.add("OEBPS/\(chapterFile(i))", chapterPage(chapter, number: i + 1, in: book))
        }
        return zip.finish()
    }

    // MARK: - Documents

    private static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    private static let stylesheet = """
        body { font-family: serif; line-height: 1.5; margin: 0 5%; }
        h1, h2 { text-align: center; }
        p.byline { text-align: center; font-style: italic; }
        p.source { text-align: center; font-size: 0.9em; }
        blockquote { margin: 1em 1.5em; }
        """

    static func chapterFile(_ index: Int) -> String { "chapter-\(index + 1).xhtml" }

    static func chapterTitle(_ chapter: Chapter, number: Int) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Chapter \(number)" : title
    }

    /// The book's identifier: the AO3 work URL, or a stable URN for an
    /// imported book that isn't on AO3.
    static func identifier(_ book: Book) -> String {
        EPUBImport.isLocalWork(book.workId)
            ? "urn:fanficly:\(book.workId)"
            : "https://archiveofourown.org/works/\(book.workId)"
    }

    /// A BCP 47 tag for `dc:language`. AO3 gives a language name ("English"),
    /// which isn't one, so anything that doesn't look like a tag is "en".
    static func languageTag(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespaces)
        let isTag = trimmed.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
        return isTag ? trimmed : "en"
    }

    private static func packageDocument(_ book: Book) -> String {
        let chapters = book.chapters.indices
        let manifest = chapters.map {
            "    <item id=\"c\($0 + 1)\" href=\"\(chapterFile($0))\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = chapters.map { "    <itemref idref=\"c\($0 + 1)\"/>" }.joined(separator: "\n")
        let modified = ISO8601DateFormatter().string(from: Date())
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(languageTag(book.language))">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">\(escape(identifier(book)))</dc:identifier>
                <dc:title>\(escape(book.title))</dc:title>
                <dc:creator>\(escape(book.author))</dc:creator>
                <dc:language>\(languageTag(book.language))</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="css" href="style.css" media-type="text/css"/>
                <item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>
            \(manifest)
              </manifest>
              <spine toc="ncx">
                <itemref idref="title"/>
            \(spine)
              </spine>
            </package>
            """
    }

    private static func navDocument(_ book: Book) -> String {
        let items = book.chapters.enumerated().map { i, chapter in
            "      <li><a href=\"\(chapterFile(i))\">\(escape(chapterTitle(chapter, number: i + 1)))</a></li>"
        }.joined(separator: "\n")
        return xhtml(title: "Contents", lang: languageTag(book.language), body: """
            <nav epub:type="toc" id="toc">
              <h1>Contents</h1>
              <ol>
            \(items)
              </ol>
            </nav>
            """)
    }

    private static func ncx(_ book: Book) -> String {
        var points: [String] = []
        for (i, chapter) in book.chapters.enumerated() {
            points.append("""
                    <navPoint id="np\(i + 1)" playOrder="\(i + 1)"><navLabel><text>\(escape(chapterTitle(chapter, number: i + 1)))</text></navLabel><content src="\(chapterFile(i))"/></navPoint>
                """)
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head>
                <meta name="dtb:uid" content="\(escape(identifier(book)))"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="0"/>
                <meta name="dtb:maxPageNumber" content="0"/>
              </head>
              <docTitle><text>\(escape(book.title))</text></docTitle>
              <navMap>
            \(points.joined(separator: "\n"))
              </navMap>
            </ncx>
            """
    }

    private static func titlePage(_ book: Book) -> String {
        var body = "<h1>\(escape(book.title))</h1>\n"
        if !book.author.isEmpty {
            body += "<p class=\"byline\">by \(escape(book.author))</p>\n"
        }
        if !EPUBImport.isLocalWork(book.workId) {
            let link = identifier(book)
            body += "<p class=\"source\"><a href=\"\(escape(link))\">\(escape(link))</a></p>\n"
        }
        let summary = xhtmlBody(fromHTML: book.summary)
        if !summary.isEmpty {
            body += "<h2>Summary</h2>\n<blockquote>\(summary)</blockquote>\n"
        }
        return xhtml(title: book.title, lang: languageTag(book.language), body: body)
    }

    private static func chapterPage(_ chapter: Chapter, number: Int, in book: Book) -> String {
        let title = chapterTitle(chapter, number: number)
        return xhtml(title: title, lang: languageTag(book.language),
                     body: "<h2>\(escape(title))</h2>\n\(xhtmlBody(fromHTML: chapter.html))")
    }

    private static func xhtml(title: String, lang: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(lang)" lang="\(lang)">
        <head>
          <meta charset="UTF-8"/>
          <title>\(escape(title))</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Saved chapter HTML as well-formed XHTML: SwiftSoup re-serializes it as
    /// XML (closed void tags, escaped text). Scripts, styles, embeds and
    /// forms are dropped, and so are images, which would be remote resources.
    /// Attributes whose names aren't valid XML are dropped so the file
    /// still parses.
    static func xhtmlBody(fromHTML html: String) -> String {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body() else {
            let text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return "<p>\(escape(text))</p>"
        }
        _ = try? doc.select("script, style, link, meta, iframe, object, embed, form, input, button, img, svg, video, audio, source").remove()
        if let all = try? body.getAllElements() {
            for element in all.array() {
                guard let attributes = element.getAttributes() else { continue }
                for attribute in attributes.asList() where !isXMLName(attribute.getKey()) {
                    _ = try? element.removeAttr(attribute.getKey())
                }
            }
        }
        _ = doc.outputSettings()
            .syntax(syntax: .xml)
            .escapeMode(Entities.EscapeMode.xhtml)
            .prettyPrint(pretty: false)
        return (try? body.html()) ?? ""
    }

    static func isXMLName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:
                // Control characters other than tab and newlines aren't
                // allowed in XML 1.0 at all.
                if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// A zip archive with every entry stored (method 0): what an EPUB needs,
/// with no compression library.
struct StoredZip {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(_ path: String, _ text: String) {
        add(path, Data(text.utf8))
    }

    mutating func add(_ path: String, _ contents: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(contents)
        let offset = UInt32(data.count)
        // 1980-01-01 00:00, the earliest DOS date: the files have no
        // meaningful time, and a fixed one keeps the output reproducible.
        let time: UInt16 = 0
        let date: UInt16 = (0 << 9) | (1 << 5) | 1

        var local = Data()
        local.appendLE(UInt32(0x0403_4b50))
        local.appendLE(UInt16(20))        // version needed
        local.appendLE(UInt16(0x0800))    // flags: UTF-8 names
        local.appendLE(UInt16(0))         // stored
        local.appendLE(time)
        local.appendLE(date)
        local.appendLE(crc)
        local.appendLE(UInt32(contents.count))
        local.appendLE(UInt32(contents.count))
        local.appendLE(UInt16(name.count))
        local.appendLE(UInt16(0))         // extra length
        data.append(local)
        data.append(name)
        data.append(contents)

        var entry = Data()
        entry.appendLE(UInt32(0x0201_4b50))
        entry.appendLE(UInt16(20))        // version made by
        entry.appendLE(UInt16(20))        // version needed
        entry.appendLE(UInt16(0x0800))
        entry.appendLE(UInt16(0))
        entry.appendLE(time)
        entry.appendLE(date)
        entry.appendLE(crc)
        entry.appendLE(UInt32(contents.count))
        entry.appendLE(UInt32(contents.count))
        entry.appendLE(UInt16(name.count))
        entry.appendLE(UInt16(0))         // extra length
        entry.appendLE(UInt16(0))         // comment length
        entry.appendLE(UInt16(0))         // disk number
        entry.appendLE(UInt16(0))         // internal attributes
        entry.appendLE(UInt32(0))         // external attributes
        entry.appendLE(offset)
        central.append(entry)
        central.append(name)
        count += 1
    }

    mutating func finish() -> Data {
        let centralOffset = UInt32(data.count)
        var out = data
        out.append(central)
        out.appendLE(UInt32(0x0605_4b50))
        out.appendLE(UInt16(0))           // this disk
        out.appendLE(UInt16(0))           // disk with the directory
        out.appendLE(count)
        out.appendLE(count)
        out.appendLE(UInt32(central.count))
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0))           // comment length
        return out
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}

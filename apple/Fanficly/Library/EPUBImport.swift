import Foundation
import SwiftSoup
#if canImport(Compression)
import Compression
#endif

/// Turns an EPUB file (an AO3 download, or any other e-book) into a work the
/// Library can hold and the reader can open offline. Pure: no SwiftData, no
/// network. `EPUBImportCenter` saves what this returns.
///
/// An AO3 EPUB keeps its AO3 work id (from the "archiveofourown.org/works/<id>"
/// link AO3 puts in the book), so importing one fills in the same Library
/// entry a download would, and AO3 actions keep working once AO3 is reachable.
/// Any other book gets a negative id derived from the book's identifier
/// (`localWorkId`), which can never clash with an AO3 work and stays the same
/// when the same book is imported again.
enum EPUBImport {
    enum ImportError: LocalizedError, Equatable {
        case notAnEPUB
        case damaged(String)
        case noText

        var errorDescription: String? {
            switch self {
            case .notAnEPUB: "This file isn't an EPUB e-book."
            case .damaged(let detail): "The EPUB couldn't be read (\(detail))."
            case .noText: "The EPUB has no chapter text to read."
            }
        }
    }

    /// Parses an EPUB's bytes into a work and its chapters.
    static func parse(data: Data) throws -> AO3WorkPayload {
        let zip = try ZipFile(data: data)

        // META-INF/container.xml names the package (OPF) file.
        guard let containerXML = try zip.text("META-INF/container.xml") else { throw ImportError.notAnEPUB }
        let container = try SwiftSoup.parse(containerXML, "", Parser.xmlParser())
        guard let opfPath = elements(named: "rootfile", in: container).first.flatMap({ try? $0.attr("full-path") }),
              !opfPath.isEmpty,
              let opfXML = try zip.text(opfPath)
        else { throw ImportError.damaged("no package file") }
        let opf = try SwiftSoup.parse(opfXML, "", Parser.xmlParser())
        let opfDir = directory(of: opfPath)

        // Manifest: id → (path, media type, properties).
        var manifest: [String: (path: String, type: String, properties: String)] = [:]
        for item in elements(named: "item", in: opf) {
            guard let id = try? item.attr("id"), let href = try? item.attr("href"), !href.isEmpty else { continue }
            manifest[id] = (resolve(href, against: opfDir),
                            ((try? item.attr("media-type")) ?? "").lowercased(),
                            (try? item.attr("properties")) ?? "")
        }
        let spinePaths: [String] = elements(named: "itemref", in: opf).compactMap {
            guard let idref = try? $0.attr("idref"), let item = manifest[idref] else { return nil }
            return item.type.contains("html") || item.path.lowercased().hasSuffix("html") ? item.path : nil
        }
        guard !spinePaths.isEmpty else { throw ImportError.damaged("no reading order") }

        var docs: [Document] = []
        var rawFirstDocs = ""
        for (i, path) in spinePaths.enumerated() {
            let html = try zip.text(path) ?? ""
            if i < 3 { rawFirstDocs += html }
            docs.append(try SwiftSoup.parse(expandSelfClosingTags(html)))
        }

        // Book metadata (Dublin Core).
        func dc(_ name: String) -> [String] {
            elements(named: name, in: opf)
                .compactMap { try? $0.text(trimAndNormaliseWhitespace: false).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        // The book's own link comes first in AO3's preface, before the summary
        // (which may link other works); the package's identifier or source
        // is the fallback.
        let ao3Id = ao3WorkId(in: rawFirstDocs) ?? ao3WorkId(in: (dc("identifier") + dc("source")).joined(separator: " "))
        let preface = docs.prefix(3).map { AO3Preface(document: $0) }.first { !$0.isEmpty } ?? AO3Preface()

        // Table of contents: the NCX (EPUB 2) or the nav document (EPUB 3).
        let spineIndex = Dictionary(spinePaths.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var toc: [TOCEntry] = []
        let tocId = elements(named: "spine", in: opf).first.flatMap { try? $0.attr("toc") } ?? ""
        let ncxPath = manifest[tocId]?.path
            ?? manifest.values.first { $0.type == "application/x-dtbncx+xml" }?.path
        if let ncxPath, let ncxXML = try zip.text(ncxPath) {
            let ncx = try SwiftSoup.parse(ncxXML, "", Parser.xmlParser())
            let dir = directory(of: ncxPath)
            for point in elements(named: "navPoint", in: ncx) {
                let label = point.children().array().first { localName($0).caseInsensitiveCompare("navLabel") == .orderedSame }.flatMap { try? $0.text() } ?? ""
                guard let content = point.children().array().first(where: { localName($0).caseInsensitiveCompare("content") == .orderedSame }),
                      let src = try? content.attr("src") else { continue }
                toc.append(TOCEntry(label: label, href: src, base: dir))
            }
        }
        if toc.isEmpty, let navPath = manifest.values.first(where: { $0.properties.contains("nav") })?.path,
           let navHTML = try zip.text(navPath) {
            let nav = try SwiftSoup.parse(expandSelfClosingTags(navHTML))
            let dir = directory(of: navPath)
            let navs = try nav.select("nav").array()
            let tocNav = navs.first { ((try? $0.attr("epub:type")) ?? "").contains("toc") } ?? navs.first
            for link in try tocNav?.select("a[href]").array() ?? [] {
                toc.append(TOCEntry(label: (try? link.text()) ?? "", href: (try? link.attr("href")) ?? "", base: dir))
            }
        }

        var sections = split(docs: docs, toc: toc, spineIndex: spineIndex)
        let fromAO3 = ao3Id != nil || !preface.isEmpty
        if fromAO3 { sections = foldAO3FrontAndBackMatter(sections) }
        sections = sections.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !sections.isEmpty else { throw ImportError.noText }
        if let notes = preface.notesHTML {
            sections[0].html = "<p><b>Notes:</b></p><blockquote>\(notes)</blockquote>" + sections[0].html
        }

        let chapters = sections.enumerated().map { i, section in
            AO3ChapterPayload(
                index: i + 1,
                title: section.title.isEmpty ? "Chapter \(i + 1)" : section.title,
                bodyHTML: section.html,
                aoId: ao3Id == nil ? nil : chapterId(in: section.headingHTML)
            )
        }
        let title = dc("title").first ?? preface.title ?? "Untitled"
        let creators = dc("creator")
        let author = creators.isEmpty ? (preface.author ?? "Unknown author") : creators.joined(separator: ", ")
        let identifier = dc("identifier").first ?? ""
        let words = preface.words ?? sections.reduce(0) { $0 + wordCount($1.text) }

        let summary = AO3WorkSummary(
            id: ao3Id ?? localWorkId(identifier: identifier, title: title, author: author),
            title: title,
            author: author,
            authorUsername: preface.authorUsername,
            summary: preface.summaryHTML ?? dc("description").first.map(summaryHTML(from:)) ?? "",
            rating: preface.rating ?? "Not Rated",
            warnings: preface.warnings,
            categories: preface.categories,
            fandoms: preface.fandoms,
            characters: preface.characters,
            relationships: preface.relationships,
            freeforms: preface.freeforms.isEmpty && !fromAO3 ? dc("subject") : preface.freeforms,
            wordCount: words,
            chapterCount: chapters.count,
            totalChapters: preface.totalChapters ?? (fromAO3 ? nil : chapters.count),
            language: preface.language ?? dc("language").first ?? "en",
            kudos: 0,
            hits: 0,
            isComplete: preface.isComplete ?? !fromAO3,
            updatedAt: preface.updatedAt ?? preface.publishedAt
        )
        return AO3WorkPayload(summary: summary, chapters: chapters)
    }

    // MARK: - Ids

    /// The AO3 work id in the first "archiveofourown.org/works/<id>" link.
    static func ao3WorkId(in text: String) -> Int? {
        firstMatch(#"archiveofourown\.org/works/(\d+)"#, in: text).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// A negative, stable id for a book that isn't from AO3: FNV-1a of its
    /// identifier (or title and author when it has none), so importing the
    /// same book again replaces it instead of adding a copy.
    static func localWorkId(identifier: String, title: String, author: String) -> Int {
        let key = identifier.isEmpty ? "\(title)\u{1F}\(author)" : identifier
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return -Int(hash % 2_000_000_000) - 1
    }

    /// True for the ids `localWorkId` hands out: a book that isn't on AO3.
    static func isLocalWork(_ id: Int) -> Bool { id < 0 }

    private static func chapterId(in html: String) -> Int? {
        firstMatch(#"/works/\d+/chapters/(\d+)"#, in: html).flatMap { Int($0) }
    }

    // MARK: - Splitting into chapters

    private struct TOCEntry {
        let label: String
        let path: String
        let fragment: String?

        init(label: String, href: String, base: String) {
            self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            path = parts.first.map { EPUBImport.resolve(String($0), against: base) } ?? ""
            fragment = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : nil
        }
    }

    struct Section {
        var title: String
        var html = ""
        var text = ""
        /// The markup of the heading the section starts at, where AO3 links
        /// the chapter (for its chapter id).
        var headingHTML = ""
    }

    /// Splits the spine into sections at the table of contents' entries.
    /// Text before the first entry (a cover or title page) is left out.
    /// Without a usable table of contents every spine document is a section.
    private static func split(docs: [Document], toc: [TOCEntry], spineIndex: [String: Int]) -> [Section] {
        for doc in docs { clean(doc) }

        // Each entry's start: (spine index, element or nil for the top of the file).
        var starts: [(spine: Int, element: Element?, label: String)] = []
        var lastPosition = (-1, -1)
        for entry in toc {
            guard let spine = spineIndex[entry.path] else { continue }
            var element: Element?
            var position = -1
            if let fragment = entry.fragment, let body = docs[spine].body() {
                // Not the body itself: an entry pointing at it is the top of the file.
                let all = ((try? body.getAllElements().array()) ?? []).filter { $0 !== body }
                if let i = all.firstIndex(where: { $0.id() == fragment || ((try? $0.attr("name")) ?? "") == fragment }) {
                    element = all[i]
                    position = i
                }
            }
            // Out of document order, or the same place again: not a new section.
            guard (spine, position) > lastPosition else { continue }
            lastPosition = (spine, position)
            starts.append((spine, element, entry.label))
        }

        guard !starts.isEmpty else {
            return docs.compactMap { doc -> Section? in
                guard let body = doc.body() else { return nil }
                var section = Section(title: headingText(in: body) ?? "")
                for node in body.getChildNodes() { append(node, to: &section) }
                return section
            }
        }

        var sections: [Section] = []
        var current: Section?
        for (spine, doc) in docs.enumerated() {
            guard let body = doc.body() else { continue }
            let here = starts.filter { $0.spine == spine }
            if let top = here.first(where: { $0.element == nil }) {
                if let current { sections.append(current) }
                current = Section(title: top.label,
                                  headingHTML: (try? body.select("h1, h2, h3").first()?.outerHtml()) ?? "")
            }
            var labels: [ObjectIdentifier: String] = [:]
            var containsStart = Set<ObjectIdentifier>()
            for start in here {
                guard let element = start.element else { continue }
                labels[ObjectIdentifier(element)] = start.label
                var parent = element.parent()
                while let p = parent {
                    containsStart.insert(ObjectIdentifier(p))
                    parent = p.parent()
                }
            }

            func walk(_ node: Node) {
                if let element = node as? Element {
                    let id = ObjectIdentifier(element)
                    if let label = labels[id] {
                        if let current { sections.append(current) }
                        current = Section(title: label, headingHTML: (try? element.outerHtml()) ?? "")
                        // A heading that just repeats the entry's title is the
                        // reader's chapter title already.
                        if !containsStart.contains(id) {
                            if !isHeading(element, repeating: label), current != nil { append(element, to: &current!) }
                            return
                        }
                    }
                    if containsStart.contains(id) {
                        for child in element.getChildNodes() { walk(child) }
                        return
                    }
                }
                if current != nil { append(node, to: &current!) }
            }
            for node in body.getChildNodes() { walk(node) }
        }
        if let current { sections.append(current) }
        return sections
    }

    /// AO3 books open with a "Preface" (the work's tags and summary, read
    /// into the Library entry instead) and end with an "Afterword" (the end
    /// notes, which belong to the last chapter).
    static func foldAO3FrontAndBackMatter(_ sections: [Section]) -> [Section] {
        var result: [Section] = []
        for section in sections {
            let title = section.title.lowercased()
            if title == "preface" { continue }
            if title == "afterword", !result.isEmpty {
                result[result.count - 1].html += section.html
                result[result.count - 1].text += " " + section.text
                continue
            }
            result.append(section)
        }
        return result
    }

    private static func append(_ node: Node, to section: inout Section) {
        if node is Comment || node is DataNode { return }
        if let text = node as? TextNode {
            section.text += text.text()
            section.html += (try? text.outerHtml()) ?? ""
            return
        }
        guard let element = node as? Element else { return }
        section.text += " " + ((try? element.text()) ?? "")
        section.html += (try? element.outerHtml()) ?? ""
    }

    /// Takes out what the reader can't use from a book's markup: scripts,
    /// styles, and pictures stored inside the book (the reader only shows
    /// pictures from the web).
    private static func clean(_ doc: Document) {
        _ = try? doc.select("script, style, link, meta, svg, object, iframe").remove()
        for image in (try? doc.select("img").array()) ?? [] {
            let src = ((try? image.attr("src")) ?? "").lowercased()
            if !(src.hasPrefix("https://") || src.hasPrefix("http://")) { try? image.remove() }
        }
    }

    private static func isHeading(_ element: Element, repeating label: String) -> Bool {
        guard ["h1", "h2", "h3", "h4", "h5", "h6"].contains(element.tagName().lowercased()) else { return false }
        let text = ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text == label.lowercased()
    }

    private static func headingText(in body: Element) -> String? {
        guard let heading = try? body.select("h1, h2, h3").first(),
              let text = try? heading.text().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }

    // MARK: - AO3's preface

    /// The tags and stats AO3 prints at the top of every download as a
    /// `<dl>` of "Rating:", "Fandom:", "Stats:" … pairs, read by their labels
    /// rather than class names, which e-book converters rename.
    struct AO3Preface {
        var title: String?
        var author: String?
        var authorUsername = ""
        var summaryHTML: String?
        /// The work's beginning notes, which open the first chapter.
        var notesHTML: String?
        var rating: String?
        var warnings: [String] = []
        var categories: [String] = []
        var fandoms: [String] = []
        var relationships: [String] = []
        var characters: [String] = []
        var freeforms: [String] = []
        var language: String?
        var words: Int?
        var totalChapters: Int?
        var isComplete: Bool?
        var publishedAt: Date?
        var updatedAt: Date?
        private(set) var isEmpty = true

        init() {}

        init(document: Document) {
            for dt in (try? document.select("dt").array()) ?? [] {
                guard let dd = try? dt.nextElementSibling(), dd.tagName().lowercased() == "dd" else { continue }
                let label = ((try? dt.text()) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines)).lowercased()
                let links = ((try? dd.select("a").array()) ?? []).compactMap { try? $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let text = ((try? dd.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let values = links.isEmpty ? text.components(separatedBy: ", ").filter { !$0.isEmpty } : links
                switch label {
                case "rating", "ratings": rating = values.first
                case "archive warning", "archive warnings", "warning", "warnings": warnings = values
                case "category", "categories": categories = values
                case "fandom", "fandoms": fandoms = values
                case "relationship", "relationships": relationships = values
                case "character", "characters": characters = values
                case "additional tags", "additional tag", "freeforms": freeforms = values
                case "language": language = text.isEmpty ? nil : text
                case "stats": readStats(text)
                default: continue
                }
                isEmpty = false
            }
            guard !isEmpty else { return }
            if let byline = try? document.select("a[rel=author]").array(), !byline.isEmpty {
                author = byline.compactMap { try? $0.text() }.joined(separator: ", ")
                authorUsername = SearchResultsParser.authorLogin(fromHref: (try? byline[0].attr("href")) ?? "")
            }
            title = try? document.select("h1").first()?.text()
            // "Summary" and "Notes" are paragraphs of their own, each followed
            // by a blockquote.
            for label in (try? document.select("p, b, strong, h2, h3").array()) ?? [] {
                let name = ((try? label.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard (name == "Summary" && summaryHTML == nil) || (name == "Notes" && notesHTML == nil) else { continue }
                var next = try? label.nextElementSibling()
                if next == nil { next = try? label.parent()?.nextElementSibling() }
                guard let next, next.tagName().lowercased() == "blockquote" else { continue }
                if name == "Summary" { summaryHTML = try? next.html() } else { notesHTML = try? next.html() }
            }
        }

        private mutating func readStats(_ text: String) {
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.timeZone = TimeZone(identifier: "UTC")
            date.dateFormat = "yyyy-MM-dd"
            publishedAt = EPUBImport.firstMatch(#"Published:\s*(\d{4}-\d{2}-\d{2})"#, in: text).flatMap(date.date(from:))
            let completed = EPUBImport.firstMatch(#"Completed:\s*(\d{4}-\d{2}-\d{2})"#, in: text).flatMap(date.date(from:))
            updatedAt = EPUBImport.firstMatch(#"Updated:\s*(\d{4}-\d{2}-\d{2})"#, in: text).flatMap(date.date(from:)) ?? completed
            words = EPUBImport.firstMatch(#"Words:\s*([\d,]+)"#, in: text).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
            if let chapters = EPUBImport.firstMatch(#"Chapters:\s*(\d+/[\d?]+)"#, in: text) {
                let parts = chapters.split(separator: "/")
                let posted = Int(parts[0])
                totalChapters = parts.count > 1 ? Int(parts[1]) : nil
                isComplete = completed != nil || (totalChapters != nil && posted == totalChapters)
            } else if completed != nil {
                isComplete = true
            }
        }
    }

    // MARK: - Helpers

    /// XHTML lets any element close itself (`<a id="x"/>`, `<title/>`), but
    /// an HTML parser reads that as an opening tag and swallows what follows.
    /// Spells those out as an opening and closing tag; void elements stay.
    static func expandSelfClosingTags(_ html: String) -> String {
        let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        guard let regex = try? NSRegularExpression(pattern: #"<([A-Za-z][\w:.-]*)((?:\s[^<>]*?)?)\s*/>"#) else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1))
            guard !void.contains(tag.lowercased()) else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += "<\(tag)\(ns.substring(with: match.range(at: 2)))></\(tag)>"
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func summaryHTML(from description: String) -> String {
        description.contains("<") ? description : description
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "<p>\(escape($0))</p>" }.joined()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func localName(_ element: Element) -> String {
        let name = element.tagName()
        return name.split(separator: ":").last.map(String.init) ?? name
    }

    /// Elements by local name, whatever namespace prefix the file uses
    /// (`dc:title`, `opf:item`, or none).
    private static func elements(named name: String, in doc: Document) -> [Element] {
        ((try? doc.getAllElements().array()) ?? []).filter { localName($0).caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// A manifest or link `href` as a path inside the zip.
    static func resolve(_ href: String, against base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var parts: [Substring] = []
        for part in (base + decoded).split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// Just enough of the ZIP format to read an EPUB: the central directory,
/// stored entries and deflated ones. No ZIP64, encryption or spanning,
/// which e-books don't use.
struct ZipFile {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    private let bytes: [UInt8]
    private var entries: [String: Entry] = [:]

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22, bytes[0] == 0x50, bytes[1] == 0x4B else { throw EPUBImport.ImportError.notAnEPUB }
        // The end-of-central-directory record, searched for from the end (a
        // comment of up to 64 KB can follow it).
        var eocd = -1
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while i >= floor {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw EPUBImport.ImportError.damaged("no zip directory") }
        let count = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4B50 else {
                throw EPUBImport.ImportError.damaged("bad zip directory")
            }
            let nameLength = Int(u16(offset + 28))
            let extraLength = Int(u16(offset + 30))
            let commentLength = Int(u16(offset + 32))
            guard offset + 46 + nameLength <= bytes.count else { throw EPUBImport.ImportError.damaged("bad zip directory") }
            let nameBytes = bytes[(offset + 46)..<(offset + 46 + nameLength)]
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            entries[name] = Entry(method: u16(offset + 10),
                                  compressedSize: Int(u32(offset + 20)),
                                  size: Int(u32(offset + 24)),
                                  headerOffset: Int(u32(offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    /// An entry's text, or nil when the book has no such file. Paths match
    /// exactly, then ignoring case (some tools change the case of hrefs).
    func text(_ path: String) throws -> String? {
        guard let contents = try data(path) else { return nil }
        return String(data: contents, encoding: .utf8) ?? String(data: contents, encoding: .isoLatin1)
    }

    func data(_ path: String) throws -> Data? {
        let key: String? = entries[path] != nil
            ? path
            : entries.keys.first(where: { $0.caseInsensitiveCompare(path) == .orderedSame })
        guard let key, let entry = entries[key] else { return nil }
        let header = entry.headerOffset
        guard header + 30 <= bytes.count, u32(header) == 0x0403_4B50 else {
            throw EPUBImport.ImportError.damaged("bad zip entry")
        }
        let start = header + 30 + Int(u16(header + 26)) + Int(u16(header + 28))
        guard start + entry.compressedSize <= bytes.count else { throw EPUBImport.ImportError.damaged("truncated file") }
        let compressed = Array(bytes[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            return try Self.inflate(compressed, size: entry.size)
        default:
            throw EPUBImport.ImportError.damaged("unsupported compression")
        }
    }

    /// Raw DEFLATE (what zip method 8 stores) to `size` bytes.
    private static func inflate(_ input: [UInt8], size: Int) throws -> Data {
        guard size > 0, !input.isEmpty else { return Data() }
        // A chapter is kilobytes; refuse anything absurd rather than allocate it.
        guard size <= 256 * 1024 * 1024 else { throw EPUBImport.ImportError.damaged("file too large") }
        #if canImport(Compression)
        var output = [UInt8](repeating: 0, count: size)
        let written = input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, size, src.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw EPUBImport.ImportError.damaged("couldn't decompress") }
        return Data(output)
        #else
        throw EPUBImport.ImportError.damaged("unsupported compression")
        #endif
    }

    private func u16(_ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private func u32(_ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

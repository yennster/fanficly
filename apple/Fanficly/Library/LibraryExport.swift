import Foundation
import SwiftData
import SwiftSoup
#if os(iOS)
import UIKit
#endif

/// Settings → Export All My Data (#417), part one: the library as a
/// spreadsheet. One row per saved work with its AO3 link, AO3's details and
/// what the reader added (progress, stars, folders, note, tags).
///
/// The file is UTF-8 with a byte order mark (so Excel reads non-English
/// titles), a header row, CRLF line ends and RFC 4180 quoting. Several values
/// in one cell are joined with "; ", dates are ISO 8601 in UTC, and yes/no
/// columns say `yes` or `no`. The Windows app's `LibraryCsv` writes the same
/// columns in the same order, so a file from either app looks the same.
///
/// It isn't the library file (Settings → Library File): that JSON is for
/// importing back. This one is for reading, sorting and other apps.
enum LibraryCSV {
    /// The columns, in order. The Windows app's `LibraryCsv.Columns` must
    /// match (both apps' tests pin this list).
    static let columns = [
        "ao3_url", "work_id", "title", "author", "author_url", "fandoms", "relationships",
        "characters", "additional_tags", "rating", "warnings", "categories", "language",
        "words", "chapters", "complete", "published", "updated", "kudos", "hits",
        "bookmarks", "comments", "summary", "saved_at", "last_read_at", "last_read_chapter",
        "progress_percent", "starred", "pinned", "following", "folders", "personal_tags",
        "note", "downloaded",
    ]

    /// Columns that hold text from AO3 or the reader. A cell in one of these
    /// that starts like a formula gets a leading apostrophe (see `guarded`).
    static let textColumns: Set<String> = [
        "title", "author", "fandoms", "relationships", "characters", "additional_tags",
        "rating", "warnings", "categories", "language", "summary", "folders",
        "personal_tags", "note",
    ]

    /// One work's cells, in `columns` order.
    @MainActor
    static func row(for work: Work, downloaded: Bool? = nil) -> [String] {
        let id = work.ao3Id
        // Imported books (negative ids) aren't on AO3, so they have no link.
        let onAO3 = !EPUBImport.isLocalWork(id)
        let username = work.authorUsername.trimmingCharacters(in: .whitespaces)
        let folderNames = Set(work.folders.map(\.name) + (work.folder.map { [$0.name] } ?? []))
        let values: [String: String] = [
            "ao3_url": onAO3 ? "https://archiveofourown.org/works/\(id)" : "",
            "work_id": onAO3 ? String(id) : "",
            "title": work.title,
            "author": work.authorName,
            "author_url": onAO3 && !username.isEmpty
                ? "https://archiveofourown.org/users/\(username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username)"
                : "",
            "fandoms": list(work.fandoms),
            "relationships": list(work.relationships),
            "characters": list(work.characters),
            "additional_tags": list(work.freeforms),
            "rating": work.rating,
            "warnings": list(work.warnings),
            "categories": list(work.categories),
            "language": work.language,
            "words": String(work.wordCount),
            "chapters": "\(work.chapterCount)/\(work.totalChapters.map(String.init) ?? "?")",
            "complete": yesNo(work.isComplete),
            "published": date(work.publishedAt),
            "updated": date(work.updatedAt),
            "kudos": String(work.kudos),
            "hits": String(work.hits),
            "bookmarks": String(work.bookmarksCount),
            "comments": String(work.commentsCount),
            "summary": plainText(fromHTML: work.summary),
            "saved_at": date(work.savedAt),
            "last_read_at": date(work.lastReadAt),
            "last_read_chapter": work.lastReadChapter.map(String.init) ?? "",
            "progress_percent": percent(work.lastReadProgress),
            "starred": yesNo(work.isStarred),
            "pinned": yesNo(work.isPinned),
            "following": yesNo(work.isFollowed),
            // UTF-16 order, as the Windows app's ordinal sort.
            "folders": list(folderNames.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }),
            "personal_tags": list(work.personalTags),
            "note": work.note ?? "",
            "downloaded": yesNo(downloaded ?? WorkPersistence.isDownloaded(work)),
        ]
        return columns.map { values[$0] ?? "" }
    }

    /// The whole file's text, header first, without the byte order mark.
    static func text(rows: [[String]]) -> String {
        var lines = [columns.map(escape).joined(separator: ",")]
        for row in rows {
            lines.append(zip(columns, row).map { column, value in
                escape(textColumns.contains(column) ? guarded(value) : value)
            }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The file's bytes: a UTF-8 byte order mark, then `text(rows:)`.
    static func data(rows: [[String]]) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(text(rows: rows).utf8)
    }

    /// Every saved work, oldest saved first (the Library's own order on a
    /// fresh install), leaving out works waiting behind the Undo toast.
    @MainActor
    static func rows(in context: ModelContext) throws -> [[String]] {
        let works = try context.fetch(FetchDescriptor<Work>(sortBy: [SortDescriptor(\.savedAt)]))
        return works
            .filter { !UndoCenter.shared.isPending(UndoCenter.Key.work($0.ao3Id)) }
            .map { row(for: $0) }
    }

    /// "Fanficly Library 2026-11-23.csv", in the device's time zone.
    static func fileName(on date: Date = .now, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "Fanficly Library \(formatter.string(from: date)).csv"
    }

    /// Writes the spreadsheet to a temporary file for the share sheet.
    @MainActor
    static func writeTemporaryFile(context: ModelContext, now: Date = .now) throws -> URL {
        let rows = try rows(in: context)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(on: now))
        try data(rows: rows).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Cells

    /// RFC 4180: a field holding a comma, a quote or a line break is quoted,
    /// with its quotes doubled.
    static func escape(_ field: String) -> String {
        // By UTF-8 byte, not Character: "\r\n" is one Character, equal to
        // neither "\r" nor "\n".
        guard field.utf8.contains(where: { $0 == 0x2C || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A text cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage
    /// return gets a leading apostrophe, so a spreadsheet app shows it as text
    /// instead of running it as a formula (OWASP's CSV injection advice).
    /// Titles, tags and summaries come from AO3, where anyone can write them.
    static func guarded(_ value: String) -> String {
        guard let first = value.unicodeScalars.first,
              "=+-@\t\r".unicodeScalars.contains(first) else { return value }
        return "'" + value
    }

    static func list(_ values: [String]) -> String {
        values.joined(separator: "; ")
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    /// ISO 8601 in UTC, to the second ("2026-11-23T18:39:09Z"); "" for none.
    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// 0…1 progress as a whole percentage, 0–100; "" when never opened.
    static func percent(_ progress: Double?) -> String {
        guard let progress, progress.isFinite else { return "" }
        return String(Int((min(max(progress, 0), 1) * 100).rounded()))
    }

    /// AO3's summary HTML as plain text: a line break or the end of a
    /// paragraph starts a new line, tags go, entities are decoded, spaces in a
    /// line are collapsed and blank lines dropped. The Windows app's
    /// `LibraryCsv.PlainText` follows the same steps.
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n",
                                             options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</(p|div|li|blockquote|h[1-6])\s*>"#, with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        text = (try? Entities.unescape(text)) ?? text
        return text
            .components(separatedBy: .newlines)
            .map { line in
                line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Settings → Storage → Export All Downloaded EPUBs (#417), part two: one
/// EPUB per downloaded story, handed to the share sheet as separate files
/// (Save to Files, AirDrop, Books…).
///
/// Each file is the one Export → EPUB would make (#173): a copy of the saved
/// AO3 EPUB, or one `EPUBBuilder` makes from the saved chapter text, so it
/// works offline and never asks AO3. Files are named after the story, as a
/// single export names them; two stories with the same name get their work
/// id added ("Stay (12345).epub").
///
/// Separate files rather than one `.zip`: the share sheet takes many file
/// URLs on iPhone, iPad and Mac, Books can open them, and a zip would need the
/// whole library in memory (the EPUBs are written by hand, without a
/// streaming zip writer).
@Observable @MainActor
final class BulkEPUBExporter {
    struct Plan: Equatable {
        var workIds: [Int]
        var estimatedBytes: Int64
        var count: Int { workIds.count }
    }

    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    private(set) var progress: Progress?
    var shareURLs: [URL]?
    var errorMessage: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool { progress != nil }

    /// The downloaded stories (saved text or a saved EPUB), in title order,
    /// and roughly how much room their files take: a saved EPUB's size, or
    /// about 6 bytes a word for one built from the text.
    static func plan(in context: ModelContext, epubDirectory: URL? = WorkPersistence.epubDirectory()) -> Plan {
        let works = ((try? context.fetch(FetchDescriptor<Work>())) ?? [])
            .filter { !UndoCenter.shared.isPending(UndoCenter.Key.work($0.ao3Id)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var ids: [Int] = []
        var bytes: Int64 = 0
        for work in works {
            let saved = savedFile(workId: work.ao3Id, in: epubDirectory)
            guard saved != nil || WorkPersistence.isDownloaded(work) else { continue }
            ids.append(work.ao3Id)
            if let saved, let size = (try? saved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                bytes += Int64(size)
            } else {
                bytes += Int64(max(work.wordCount, 0)) * 6 + 8_000
            }
        }
        return Plan(workIds: ids, estimatedBytes: bytes)
    }

    /// File names for the stories, without ".epub": the story's name as a
    /// single export names it, with " (<id>)" added for every story whose
    /// name another one shares (ignoring case, as Files and Windows do).
    static func fileNames(_ works: [(id: Int, title: String)]) -> [Int: String] {
        let bases = works.map { work -> (Int, String) in
            let name = AO3Client.sanitizeFilename(work.title)
            return (work.id, name.isEmpty ? "work-\(work.id)" : name)
        }
        var counts: [String: Int] = [:]
        for (_, base) in bases { counts[base.lowercased(), default: 0] += 1 }
        var names: [Int: String] = [:]
        for (id, base) in bases {
            names[id] = counts[base.lowercased(), default: 0] > 1 ? "\(base) (\(id))" : base
        }
        return names
    }

    /// Starts writing the files. The share sheet opens (`shareURLs`) when all
    /// are written; Cancel stops it and shares nothing.
    func start(_ plan: Plan, context: ModelContext,
               epubDirectory: URL? = WorkPersistence.epubDirectory(),
               outputDirectory: URL? = nil) {
        guard !isRunning, !plan.workIds.isEmpty else { return }
        progress = Progress(done: 0, total: plan.count)
        announce("Exporting \(plan.count) EPUB \(plan.count == 1 ? "file" : "files"). The share sheet will open when they're ready.")
        task = Task { [weak self] in
            await self?.run(plan, context: context, epubDirectory: epubDirectory, outputDirectory: outputDirectory)
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Writes every file and returns their URLs (the work for `start`, and
    /// what the tests call). Stops early, returning nil, when cancelled.
    func export(_ plan: Plan, context: ModelContext,
                epubDirectory: URL? = WorkPersistence.epubDirectory(),
                outputDirectory: URL? = nil) async throws -> [URL]? {
        let dir = outputDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("All EPUBs", isDirectory: true)
        // A fresh folder, so an earlier export's files never go along.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let works = plan.workIds.compactMap { id -> Work? in
            let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == id })
            return (try? context.fetch(descriptor))?.first
        }
        let names = Self.fileNames(works.map { ($0.ao3Id, $0.title) })
        var urls: [URL] = []
        for work in works {
            if Task.isCancelled { return nil }
            let id = work.ao3Id
            let target = dir.appendingPathComponent("\(names[id] ?? "work-\(id)").epub")
            if let saved = Self.savedFile(workId: id, in: epubDirectory),
               (try? await Task.detached { try FileManager.default.copyItem(at: saved, to: target) }.value) != nil {
                urls.append(target)
            } else if WorkPersistence.isDownloaded(work) {
                // One book in memory at a time: read on the main actor, built
                // and written off it.
                let book = EPUBBuilder.book(from: work)
                try await Task.detached {
                    try EPUBBuilder.build(book).write(to: target, options: .atomic)
                }.value
                urls.append(target)
            }
            if progress != nil { progress?.done += 1 }
        }
        return Task.isCancelled ? nil : urls
    }

    private func run(_ plan: Plan, context: ModelContext, epubDirectory: URL?, outputDirectory: URL?) async {
        defer { progress = nil; task = nil }
        do {
            guard let urls = try await export(plan, context: context, epubDirectory: epubDirectory,
                                              outputDirectory: outputDirectory) else {
                announce("Export cancelled.")
                return
            }
            guard !urls.isEmpty else {
                errorMessage = String(localized: "There were no downloaded stories to export.")
                return
            }
            announce("\(urls.count) EPUB \(urls.count == 1 ? "file is" : "files are") ready to share.")
            shareURLs = urls
        } catch {
            errorMessage = String(localized: "Couldn't write the EPUB files. \(error.localizedDescription)")
        }
    }

    private static func savedFile(workId: Int, in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent("\(workId).epub")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func announce(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
        #endif
    }
}

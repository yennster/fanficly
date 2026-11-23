import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Imports EPUB files into the Library: from the Library's Import menu
/// (`epubImporter`: picked files, or a whole folder with its subfolders, #418)
/// or a file opened in Fanficly from Files, Books or Safari (`RootView`'s
/// `onOpenURL`). Parsing (`EPUBImport.parse`) runs off the main actor; saving
/// runs on it. The outcome is shown by `epubImportAlert()`, and a folder's
/// progress ("Importing 37 of 212…", Cancel) by its banner.
@MainActor
@Observable
final class EPUBImportCenter {
    static let shared = EPUBImportCenter()

    struct Outcome: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// What the Library's Import menu picks.
    enum Pick { case files, folder }

    /// A folder import's place: files read so far of the EPUBs found.
    struct FolderProgress: Equatable {
        var done: Int
        var total: Int
    }

    private(set) var isImporting = false
    /// Set while a folder import runs (nil otherwise); drives the banner.
    private(set) var folderProgress: FolderProgress?
    private var cancelRequested = false
    var outcome: Outcome?

    /// Imports each file in turn and returns the ids of the works saved.
    @discardableResult
    func importFiles(_ urls: [URL], context: ModelContext) async -> [Int] {
        guard !urls.isEmpty, !isImporting else { return [] }
        isImporting = true
        defer { isImporting = false }
        var saved: [(id: Int, title: String)] = []
        var failures: [String] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let data = try Self.read(url)
                let payload = try await Task.detached(priority: .userInitiated) {
                    try EPUBImport.parse(data: data)
                }.value
                let work = try Self.save(payload, epub: data, into: context)
                saved.append((work.ao3Id, work.title))
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if !saved.isEmpty {
            iCloudSyncManager.shared.queueBackup(context: context)
            WidgetDataStore.updateAll(context: context)
        }
        outcome = Self.outcome(saved: saved.map(\.title), failures: failures)
        return saved.map(\.id)
    }

    // MARK: - Folder import (#418)

    /// Stops a folder import after the file it's on. What it saved stays.
    func cancelFolderImport() {
        cancelRequested = true
    }

    /// Imports every `.epub` in a picked folder and its subfolders, one file
    /// at a time (so memory stays flat), with progress and Cancel. Two copies
    /// of one work keep the one with more chapters; a work already in the
    /// Library merges through `save`. Backup and widgets refresh once, at the end.
    func importFolder(_ folder: URL, context: ModelContext) async {
        guard !isImporting else { return }
        isImporting = true
        cancelRequested = false
        folderProgress = FolderProgress(done: 0, total: 0)
        defer {
            isImporting = false
            folderProgress = nil
        }
        // The folder's scope covers listing and reading every file under it.
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let found = await Task.detached(priority: .userInitiated) { Self.epubFiles(in: folder) }.value
        let result = await Self.importEPUBs(found, context: context,
                                            isCancelled: { [weak self] in self?.cancelRequested ?? true },
                                            progress: { [weak self] done, total in
                                                self?.reportProgress(done: done, total: total)
                                            })
        if result.imported + result.updated > 0 {
            iCloudSyncManager.shared.queueBackup(context: context)
            WidgetDataStore.updateAll(context: context)
        }
        // VoiceOver reads the alert itself.
        outcome = Self.folderOutcome(result)
    }

    private func reportProgress(done: Int, total: Int) {
        let previous = folderProgress?.done ?? 0
        folderProgress = FolderProgress(done: done, total: total)
        // VoiceOver hears the count at the start and every tenth of the way.
        if total > 0 && (done == 0 || (total >= 10 && done * 10 / total > previous * 10 / total && done < total)) {
            announce(String(localized: "Importing \(done) of \(total)"))
        }
    }

    private func announce(_ text: String) {
        guard !FanficlyApp.isTestMode else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// What a folder import did: new works, works already in the Library that
    /// it updated, extra copies of a work it skipped, and files it couldn't read.
    struct FolderResult: Equatable {
        var found = 0
        var processed = 0
        var imported = 0
        var updated = 0
        var skipped = 0
        var failures: [String] = []
        var cancelled = false
        var savedIds: [Int] = []
    }

    /// Decides which copy of each work a folder import keeps and counts the
    /// outcome. Pure, so the rules are tested without files.
    struct FolderTally {
        private(set) var result = FolderResult()
        /// The copy kept for each work id so far: its chapter count, and
        /// whether this import added the work (rather than updating one).
        private var kept: [Int: (chapters: Int, added: Bool)] = [:]

        /// Whether this copy should be saved: the first copy of a work, or a
        /// later one with more chapters than the copy already kept.
        func shouldSave(workId: Int, chapters: Int) -> Bool {
            guard let previous = kept[workId] else { return true }
            return chapters > previous.chapters
        }

        /// Whether a better copy of this work should replace the details too:
        /// this import added the work from an earlier copy, so those details
        /// are only that copy's, not ones the Library had.
        func replacesDetails(workId: Int) -> Bool {
            kept[workId]?.added == true
        }

        /// A copy was saved. A later copy that replaced an earlier one leaves
        /// that one skipped; otherwise it's new or an update.
        mutating func saved(workId: Int, chapters: Int, wasInLibrary: Bool) {
            if let previous = kept[workId] {
                result.skipped += 1
                kept[workId] = (chapters, previous.added)
                return
            }
            if wasInLibrary {
                result.updated += 1
                result.savedIds.append(workId)
            } else {
                result.imported += 1
                result.savedIds.append(workId)
            }
            kept[workId] = (chapters, !wasInLibrary)
        }

        mutating func skippedCopy() { result.skipped += 1 }
        mutating func failed(_ message: String) { result.failures.append(message) }
        mutating func processedOne() { result.processed += 1 }
        mutating func setFound(_ count: Int) { result.found = count }
        mutating func setCancelled() { result.cancelled = true }
    }

    /// Reads, parses and saves each file in turn (parsing off the main actor),
    /// checking `isCancelled` between files. No backup or widget refresh: the caller does that once.
    static func importEPUBs(_ urls: [URL], context: ModelContext,
                            isCancelled: () -> Bool = { false },
                            progress: (Int, Int) -> Void = { _, _ in }) async -> FolderResult {
        var tally = FolderTally()
        tally.setFound(urls.count)
        progress(0, urls.count)
        for (offset, url) in urls.enumerated() {
            if isCancelled() {
                tally.setCancelled()
                break
            }
            let name = url.lastPathComponent
            do {
                let (data, payload) = try await Task.detached(priority: .userInitiated) {
                    let data = try Self.readDownloading(url)
                    return (data, try EPUBImport.parse(data: data))
                }.value
                let id = payload.summary.id
                if tally.shouldSave(workId: id, chapters: payload.chapters.count) {
                    let inLibrary = (try? context.fetchCount(FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == id }))) ?? 0
                    let wasInLibrary = inLibrary > 0
                    // Importing a work deleted a moment ago keeps it (#169).
                    UndoCenter.shared.cancel(UndoCenter.Key.work(id))
                    _ = try save(payload, epub: data, into: context,
                                 replacingDetails: tally.replacesDetails(workId: id))
                    tally.saved(workId: id, chapters: payload.chapters.count, wasInLibrary: wasInLibrary)
                } else {
                    tally.skippedCopy()
                }
            } catch {
                tally.failed("\(name): \(error.localizedDescription)")
            }
            tally.processedOne()
            progress(offset + 1, urls.count)
        }
        return tally.result
    }

    /// Every `.epub` file in `folder` and its subfolders, in name order. Other
    /// files are left out. An iCloud file not downloaded yet (listed as
    /// `.Name.epub.icloud`) is returned under its real name;
    /// `readDownloading` downloads it.
    nonisolated static func epubFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true })
        else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let lower = name.lowercased()
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                // An unpacked .epub package (Apple Books keeps some that way)
                // isn't a file Fanficly can read; don't look inside it.
                if lower.hasSuffix(".epub") || name.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            if name.hasPrefix(".") {
                if lower.hasSuffix(".epub.icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    found.append(url.deletingLastPathComponent().appendingPathComponent(real))
                }
                continue
            }
            if lower.hasSuffix(".epub") { found.append(url) }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Whether a picked URL is a folder (asked inside its security scope).
    nonisolated static func isFolder(_ url: URL) -> Bool {
        if url.hasDirectoryPath { return true }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Reads a file through `NSFileCoordinator`, which downloads an iCloud
    /// file that's only in the cloud before handing it over.
    nonisolated static func readDownloading(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// How many failures the outcome names before summing up the rest.
    static let listedFailures = 5

    /// The alert a folder import ends with.
    static func folderOutcome(_ r: FolderResult) -> Outcome {
        if r.found == 0 {
            return Outcome(title: String(localized: "No EPUBs found"),
                           message: String(localized: "That folder and its subfolders have no EPUB files."))
        }
        let kept = r.imported + r.updated
        let title: String
        if r.cancelled {
            title = String(localized: "Import stopped")
        } else if kept == 0 && !r.failures.isEmpty {
            title = String(localized: "Couldn't import")
        } else {
            title = String(localized: "Imported")
        }
        var lines: [String] = []
        if r.cancelled {
            lines.append(String(localized: "Stopped after \(r.processed) of \(r.found) files. What was imported stays in your Library."))
        }
        if r.imported > 0 {
            lines.append(r.imported == 1
                ? String(localized: "1 new story added to your Library.")
                : String(localized: "\(r.imported) new stories added to your Library."))
        }
        if r.updated > 0 {
            lines.append(r.updated == 1
                ? String(localized: "1 story already in your Library updated.")
                : String(localized: "\(r.updated) stories already in your Library updated."))
        }
        if r.skipped > 0 {
            lines.append(r.skipped == 1
                ? String(localized: "1 extra copy of a story skipped.")
                : String(localized: "\(r.skipped) extra copies of stories skipped."))
        }
        if !r.failures.isEmpty {
            lines.append(r.failures.count == 1
                ? String(localized: "1 file couldn't be imported:")
                : String(localized: "\(r.failures.count) files couldn't be imported:"))
            lines.append(contentsOf: r.failures.prefix(listedFailures))
            let rest = r.failures.count - listedFailures
            if rest > 0 {
                lines.append(rest == 1 ? String(localized: "…and 1 more.") : String(localized: "…and \(rest) more."))
            }
        }
        if kept == 0 && r.failures.isEmpty && !r.cancelled {
            lines.append(String(localized: "Nothing new to add."))
        }
        return Outcome(title: title, message: lines.joined(separator: "\n"))
    }

    static func outcome(saved: [String], failures: [String]) -> Outcome {
        let failed = failures.joined(separator: "\n")
        switch (saved.count, failures.isEmpty) {
        case (0, _):
            return Outcome(title: String(localized: "Couldn't import"), message: failed)
        case (1, true):
            return Outcome(title: String(localized: "Imported"),
                           message: String(localized: "“\(saved[0])” is in your Library and reads offline."))
        case (_, true):
            return Outcome(title: String(localized: "Imported"),
                           message: String(localized: "\(saved.count) stories are in your Library and read offline."))
        default:
            return Outcome(title: String(localized: "Imported \(saved.count) of \(saved.count + failures.count)"),
                           message: failed)
        }
    }

    /// Reads a picked or opened file, which may sit outside the sandbox.
    private static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        // A file opened from another app arrives as a copy in Documents/Inbox;
        // the Library keeps its own copy, so that one goes.
        if let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
           url.deletingLastPathComponent().standardizedFileURL == docs.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        return data
    }

    /// Saves an imported book to the Library, with the file kept as the
    /// work's EPUB so it shows as Downloaded. A work already in the Library
    /// (an AO3 book) keeps its AO3 details and reading position and takes
    /// the book's chapters, unless it already holds more of them; a new one gets the book's details too.
    /// `replacingDetails` (a folder import's better copy of a work it added
    /// from another copy) takes the book's details as for a new work.
    static func save(_ payload: AO3WorkPayload, epub data: Data, into context: ModelContext,
                     replacingDetails: Bool = false) throws -> Work {
        let id = payload.summary.id
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == id })
        let work: Work
        if !replacingDetails, let existing = try? context.fetch(descriptor).first {
            work = existing
            // An older download with fewer chapters never replaces more text
            // (AO3 may not be there to download it again).
            if payload.chapters.count >= work.chapters.count {
                for chapter in work.chapters { context.delete(chapter) }
                work.chapters.removeAll()
                for ch in payload.chapters {
                    context.insert(Chapter(work: work, index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML, aoId: ch.aoId))
                }
            }
            if work.wordCount == 0 { work.wordCount = payload.summary.wordCount }
            work.chapterCount = max(work.chapterCount, payload.chapters.count)
            try context.save()
        } else {
            work = WorkPersistence.upsert(payload: payload, into: context)
        }

        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("\(id).epub"), options: .atomic)
        return work
    }
}

extension View {
    /// The Library's file picker: EPUB files, or a folder of them (#418).
    /// Picked folders are imported with their subfolders; picked files as they are.
    func epubImporter(picking: Binding<EPUBImportCenter.Pick?>, context: ModelContext) -> some View {
        let folder = picking.wrappedValue == .folder
        return fileImporter(isPresented: Binding(get: { picking.wrappedValue != nil },
                                                 set: { if !$0 { picking.wrappedValue = nil } }),
                            allowedContentTypes: folder ? [.folder] : [.epub],
                            allowsMultipleSelection: !folder) { result in
            guard case .success(let urls) = result else { return }
            // Decided by what came back, not the menu item, since the picker's
            // binding is already cleared when this runs.
            let folders = urls.filter(EPUBImportCenter.isFolder)
            let files = urls.filter { !EPUBImportCenter.isFolder($0) }
            Task {
                if let first = folders.first {
                    await EPUBImportCenter.shared.importFolder(first, context: context)
                } else {
                    await EPUBImportCenter.shared.importFiles(files, context: context)
                }
            }
        }
    }

    /// Shows how an EPUB import went, and a folder import's progress.
    func epubImportAlert() -> some View {
        modifier(EPUBImportAlert())
    }
}

/// "Importing 37 of 212…" with Cancel while a folder import runs.
private struct EPUBFolderImportBanner: View {
    let center: EPUBImportCenter

    var body: some View {
        if let p = center.folderProgress {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.total == 0 ? "Looking for EPUB files…" : "Importing \(p.done) of \(p.total)…")
                        .font(.footnote.weight(.semibold))
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .progressViewStyle(.linear)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.total == 0 ? "Looking for EPUB files" : "Importing EPUBs, \(p.done) of \(p.total) done")
                Button("Cancel") { center.cancelFolderImport() }
                    .font(.footnote.weight(.semibold))
                    .accessibilityHint("Stops the import. Stories already imported stay in your Library.")
            }
            .padding(14)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct EPUBImportAlert: ViewModifier {
    @State private var center = EPUBImportCenter.shared

    func body(content: Content) -> some View {
        content.alert(
            center.outcome?.title ?? "",
            isPresented: Binding(get: { center.outcome != nil }, set: { if !$0 { center.outcome = nil } }),
            presenting: center.outcome
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { outcome in
            Text(outcome.message)
        }
        .overlay(alignment: .bottom) {
            EPUBFolderImportBanner(center: center)
                .animation(.easeInOut(duration: 0.25), value: center.folderProgress)
        }
    }
}

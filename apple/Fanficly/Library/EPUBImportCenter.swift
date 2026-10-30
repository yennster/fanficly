import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Imports EPUB files into the Library: from the Library's Import button
/// (`epubImporter`) or a file opened in Fanficly from Files, Books or Safari
/// (`RootView`'s `onOpenURL`). Parsing (`EPUBImport.parse`) runs off the main
/// actor; saving runs on it. The outcome is shown by `epubImportAlert()`.
@MainActor
@Observable
final class EPUBImportCenter {
    static let shared = EPUBImportCenter()

    struct Outcome: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var isImporting = false
    var outcome: Outcome?

    /// Imports each file in turn and returns the ids of the works saved.
    @discardableResult
    func importFiles(_ urls: [URL], context: ModelContext) async -> [Int] {
        guard !urls.isEmpty else { return [] }
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
        return try Data(contentsOf: url)
    }

    /// Saves an imported book to the Library, with the file kept as the
    /// work's EPUB so it shows as Downloaded. A work already in the Library
    /// (an AO3 book) keeps its AO3 details and reading position and takes
    /// the book's chapters; a new one gets the book's details too.
    static func save(_ payload: AO3WorkPayload, epub data: Data, into context: ModelContext) throws -> Work {
        let id = payload.summary.id
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == id })
        let work: Work
        if let existing = try? context.fetch(descriptor).first {
            work = existing
            for chapter in work.chapters { context.delete(chapter) }
            work.chapters.removeAll()
            for ch in payload.chapters {
                context.insert(Chapter(work: work, index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML, aoId: ch.aoId))
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
    /// The Library's file picker for EPUBs; picked files are imported.
    func epubImporter(isPresented: Binding<Bool>, context: ModelContext) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.epub],
                     allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await EPUBImportCenter.shared.importFiles(urls, context: context) }
        }
    }

    /// Shows how an EPUB import went.
    func epubImportAlert() -> some View {
        modifier(EPUBImportAlert())
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
    }
}

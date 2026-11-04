import SwiftUI
import SwiftData
import UIKit

/// Drives a work export: downloads the work in the chosen AO3 format and holds
/// the resulting file so the presenting screen can hand it to the share sheet.
/// EPUB never needs AO3 for a story saved on this device (#173): it shares
/// the saved AO3 EPUB, or builds one from the saved chapter text
/// (`EPUBBuilder`), so it works offline. The other formats always download.
///
/// The exporter (and the `.workExportPresentation` modifier that renders its
/// sheet/alert) must be owned by the stable screen view, never by a view inside
/// a `Menu`'s content: menu content is torn down when the menu dismisses, so a
/// `.sheet` attached there has no live anchor by the time the download finishes
/// and silently never presents — VoiceOver users hit this every time (the menu
/// dismisses slower under VoiceOver) and reported "the dialog disappears and
/// nothing happens".
@Observable @MainActor
final class WorkExporter {
    var isExporting = false
    var shareItem: ShareItem?
    var errorMessage: String?

    func export(workId: Int, title: String, format: WorkExportFormat,
                client: any AO3ClientProtocol, context: ModelContext? = nil) async {
        if format == .epub, let context, let url = await savedEPUB(workId: workId, title: title, context: context) {
            shareItem = ShareItem(url: url)
            return
        }
        isExporting = true
        defer { isExporting = false }
        // The menu has already dismissed and the download can take several
        // seconds (AO3 throttle), so tell VoiceOver users something is
        // happening; queued so the menu-dismissal speech doesn't clobber it.
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: "Downloading \(format.displayName). The share sheet will open when it's ready.",
            attributes: [.accessibilitySpeechQueueAnnouncement: true]))
        do {
            let url = try await client.exportWork(workId: workId, format: format, filename: title)
            shareItem = ShareItem(url: url)
        } catch {
            errorMessage = "Couldn't download the \(format.displayName) file. \(error.localizedDescription)"
        }
    }

    /// An EPUB of a story saved on this device, without AO3: a copy of the
    /// saved AO3 file named after the story, or one built from the saved
    /// text (off the main actor: a long work takes a moment). Nil when the
    /// story isn't saved (no text), or the file couldn't be written, so
    /// Export downloads. The saved file is never older than the text:
    /// saving or restoring new text deletes it.
    private func savedEPUB(workId: Int, title: String, context: ModelContext) async -> URL? {
        if let saved = WorkPersistence.epubURL(workId: workId),
           let copy = try? Self.shareableCopy(of: saved, title: title, workId: workId) {
            return copy
        }
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == workId })
        guard let work = (try? context.fetch(descriptor))?.first,
              WorkPersistence.isDownloaded(work) else { return nil }
        let book = EPUBBuilder.book(from: work)
        isExporting = true
        defer { isExporting = false }
        return try? await Task.detached { try EPUBBuilder.writeTemporaryFile(book) }.value
    }

    /// The saved file is `<id>.epub`; the share sheet should offer the
    /// story's title, as a download does, and never hand out the library's
    /// own copy.
    private static func shareableCopy(of saved: URL, title: String, workId: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = AO3Client.sanitizeFilename(title)
        let url = dir.appendingPathComponent("\(name.isEmpty ? "work-\(workId)" : name).epub")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: saved, to: url)
        return url
    }
}

/// Reusable export/share control — a submenu of AO3 download formats. Embed it
/// in a toolbar or an overflow `Menu`, pass the screen's `WorkExporter`, and
/// attach `.workExportPresentation(exporter)` to the screen itself.
struct WorkExportButton: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    let workId: Int
    let title: String
    let exporter: WorkExporter
    var useTextLabel: Bool = false

    var body: some View {
        Menu {
            Section("Export & share") {
                ForEach(WorkExportFormat.allCases) { format in
                    Button {
                        let client = client
                        let context = context
                        Task {
                            await exporter.export(workId: workId, title: title,
                                                  format: format, client: client, context: context)
                        }
                    } label: {
                        Label(format.displayName, systemImage: format.icon)
                    }
                }
            }
        } label: {
            if exporter.isExporting {
                ProgressView()
            } else {
                if useTextLabel {
                    Label("Share & export...", systemImage: "square.and.arrow.up")
                } else {
                    Label("Share and export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .disabled(exporter.isExporting)
        .accessibilityLabel("Share and export")
    }
}

private struct WorkExportPresentation: ViewModifier {
    @Bindable var exporter: WorkExporter

    func body(content: Content) -> some View {
        content
            .sheet(item: $exporter.shareItem) { ShareSheet(items: [$0.url]) }
            .alert("Export failed", isPresented: Binding(
                get: { exporter.errorMessage != nil },
                set: { if !$0 { exporter.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exporter.errorMessage ?? "")
            }
    }
}

extension View {
    /// Presents the share sheet / error alert for a `WorkExporter`. Attach to
    /// the screen view that owns the exporter — never inside `Menu` content.
    func workExportPresentation(_ exporter: WorkExporter) -> some View {
        modifier(WorkExportPresentation(exporter: exporter))
    }
}

import Foundation
import SwiftData
import SwiftUI
import UIKit

/// The Library row menu's Download for Offline (#191): which works are
/// downloading from a row right now, so the menu shows "Downloading…" for
/// them instead of a second Download, and their rows re-render (with the
/// Downloaded badge) when each one ends. Folder Download All runs through
/// `RestoreDownloadCenter` instead.
@Observable @MainActor
final class LibraryDownloads {
    static let shared = LibraryDownloads()

    private(set) var inFlight: Set<Int> = []

    func isDownloading(_ ao3Id: Int) -> Bool { inFlight.contains(ao3Id) }

    /// Saves the work for offline reading (`WorkPersistence.saveOffline`).
    /// Returns nil when it worked (or was already running), or the message
    /// to show when it didn't.
    func download(_ work: Work, client: any AO3ClientProtocol, context: ModelContext) async -> String? {
        let id = work.ao3Id
        let title = work.title
        guard inFlight.insert(id).inserted else { return nil }
        defer { inFlight.remove(id) }
        Self.announce(String(localized: "Downloading \(title) for offline reading"))
        let hadText = !work.chapters.isEmpty
        do {
            guard try await WorkPersistence.saveOffline(workId: id, client: client, context: context) else { return nil }
        } catch {
            let textSaved = hadText || (!work.isDeleted && work.modelContext != nil && !work.chapters.isEmpty)
            return textSaved
                ? String(localized: "The text is saved for offline reading, but the EPUB download failed: \(error.localizedDescription)")
                : String(localized: "Couldn't get the story's text from AO3, so nothing was saved: \(error.localizedDescription)")
        }
        Self.announce(String(localized: "Downloaded \(title) for offline reading"))
        return nil
    }

    static func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
    }
}

/// The row menu's download item (#191), shared by the Library and folder
/// screens: Download for Offline, Downloading… while it runs, or Remove
/// Download once the EPUB is here. An imported book that isn't on AO3 gets
/// none: its text is all there is. The screens own the confirmation and the
/// error alert, since a context menu's own views are gone once it closes.
struct LibraryDownloadMenuItem: View {
    let work: Work
    let download: () -> Void
    let removeDownload: () -> Void

    var body: some View {
        if EPUBImport.isLocalWork(work.ao3Id) {
            EmptyView()
        } else if LibraryDownloads.shared.isDownloading(work.ao3Id) {
            Button {} label: {
                Label("Downloading…", systemImage: "arrow.down.circle")
            }
            .disabled(true)
        } else if WorkPersistence.epubURL(workId: work.ao3Id) != nil {
            Button(action: removeDownload) {
                Label("Remove Download", systemImage: "xmark.circle")
            }
        } else {
            Button(action: download) {
                Label("Download", systemImage: "arrow.down.circle")
            }
            // A folder's Download All (or the restore's re-download) may
            // have this work queued: one download at a time, never twice.
            .disabled(RestoreDownloadCenter.shared.progress.map { !$0.finished } ?? false)
        }
    }
}

extension View {
    /// The screen half of the row menu's download item: the Remove Download
    /// confirmation and the alert when a download fails.
    func libraryDownloadAlerts(removing: Binding<Work?>, error: Binding<String?>,
                               context: ModelContext) -> some View {
        confirmationDialog(
            removing.wrappedValue.map { String(localized: "Remove the download of “\($0.title)”?") } ?? "",
            isPresented: Binding(get: { removing.wrappedValue != nil },
                                 set: { if !$0 { removing.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: removing.wrappedValue
        ) { work in
            Button("Remove Download", role: .destructive) {
                guard !work.isDeleted, work.modelContext != nil else { return }
                let title = work.title
                WorkPersistence.removeDownload(work, in: context)
                iCloudSyncManager.shared.queueBackup(context: context)
                LibraryDownloads.announce(String(localized: "Removed the download of \(title)"))
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The story stays in your Library and loads from AO3 when you read it.")
        }
        .alert("Couldn't Download for Offline", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}

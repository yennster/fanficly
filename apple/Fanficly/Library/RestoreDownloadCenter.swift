import Foundation
import SwiftData
import SwiftUI
import UIKit

/// After an iCloud restore, offers to re-download the EPUB files for works
/// that were saved offline on the old device. Chapter text rides in the
/// backup, but the EPUB files themselves don't — so a restored library reads
/// offline yet loses its Downloaded state (and export copies) until the
/// files are fetched again. Any restore path (launch auto-sync, Settings)
/// calls `proposeRedownload`; `RootView` renders the prompt and the progress
/// banner via `.restoreRedownloadUI()`. Downloads are cancellable at any
/// point — the restored library data is already saved and unaffected.
@Observable @MainActor
final class RestoreDownloadCenter {
    static let shared = RestoreDownloadCenter()

    struct Progress: Equatable {
        var done: Int
        var failed: Int
        var total: Int
        var finished: Bool
    }

    /// Non-nil while the "re-download?" prompt should show.
    private(set) var proposedIds: [Int]?
    /// Non-nil while downloads run (or briefly after, `finished == true`).
    private(set) var progress: Progress?
    private var lastProposal: [Int] = []
    private var downloadTask: Task<Void, Never>?

    /// Works whose offline text was restored but whose EPUB file is missing
    /// locally — i.e. they were downloaded on the device that made the backup.
    static func redownloadCandidates(in context: ModelContext) -> [Int] {
        let works = (try? context.fetch(FetchDescriptor<Work>())) ?? []
        return works
            .filter { !$0.chapters.isEmpty && WorkPersistence.epubURL(workId: $0.ao3Id) == nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map(\.ao3Id)
    }

    func proposeRedownload(context: ModelContext) {
        guard downloadTask == nil, progress == nil, proposedIds == nil else { return }
        let ids = Self.redownloadCandidates(in: context)
        guard !ids.isEmpty else { return }
        lastProposal = ids
        proposedIds = ids
    }

    func dismissProposal() {
        proposedIds = nil
    }

    /// Kicks off sequential EPUB downloads (the AO3 throttle spaces them out
    /// anyway). Reads the snapshot taken at proposal time, so it works no
    /// matter whether the alert clears its binding before or after the
    /// button action runs.
    func startDownloads(client: any AO3ClientProtocol) {
        let ids = lastProposal
        guard !ids.isEmpty, downloadTask == nil else { return }
        proposedIds = nil
        lastProposal = []
        progress = Progress(done: 0, failed: 0, total: ids.count, finished: false)
        UIAccessibility.post(notification: .announcement,
                             argument: "Downloading \(ids.count) stories for offline reading.")
        downloadTask = Task {
            var done = 0
            var failed = 0
            for id in ids {
                if Task.isCancelled { break }
                do {
                    _ = try await client.downloadEPUB(workId: id)
                    done += 1
                } catch is CancellationError {
                    break
                } catch {
                    // Skip and move on — a deleted work mustn't stall the rest.
                    failed += 1
                }
                if Task.isCancelled { break }
                progress = Progress(done: done, failed: failed, total: ids.count, finished: false)
            }
            if Task.isCancelled { return }
            downloadTask = nil
            progress = Progress(done: done, failed: failed, total: ids.count, finished: true)
            UIAccessibility.post(notification: .announcement, argument: failed == 0
                ? "Downloaded \(done) stories for offline reading."
                : "Downloads finished. \(done) succeeded, \(failed) failed.")
            try? await Task.sleep(for: .seconds(4))
            if progress?.finished == true { progress = nil }
        }
    }

    /// Stops the downloads; everything already restored (and already
    /// downloaded) stays.
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        progress = nil
        UIAccessibility.post(notification: .announcement,
                             argument: "Downloads canceled. Your restored library is unaffected.")
    }
}

/// The floating progress card: spinner while running, x/total bar, Cancel.
private struct RestoreDownloadBanner: View {
    let center: RestoreDownloadCenter

    var body: some View {
        if let p = center.progress {
            HStack(spacing: 12) {
                if p.finished {
                    Image(systemName: p.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(p.failed == 0 ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.finished
                         ? (p.failed == 0 ? "Downloaded \(p.done) stories"
                                          : "Downloaded \(p.done) of \(p.total) stories")
                         : "Downloading stories… \(p.done) of \(p.total)")
                        .font(.footnote.weight(.semibold))
                    ProgressView(value: Double(p.done + p.failed), total: Double(max(p.total, 1)))
                        .progressViewStyle(.linear)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.finished
                    ? "Downloaded \(p.done) of \(p.total) stories"
                    : "Downloading stories, \(p.done) of \(p.total) done")
                if !p.finished {
                    Button("Cancel") { center.cancel() }
                        .font(.footnote.weight(.semibold))
                        .accessibilityHint("Stops the downloads. Everything else stays restored.")
                }
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

private struct RestoreRedownloadUI: ViewModifier {
    @Environment(\.ao3Client) private var client
    private var center: RestoreDownloadCenter { .shared }

    private var proposedCount: Int {
        RestoreDownloadCenter.shared.proposedIds?.count ?? 0
    }

    func body(content: Content) -> some View {
        content
            .alert("Re-download offline stories?", isPresented: Binding(
                get: { RestoreDownloadCenter.shared.proposedIds != nil },
                set: { if !$0 { RestoreDownloadCenter.shared.dismissProposal() } })) {
                Button("Download") { center.startDownloads(client: client) }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("\(proposedCount) \(proposedCount == 1 ? "story" : "stories") in your restored library \(proposedCount == 1 ? "was" : "were") saved for offline reading. Download \(proposedCount == 1 ? "it" : "them") again on this device? Everything else is already restored.")
            }
            .overlay(alignment: .bottom) {
                RestoreDownloadBanner(center: RestoreDownloadCenter.shared)
                    .animation(.easeInOut(duration: 0.25), value: RestoreDownloadCenter.shared.progress)
            }
    }
}

extension View {
    /// Attach once, on the app's root view: renders the post-restore
    /// re-download prompt and progress banner wherever the user is.
    func restoreRedownloadUI() -> some View {
        modifier(RestoreRedownloadUI())
    }
}

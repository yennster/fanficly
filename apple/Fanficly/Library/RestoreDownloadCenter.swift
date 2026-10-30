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
///
/// The prompt offers only works whose text a restore just added, minus the
/// ones the reader turned down with Not Now, so a launch sync that brings in
/// nothing new doesn't ask again (#152).
@Observable @MainActor
final class RestoreDownloadCenter {
    static let shared = RestoreDownloadCenter()

    struct Progress: Equatable {
        var done: Int
        var failed: Int
        var total: Int
        var finished: Bool
        /// Why the run ended early, when AO3 refused it; the rest weren't tried.
        var stopped: StopReason? = nil
    }

    /// AO3 answers that would fail every remaining story the same way, so
    /// the queue stops instead of sending one request a second into them.
    enum StopReason: Equatable {
        /// AO3 said slow down (429).
        case rateLimited
        /// AO3 sent a signed-in reader to its login page: the session expired.
        case signInNeeded

        /// Signed out, `.unauthorized` is just a restricted work (it needs an
        /// account), so it fails alone and the public ones still download.
        init?(_ error: any Error, signedIn: Bool) {
            switch error as? AO3Error {
            case .rateLimited: self = .rateLimited
            case .unauthorized where signedIn: self = .signInNeeded
            default: return nil
            }
        }
    }

    /// Non-nil while the "re-download?" prompt should show.
    private(set) var proposedIds: [Int]?
    /// Non-nil while downloads run (or briefly after, `finished == true`).
    private(set) var progress: Progress?
    private var lastProposal: [Int] = []
    private var downloadTask: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Works whose offline text was restored but whose EPUB file is missing
    /// locally — i.e. they were downloaded on the device that made the backup.
    /// With `restored`, only those works; `declined` ones are left out.
    static func redownloadCandidates(
        in context: ModelContext, restored: Set<Int>? = nil, declined: Set<Int> = []
    ) -> [Int] {
        let works = (try? context.fetch(FetchDescriptor<Work>())) ?? []
        return works
            .filter { restored?.contains($0.ao3Id) ?? true }
            .filter { !declined.contains($0.ao3Id) }
            // An imported book that isn't on AO3 has nothing to download.
            .filter { !EPUBImport.isLocalWork($0.ao3Id) }
            .filter { !$0.chapters.isEmpty && WorkPersistence.epubURL(workId: $0.ao3Id) == nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map(\.ao3Id)
    }

    /// The restore (`iCloudSyncManager.applyBackup`) records each work it
    /// gave chapter text, so the next prompt offers just those.
    func noteRestoredText(workIds: some Sequence<Int>) {
        restoredTextIds.formUnion(workIds)
    }

    /// Works whose chapter text a restore added since the last prompt, plus
    /// the ones a stopped run didn't get to. Kept on this device, so they
    /// survive a relaunch until the next restore offers them.
    static let pendingKey = "restore.pendingRedownloads"

    private var restoredTextIds: Set<Int> {
        get { Set(defaults.array(forKey: Self.pendingKey) as? [Int] ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.pendingKey) }
    }

    /// Shows the prompt for the works the last restore gave text, when any
    /// still lack their EPUB and weren't turned down. Does nothing while a
    /// prompt or a run is up; the noted works wait for the next restore.
    func proposeRedownload(context: ModelContext) {
        guard downloadTask == nil, progress == nil, proposedIds == nil else { return }
        let ids = Self.redownloadCandidates(in: context, restored: restoredTextIds, declined: declinedIds)
        restoredTextIds = []
        guard !ids.isEmpty else { return }
        lastProposal = ids
        proposedIds = ids
    }

    func dismissProposal() {
        proposedIds = nil
    }

    /// Not Now: this device doesn't offer these works again. Each still has
    /// its own Save Offline, and a folder's Download All includes it.
    func declineProposal() {
        proposedIds = nil
        guard !lastProposal.isEmpty else { return }
        declinedIds.formUnion(lastProposal)
        lastProposal = []
    }

    /// Kept on this device only (not in the backup's settings), as AO3 ids.
    static let declinedKey = "restore.declinedRedownloads"

    private var declinedIds: Set<Int> {
        get { Set(defaults.array(forKey: Self.declinedKey) as? [Int] ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.declinedKey) }
    }

    /// Kicks off sequential EPUB downloads (the AO3 throttle spaces them out
    /// anyway). Reads the snapshot taken at proposal time, so it works no
    /// matter whether the alert clears its binding before or after the
    /// button action runs.
    /// `signedIn` decides what an `.unauthorized` means (`StopReason`).
    func startDownloads(client: any AO3ClientProtocol, signedIn: Bool) {
        let ids = lastProposal
        guard !ids.isEmpty, downloadTask == nil else { return }
        proposedIds = nil
        lastProposal = []
        start(ids: ids, kind: .restore, signedIn: signedIn) { id in _ = try await client.downloadEPUB(workId: id) }
    }

    // MARK: - Folder "Download All"

    /// What the current (or last) run is for; it picks the banner's and
    /// VoiceOver's wording.
    enum Kind: Equatable {
        case restore
        case folder
    }

    private(set) var kind: Kind = .restore

    /// The works in a folder that aren't downloaded yet, in the order given
    /// (the folder's on-screen order), each once. `isDownloaded` defaults to
    /// the EPUB file check that drives the Downloaded badge.
    static func folderDownloadCandidates(
        _ works: [Work],
        isDownloaded: (Int) -> Bool = { WorkPersistence.epubURL(workId: $0) != nil }
    ) -> [Int] {
        var seen = Set<Int>()
        return works
            .map(\.ao3Id)
            .filter { !EPUBImport.isLocalWork($0) && !isDownloaded($0) && seen.insert($0).inserted }
    }

    /// Downloads a folder's stories one after another. `download` does the
    /// per-work save (offline text if missing, then the EPUB), exactly what
    /// the per-work Save Offline does. Ignored while another run is going.
    func startFolderDownload(ids: [Int], signedIn: Bool, download: @escaping @MainActor (Int) async throws -> Void) {
        guard !ids.isEmpty, downloadTask == nil else { return }
        start(ids: ids, kind: .folder, signedIn: signedIn, download: download)
    }

    // MARK: - The queue

    private func start(ids: [Int], kind: Kind, signedIn: Bool, download: @escaping @MainActor (Int) async throws -> Void) {
        self.kind = kind
        progress = Progress(done: 0, failed: 0, total: ids.count, finished: false)
        UIAccessibility.post(notification: .announcement,
                             argument: "Downloading \(ids.count) stories for offline reading.")
        downloadTask = Task {
            let tally = await Self.runQueue(ids: ids, signedIn: signedIn, download: download) { [weak self] in
                self?.progress = $0
            }
            guard let tally, !Task.isCancelled else { return }
            downloadTask = nil
            progress = tally
            // A stopped restore run offers what it didn't get to after the
            // next restore, as the banner promises. (A folder keeps its
            // Download All button for that.)
            if kind == .restore, tally.stopped != nil {
                noteRestoredText(workIds: ids.suffix(tally.untried))
            }
            UIAccessibility.post(notification: .announcement, argument: tally.announcement)
            // A stop asks the reader to do something, so it stays up longer.
            try? await Task.sleep(for: .seconds(tally.stopped == nil ? 4 : 10))
            if progress?.finished == true { progress = nil }
        }
    }

    /// Runs `download` for each id in turn, never in parallel. A failure is
    /// counted and skipped (a deleted work mustn't stall the rest), except
    /// a rate limit or a sign-in wall, which ends the run (`stopped`) since
    /// every story after it would fail the same way. Returns
    /// the finished tally, or nil when the surrounding task was cancelled;
    /// works downloaded before the cancel stay downloaded, since nothing
    /// here undoes them. `report` gets the tally after each work.
    static func runQueue(
        ids: [Int],
        signedIn: Bool,
        download: @MainActor (Int) async throws -> Void,
        report: @MainActor (Progress) -> Void
    ) async -> Progress? {
        var tally = Progress(done: 0, failed: 0, total: ids.count, finished: false)
        for id in ids {
            if Task.isCancelled { return nil }
            do {
                try await download(id)
                tally = tally.recording(succeeded: true)
            } catch is CancellationError {
                return nil
            } catch {
                tally = tally.recording(succeeded: false)
                if let reason = StopReason(error, signedIn: signedIn) {
                    if Task.isCancelled { return nil }
                    return tally.finishing(stopped: reason)
                }
            }
            if Task.isCancelled { return nil }
            report(tally)
        }
        return tally.finishing()
    }

    /// Stops the downloads; everything already restored (and already
    /// downloaded) stays.
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        progress = nil
        UIAccessibility.post(notification: .announcement, argument: kind == .restore
            ? "Downloads canceled. Your restored library is unaffected."
            : "Downloads canceled. Stories already downloaded stay downloaded.")
    }
}

extension RestoreDownloadCenter.Progress {
    /// The tally after one more work finished (or failed).
    func recording(succeeded: Bool) -> Self {
        var next = self
        if succeeded { next.done += 1 } else { next.failed += 1 }
        return next
    }

    /// The same tally, marked finished (early, with `stopped`).
    func finishing(stopped: RestoreDownloadCenter.StopReason? = nil) -> Self {
        var next = self
        next.finished = true
        next.stopped = stopped
        return next
    }

    /// The finished banner's headline.
    var finishedTitle: String {
        switch stopped {
        case .rateLimited: "AO3 asked to slow down"
        case .signInNeeded: "Sign in to AO3 to download the rest"
        case nil: failed == 0 ? "Downloaded \(done) stories" : "Downloaded \(done) of \(total) stories"
        }
    }

    /// The stories a stopped run didn't download: the one AO3 refused and
    /// every one after it. Zero for a run that went to the end.
    var untried: Int {
        stopped == nil ? 0 : total - done - failed + 1
    }

    /// The finished banner's second line, for a stopped run.
    var stoppedDetail: String? {
        guard let stopped else { return nil }
        let left = untried
        return switch stopped {
        case .rateLimited: "Downloaded \(done) of \(total). Try the other \(left) again later."
        case .signInNeeded: "Downloaded \(done) of \(total). AO3 wants a signed-in reader for the other \(left)."
        }
    }

    /// What VoiceOver says when the run ends.
    var announcement: String {
        if let stoppedDetail { return "Downloads stopped. \(finishedTitle). \(stoppedDetail)" }
        return failed == 0
            ? "Downloaded \(done) stories for offline reading."
            : "Downloads finished. \(done) succeeded, \(failed) failed."
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
                    Text(p.finished ? p.finishedTitle : "Downloading stories… \(p.done) of \(p.total)")
                        .font(.footnote.weight(.semibold))
                    if let detail = p.stoppedDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView(value: Double(p.done + p.failed), total: Double(max(p.total, 1)))
                            .progressViewStyle(.linear)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.finished
                    ? p.stoppedDetail.map { "\(p.finishedTitle). \($0)" } ?? "Downloaded \(p.done) of \(p.total) stories"
                    : "Downloading stories, \(p.done) of \(p.total) done")
                if !p.finished {
                    Button("Cancel") { center.cancel() }
                        .font(.footnote.weight(.semibold))
                        .accessibilityHint(center.kind == .restore
                            ? "Stops the downloads. Everything else stays restored."
                            : "Stops the downloads. Stories already downloaded stay.")
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
    @Environment(AuthState.self) private var auth
    private var center: RestoreDownloadCenter { .shared }

    private var proposedCount: Int {
        RestoreDownloadCenter.shared.proposedIds?.count ?? 0
    }

    func body(content: Content) -> some View {
        content
            .alert("Re-download offline stories?", isPresented: Binding(
                get: { RestoreDownloadCenter.shared.proposedIds != nil },
                set: { if !$0 { RestoreDownloadCenter.shared.dismissProposal() } })) {
                Button("Download") { center.startDownloads(client: client, signedIn: auth.isLoggedIn) }
                Button("Not Now", role: .cancel) { center.declineProposal() }
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

import SwiftUI
import SwiftData
import UIKit // UIAccessibility announcements (SaveOfflineAlert)

struct WorkDetailView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(ReaderProfile.deviceKey("reader.theme")) private var themeRaw: String = ReaderTheme.system.rawValue
    @Environment(\.dismiss) private var dismiss
    let workId: Int
    @State private var payload: AO3WorkPayload?
    @State private var errorMessage: String?
    /// Why Download failed, shown in an alert: `errorMessage` only shows when
    /// the work never loaded.
    @State private var saveError: String?
    @State private var isSavingOffline: Bool = false
    @State private var followed: Bool = false
    @State private var epubURL: URL?
    @State private var showingReport: Bool = false
    @State private var showingComments: Bool = false
    @State private var showingBookmark: Bool = false
    @State private var currentChapterIndex = 1
    /// The reader is in full screen: its back arrow is the only toolbar item.
    @State private var readerFullScreen = false
    @State private var exporter = WorkExporter()
    @State private var kudos = KudosGiver()

    /// The reader's themed page colour, computed the same way `ReaderView`
    /// does, so the detail screen is opaque from the first frame.
    private var readerBackground: Color {
        let theme = ReaderTheme(rawValue: themeRaw) ?? .system
        let scheme = theme.preferredColorScheme ?? systemColorScheme
        return theme.background(for: scheme)
    }

    var body: some View {
        Group {
            if let payload {
                ReaderView(payload: payload, currentChapter: $currentChapterIndex)
                    .onPreferenceChange(ReaderFullScreenKey.self) { readerFullScreen = $0 }
                    .toolbar {
                        if !readerFullScreen {
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                Button {
                                    followed = WorkPersistence.toggleFollow(summary: payload.summary, into: context)
                                } label: {
                                    Label(followed ? "Remove from Library" : "Save to Library",
                                          systemImage: followed ? "bookmark.fill" : "bookmark")
                                }
                                .accessibilityLabel(followed ? "Remove from Library" : "Save to Library")
                            
                                moreMenu(payload: payload)
                            }
                        }
                    }
                    .sheet(isPresented: $showingReport) {
                        SafariView(url: URL(string: "https://archiveofourown.org/abuse_reports/new")!)
                            .ignoresSafeArea()
                    }
                    .sheet(isPresented: $showingComments) {
                        CommentsView(workId: workId, workTitle: payload.summary.title,
                                     chapterId: payload.chapters.first(where: { $0.index == currentChapterIndex })?.aoId,
                                     chapterNumber: currentChapterIndex,
                                     totalChapters: payload.chapters.count)
                    }
                    .sheet(isPresented: $showingBookmark) {
                        AO3BookmarkSheet(workId: workId, workTitle: payload.summary.title)
                    }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load work", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { retry() }
                }
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Opaque, full-bleed backing so the screen we pushed from (e.g. the
        // Browse list with its filter chips) never shows through while the work
        // loads or during the push transition.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(readerBackground.ignoresSafeArea())
        // On the screen view, NOT inside the menu — see WorkExporter's docs.
        .workExportPresentation(exporter)
        .kudosPresentation(kudos, workId: workId)
        .saveOfflineAlert($saveError)
        .task { await load() }
    }

    // MARK: - Toolbar buttons

    /// Overflow menu: save-to-library (follow), offline download, plus the
    /// UGC safeguards (App Store guideline 1.2) — report objectionable content
    /// to AO3 (the host/moderator), and hide the work locally so it never
    /// appears in results again. Kept to a single menu so the toolbar matches
    /// the Library reader and the reader's own items (chapters, Aa, minimize)
    /// fit without the system spilling them into its own overflow. Its symbol
    /// isn't an ellipsis: Apple keeps that for the system overflow menu.
    private func moreMenu(payload: AO3WorkPayload) -> some View {
        Menu {
            Button {
                showingComments = true
            } label: {
                Label("Comments", systemImage: "bubble.left.and.bubble.right")
            }
            KudosMenuButton(workId: workId, giver: kudos)
            Button {
                showingBookmark = true
            } label: {
                Label("Bookmark on AO3", systemImage: "bookmark.square")
            }

            Divider()

            WorkExportButton(workId: workId, title: payload.summary.title,
                             exporter: exporter, useTextLabel: true)
            Button {
                Task { await saveOffline(payload) }
            } label: {
                if isSavingOffline {
                    Label("Downloading…", systemImage: "arrow.down.circle")
                } else if epubURL != nil {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .disabled(isSavingOffline || epubURL != nil)

            Divider()

            Button {
                showingReport = true
            } label: {
                Label("Report this work", systemImage: "flag")
            }
            Button(role: .destructive) {
                HiddenWorkStore.hide(ao3Id: payload.summary.id, title: payload.summary.title, into: context)
                dismiss()
            } label: {
                Label("Hide this work", systemImage: "eye.slash")
            }
        } label: {
            if exporter.isExporting || kudos.isSending {
                ProgressView()
            } else {
                Label("Work options", systemImage: "book.circle")
            }
        }
        .accessibilityLabel("Work options")
    }

    // MARK: - Actions

    /// Clears the error first: the error state shows until `errorMessage` is nil.
    private func retry() {
        errorMessage = nil
        Task { await load() }
    }

    private func load() async {
        epubURL = WorkPersistence.epubURL(workId: workId)
        followed = WorkPersistence.isFollowed(workId: workId, in: context)

        do {
            let fetched = try await client.fetchWork(id: workId)
            payload = fetched
            WorkPersistence.recordView(summary: fetched.summary, into: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveOffline(_ payload: AO3WorkPayload) async {
        isSavingOffline = true
        defer { isSavingOffline = false }
        _ = WorkPersistence.upsert(payload: payload, into: context)
        iCloudSyncManager.shared.queueBackup(context: context)
        do {
            let url = try await client.downloadEPUB(workId: payload.summary.id)
            epubURL = url
        } catch {
            saveError = "The text is saved for offline reading, but the EPUB download failed: \(error.localizedDescription)"
        }
    }

}

/// Leaves kudos from a work's options menu (login-gated, once per work).
/// The screen owns it, like `WorkExporter`, so the result alert has a live
/// anchor after the menu closes. The POST is never retried: after a dropped
/// connection a second tap is safe, because AO3 answers a duplicate with
/// "already left kudos".
@Observable @MainActor
final class KudosGiver {
    var isSending = false
    var hasLeft = false
    /// The alert after a tap: a thank-you or AO3's reason for refusing.
    var result: (title: String, message: String)?
    /// AO3 refused the kudos for an expired session; the screen marks
    /// `AuthState` (#131) and resets it.
    var sessionExpired = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func refresh(workId: Int, username: String?) {
        hasLeft = username != nil && KudosStore.hasLeft(workId: workId, defaults: defaults)
    }

    func leave(workId: Int, username: String?, client: any AO3ClientProtocol) async {
        guard username != nil, !isSending, !hasLeft else { return }
        isSending = true
        defer { isSending = false }
        do {
            let outcome = try await client.leaveKudos(workId: workId)
            KudosStore.markLeft(workId: workId, defaults: defaults)
            hasLeft = true
            result = outcome == .left
                ? (title: "Kudos left", message: "Thank you for leaving kudos!")
                : (title: "Kudos already left", message: "You've already left kudos on this work.")
        } catch AO3Error.unauthorized {
            sessionExpired = true
            result = (title: "Couldn't leave kudos", message: "Your AO3 login has expired. Log in again in Settings → AO3 Login, then try again.")
        } catch AO3Error.kudosRejected(let message) {
            result = (title: "Couldn't leave kudos", message: message)
        } catch AO3Error.rateLimited {
            result = (title: "Couldn't leave kudos", message: "AO3 is asking us to slow down. Try again in a few minutes.")
        } catch AO3Error.network(let underlying) {
            result = (title: "Couldn't leave kudos", message: "Couldn't reach AO3: \(underlying) If the request reached AO3, the kudos may have landed; trying again is safe.")
        } catch {
            result = (title: "Couldn't leave kudos", message: error.localizedDescription)
        }
    }
}

/// The "Leave Kudos" item for a work's options menu. Pass the screen's
/// `KudosGiver` and attach `.kudosPresentation(_:workId:)` to the screen.
struct KudosMenuButton: View {
    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    let workId: Int
    let giver: KudosGiver

    var body: some View {
        Button {
            let client = client
            let username = auth.username
            Task { await giver.leave(workId: workId, username: username, client: client) }
        } label: {
            if giver.isSending {
                Label("Leaving Kudos…", systemImage: "heart")
            } else if giver.hasLeft {
                Label("Kudos Left", systemImage: "heart.fill")
            } else if auth.username == nil {
                Label("Log In to Leave Kudos", systemImage: "heart")
            } else {
                Label("Leave Kudos", systemImage: "heart")
            }
        }
        .disabled(giver.isSending || giver.hasLeft || auth.username == nil)
    }
}

private struct KudosPresentation: ViewModifier {
    @Environment(AuthState.self) private var auth
    @Bindable var giver: KudosGiver
    let workId: Int

    func body(content: Content) -> some View {
        content
            .onAppear { giver.refresh(workId: workId, username: auth.username) }
            .onChange(of: auth.username) { _, name in giver.refresh(workId: workId, username: name) }
            .onChange(of: giver.sessionExpired) { _, expired in
                guard expired else { return }
                auth.markSessionExpired()
                giver.sessionExpired = false
            }
            .alert(giver.result?.title ?? "", isPresented: Binding(
                get: { giver.result != nil },
                set: { if !$0 { giver.result = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(giver.result?.message ?? "")
            }
    }
}

/// The alert a failed Save Offline or Download ends with, also spoken to
/// VoiceOver: the menu has closed by then, so nothing else says it failed.
private struct SaveOfflineAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: message) { _, message in
                guard let message else { return }
                UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                    string: message,
                    attributes: [.accessibilitySpeechQueueAnnouncement: true]))
            }
            .alert("Couldn't finish saving offline", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }
}

extension View {
    /// Presents a Save Offline / Download failure. Attach to the screen view,
    /// never inside `Menu` content.
    func saveOfflineAlert(_ message: Binding<String?>) -> some View {
        modifier(SaveOfflineAlert(message: message))
    }

    /// Loads the remembered kudos state and presents a `KudosGiver`'s result.
    /// Attach to the screen view that owns the giver, never inside `Menu` content.
    func kudosPresentation(_ giver: KudosGiver, workId: Int) -> some View {
        modifier(KudosPresentation(giver: giver, workId: workId))
    }
}

import SwiftUI
import SwiftData
import StoreKit

/// The App Clip's one screen: the shared work in the app's reader, behind
/// the same 17+ confirmation as the app, with the system "Get the full app"
/// overlay. A link opens through `NSUserActivityTypeBrowsingWeb` (a
/// fanficly.app link tapped in Messages or Safari, a QR code, an App Clip
/// Code); in Xcode, the scheme's `_XCAppClipURL` does the same.
struct ClipRootView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(ContentControl.ageConfirmedKey) private var ageConfirmed: Bool = false
    @State private var link: WorkLink?
    @State private var unsupportedLink = false
    @State private var path = NavigationPath()
    @State private var statusBar = StatusBarVisibility()
    @State private var readerFullScreen = false
    @State private var wantsAppOverlay = false
    /// A link's chapter, waiting for the 17+ confirmation before it becomes
    /// the work's starting place.
    @State private var pendingChapterLink: WorkLink?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let link, ageConfirmed {
                    WorkDetailView(workId: link.workId)
                        // A second link replaces the work on screen.
                        .id(link.workId)
                } else {
                    ClipWelcomeView(unsupportedLink: unsupportedLink)
                }
            }
            // The byline and the series links lead past this one work: the
            // full app's job. `WorkDetailView`'s own links push these.
            .navigationDestination(for: AuthorRef.self) { author in
                ClipFullAppView(message: "Get Fanficly to see more from \(author.displayName).")
            }
            .navigationDestination(for: SeriesRef.self) { series in
                ClipFullAppView(message: "Get Fanficly to read the rest of \(series.title).")
            }
            .navigationDestination(for: SeriesWorkRef.self) { _ in
                ClipFullAppView(message: "Get Fanficly to read the next part of this series.")
            }
            // The header's tag chips (#380) open a tag's works in the app.
            .navigationDestination(for: TagRef.self) { tag in
                ClipFullAppView(message: "Get Fanficly to see more works tagged \(tag.name).")
            }
        }
        .onPreferenceChange(ReaderFullScreenKey.self) { readerFullScreen = $0 }
        .environment(statusBar)
        .statusBarHidden(statusBar.hidden)
        .undoToastHost()
        .environment(\.showFullAppOffer, ShowFullAppOffer { wantsAppOverlay = true })
        // The same first-launch 17+ confirmation as the app; the work loads
        // only once it's confirmed.
        .fullScreenCover(isPresented: .constant(!ageConfirmed)) {
            AgeGateView()
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            open(activity.webpageURL)
        }
        .onChange(of: ageConfirmed) { _, confirmed in
            guard confirmed else { return }
            seedChapterIfNeeded()
            if link != nil { wantsAppOverlay = true }
        }
        // Out of the way in full screen, where nothing but the page shows.
        .appStoreOverlay(isPresented: Binding(
            get: { wantsAppOverlay && !readerFullScreen && ageConfirmed },
            set: { wantsAppOverlay = $0 }
        )) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }

    private func open(_ url: URL?) {
        guard let url, let parsed = WorkLink(url: url) else {
            if link == nil { unsupportedLink = url != nil }
            return
        }
        ClipHandoff.record(workId: parsed.workId)
        pendingChapterLink = parsed.anchor == nil ? nil : parsed
        if ageConfirmed { seedChapterIfNeeded() }
        path = NavigationPath()
        link = parsed
        unsupportedLink = false
        if ageConfirmed { wantsAppOverlay = true }
    }

    /// A chapter in the link is where a first read starts; a place the reader
    /// already has in the clip wins, as a resume link's does. Only after the
    /// 17+ confirmation, before the reader loads (it reads the place as it
    /// opens), and as a bare progress row: not `ReadingProgressStore.save`,
    /// which would also count a reading day nobody read.
    private func seedChapterIfNeeded() {
        guard let pending = pendingChapterLink, let anchor = pending.anchor else { return }
        pendingChapterLink = nil
        guard ReadingProgressStore.load(ao3Id: pending.workId, in: context) == nil else { return }
        context.insert(ReadingProgress(ao3Id: pending.workId, chapterIndex: anchor.chapter,
                                       paragraphIndex: anchor.paragraph))
        try? context.save()
    }
}

/// Asks the clip to show the "Get the full app" overlay again (the work's
/// menu in `WorkDetailView` uses it).
struct ShowFullAppOffer: Sendable {
    let action: @MainActor @Sendable () -> Void

    @MainActor func callAsFunction() { action() }
}

private struct ShowFullAppOfferKey: EnvironmentKey {
    static var defaultValue: ShowFullAppOffer { ShowFullAppOffer {} }
}

extension EnvironmentValues {
    var showFullAppOffer: ShowFullAppOffer {
        get { self[ShowFullAppOfferKey.self] }
        set { self[ShowFullAppOfferKey.self] = newValue }
    }
}

/// Before a link arrives (the clip opened from its App Store card, say) or
/// for a link that isn't a work.
private struct ClipWelcomeView: View {
    let unsupportedLink: Bool
    @Environment(\.showFullAppOffer) private var showFullAppOffer

    var body: some View {
        ContentUnavailableView {
            Label("Fanficly", systemImage: "book.closed")
        } description: {
            Text(unsupportedLink
                 ? "This link isn't a work Fanficly can open. Get Fanficly to search and read AO3."
                 : "Open a shared fanficly.app work link to read it here, or get Fanficly to search, save and read AO3.")
        } actions: {
            Button("Get Fanficly") { showFullAppOffer() }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Where a link past the shared work lands.
private struct ClipFullAppView: View {
    let message: String
    @Environment(\.showFullAppOffer) private var showFullAppOffer

    var body: some View {
        ContentUnavailableView {
            Label("Get Fanficly", systemImage: "arrow.down.app")
        } description: {
            Text(message)
        } actions: {
            Button("Get Fanficly") { showFullAppOffer() }
                .buttonStyle(.borderedProminent)
        }
        .onAppear { showFullAppOffer() }
    }
}

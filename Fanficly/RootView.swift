import SwiftUI
import StoreKit
import SwiftData
import UniformTypeIdentifiers
import UIKit // UIAccessibility announcements (ImportOverlay)

struct PinnedFolderRoute: Hashable, Sendable {
    let folderName: String
}

struct FolderRouteDetailLoader: View {
    let folderName: String
    @Query private var folders: [CustomFolder]
    
    init(folderName: String) {
        self.folderName = folderName
        let pred = #Predicate<CustomFolder> { $0.name == folderName }
        _folders = Query(filter: pred)
    }
    
    var body: some View {
        if let folder = folders.first {
            FolderDetailView(folder: folder, initialSearchText: "")
        } else {
            ContentUnavailableView("Folder Not Found", systemImage: "folder.badge.questionmark", description: Text("The folder '\(folderName)' could not be found."))
        }
    }
}

struct RootView: View {
    // Start with no selection so the app opens on the sidebar menu
    // (on iPhone) rather than pushing straight into Search.
    @AppStorage("app.selectedTabRaw") private var selectedTabRaw: String = "search"
    @Environment(\.modelContext) private var context
    @Environment(\.ao3Client) private var client
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.requestReview) private var requestReview
    @AppStorage(ContentControl.ageConfirmedKey) private var ageConfirmed: Bool = false
    
    @State private var importingWorkId: Int? = nil
    @State private var compactSelection: SidebarItem?
    @State private var detailPath = NavigationPath()
    @State private var pendingResumeRoute: ResumeWorkRoute?
    @State private var pendingFolderRoute: PinnedFolderRoute?
    @State private var pendingNotificationRoute: NotificationRoute?

    @AppStorage("app.zoomScale") private var zoomScale: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            innerBody
                .frame(width: geo.size.width / CGFloat(zoomScale), height: geo.size.height / CGFloat(zoomScale))
                .scaleEffect(CGFloat(zoomScale), anchor: .topLeading)
        }
        .background {
            Group {
                Button(action: { zoom(in: true) }) { EmptyView() }
                    .keyboardShortcut("+", modifiers: [.command])
                Button(action: { zoom(in: true) }) { EmptyView() }
                    .keyboardShortcut("=", modifiers: [.command])
                Button(action: { zoom(in: false) }) { EmptyView() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button(action: { resetZoom() }) { EmptyView() }
                    .keyboardShortcut("0", modifiers: [.command])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var mainSplitView: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        NavigationLink(value: item) {
                            Label(item.title, systemImage: item.systemImage)
                        }
                        .help("Go to \(item.title)")
                        .hoverEffect(.highlight)
                    }
                }
            }
            .navigationTitle("Fanficly")
            .navigationBarTitleDisplayMode(.large)
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    switch selectedDetailItem {
                    case .search: SearchView()
                    case .browse: BrowseView()
                    case .popular: PopularView()
                    case .library: LibraryView()
                    case .stats: StatsView()
                    case .recentlyViewed: RecentlyViewedView()
                    case .authors: FollowedAuthorsView()
                    case .bookmarks: BookmarksView()
                    case .subscriptions: SubscriptionsView()
                    case .settings: SettingsView()
                    }
                }
                .navigationDestination(for: ResumeWorkRoute.self) { route in
                    if let savedWork = savedWork(with: route.workId) {
                        SavedWorkReader(work: savedWork)
                    } else {
                        WorkDetailView(workId: route.workId)
                    }
                }
                .navigationDestination(for: PinnedFolderRoute.self) { route in
                    FolderRouteDetailLoader(folderName: route.folderName)
                }
                .navigationDestination(for: NotificationRoute.self) { route in
                    Group {
                        switch route {
                        // Always the live work, even when it's saved: a downloaded
                        // copy doesn't have the chapter the alert is about.
                        // Reading position is keyed by work id, so it still resumes.
                        case .newChapters(let workId), .newWork(let workId):
                            WorkDetailView(workId: workId)
                        case .newWorks(let author):
                            AuthorWorksView(author: author)
                        }
                    }
                    // A tap can replace one route with another in the same slot;
                    // without this SwiftUI keeps the old screen (and its loaded
                    // work) and just hands it the new route.
                    .id(route)
                }
                // Performs the widget-resume push. Driven by state instead of
                // an imperative append so it runs once this stack's content is
                // actually mounted: in compact width the detail column doesn't
                // exist until the split view navigates to it, and pushing in
                // the same frame as the tab switch trips SwiftUI's
                // "NavigationRequestObserver tried to update multiple times
                // per frame" warning (and can silently drop the push).
                .task(id: pendingResumeRoute) {
                    guard let route = pendingResumeRoute else { return }
                    pendingResumeRoute = nil
                    detailPath = NavigationPath([route])
                }
                .task(id: pendingFolderRoute) {
                    guard let route = pendingFolderRoute else { return }
                    pendingFolderRoute = nil
                    detailPath = NavigationPath([route])
                }
                .task(id: pendingNotificationRoute) {
                    guard let route = pendingNotificationRoute else { return }
                    pendingNotificationRoute = nil
                    detailPath = NavigationPath([route])
                }
            }
        }
    }

    @ViewBuilder
    private var innerBody: some View {
        mainSplitView
            .task {
                if FanficlyApp.isDemoMode { DemoSeed.seed(into: context) }
            }
            .onChange(of: horizontalSizeClass) { _, newSizeClass in
                if newSizeClass == .compact {
                    compactSelection = nil
                }
            }
            .onChange(of: selectedTabRaw) { _, raw in
                guard horizontalSizeClass == .compact,
                      let item = SidebarItem(rawValue: raw),
                      compactSelection != item else { return }
                compactSelection = item
            }
            // 17+ confirmation on first launch (UGC safeguard). Skipped in demo
            // mode so screenshot automation isn't blocked.
            .fullScreenCover(isPresented: .constant(!ageConfirmed && !FanficlyApp.isDemoMode)) {
                AgeGateView()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            // `initial: true` catches a tap that cold-launched the app and
            // landed before this view existed.
            .onChange(of: NotificationRouter.shared.pendingRoute, initial: true) { _, route in
                guard let route else { return }
                NotificationRouter.shared.pendingRoute = nil
                openNotificationRoute(route)
            }
            // The rating prompt, shown just after a reader closes on a finished
            // story; the short delay lets the pop settle so it lands over the
            // list rather than mid-transition. See `ReviewPrompter`.
            .onChange(of: ReviewPrompter.shared.requestCount) { _, _ in
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    requestReview()
                }
            }
            .overlay {
                if let workId = importingWorkId {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    
                    ImportOverlay(workId: workId) { work in
                        self.importingWorkId = nil
                        select(.library)
                    } onCancel: {
                        self.importingWorkId = nil
                    }
                    .transition(.scale)
                }
            }
            .onDrop(of: [.url, .text], isTargeted: nil) { providers in
                self.handleImportProviders(providers)
            }
            .onPasteCommandIfAvailable { providers in
                _ = self.handleImportProviders(providers)
            }
            // Post-iCloud-restore "re-download offline stories?" prompt and
            // its progress banner — root-level so it shows on any tab.
            .restoreRedownloadUI()
    }

    private var isCompactNavigation: Bool {
        horizontalSizeClass == .compact
    }

    private var selectedDetailItem: SidebarItem {
        if isCompactNavigation, let compactSelection {
            return compactSelection
        }
        return SidebarItem(rawValue: selectedTabRaw) ?? .search
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            if isCompactNavigation {
                compactSelection
            } else {
                SidebarItem(rawValue: selectedTabRaw)
            }
        } set: { item in
            guard let item else {
                if isCompactNavigation {
                    compactSelection = nil
                }
                return
            }
            select(item)
        }
    }

    private func select(_ item: SidebarItem) {
        selectedTabRaw = item.rawValue
        detailPath = NavigationPath()
        if isCompactNavigation {
            compactSelection = item
        }
    }

    private func zoom(in forward: Bool) {
        let step = 0.1
        let minScale = 0.5
        let maxScale = 2.0
        if forward {
            zoomScale = min(maxScale, zoomScale + step)
        } else {
            zoomScale = max(minScale, zoomScale - step)
        }
    }

    private func resetZoom() {
        zoomScale = 1.0
    }

    private func handleIncomingURL(_ url: URL) {
        if let route = parseResumeRoute(from: url) {
            openResumeRoute(route)
            return
        }

        if let workId = parseWorkId(from: url) {
            importingWorkId = workId
            return
        }
        
        // Custom Folder Shortcut routing (fanficly://library?folder=name)
        if url.host == "library",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let folderItem = components.queryItems?.first(where: { $0.name == "folder" }),
           let folderName = folderItem.value {
            select(.library)
            pendingFolderRoute = PinnedFolderRoute(folderName: folderName)
            return
        }
        
        // Saved Searches Shortcut routing (fanficly://search?query=queryText)
        if url.host == "search",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let queryItem = components.queryItems?.first(where: { $0.name == "query" }),
           let queryValue = queryItem.value {
            select(.search)
            UserDefaults.standard.set(queryValue, forKey: "search.pendingQuery")
            return
        }
    }

    private func openResumeRoute(_ route: ResumeWorkRoute) {
        installResumeProgressIfAvailable(for: route)
        // Switch to Library but DON'T clear the detail path here (as the general
        // `select(_:)` does). Clearing it and then re-pushing in the deferred
        // `.task` spans two update cycles and races with the tab switch; when the
        // app is already open SwiftUI can drop the re-push ("tried to update
        // multiple times per frame"), stranding you on an empty Library instead
        // of the reader. Letting the `.task` set the path to `[route]` in one
        // atomic mutation replaces whatever was there (empty, this same route, or
        // another tab's stack) reliably and idempotently.
        selectedTabRaw = SidebarItem.library.rawValue
        if isCompactNavigation { compactSelection = .library }
        pendingResumeRoute = route   // pushed by the .task(id:) on the stack
    }

    /// Opens what a tapped notification is about.
    private func openNotificationRoute(_ route: NotificationRoute) {
        if isCompactNavigation && compactSelection == nil {
            // iPhone on the sidebar menu (always the case after a cold launch):
            // open the route's own tab. Its detail column has to mount first,
            // and pushing in that same frame drops the push, so the stack's
            // .task(id:) does it once mounted (as in `openResumeRoute`).
            let workIsSaved = route.workId.map { savedWork(with: $0) != nil } ?? false
            let tab = route.landingTab(workIsSaved: workIsSaved)
            selectedTabRaw = tab.rawValue
            compactSelection = tab
            pendingNotificationRoute = route
        } else {
            // A tab's stack is already on screen: open the route on top of it
            // instead of switching tabs. Switching the split view's selection
            // while a screen is pushed can drop the push, and the deferred
            // .task never runs on a stack with a screen pushed over it.
            detailPath = NavigationPath([route])
        }
    }

    private func installResumeProgressIfAvailable(for route: ResumeWorkRoute) {
        let widgetProgress = WidgetProgressStore.load()
        let matchingWidgetProgress = widgetProgress?.id == route.workId ? widgetProgress : nil

        let widgetAnchor = matchingWidgetProgress.flatMap { progress -> ReadingAnchor? in
            guard let chapter = progress.chapter else { return nil }
            return ReadingAnchor(chapter: max(chapter, 1), paragraph: max(progress.paragraph ?? 0, 0))
        }

        let existing = readingProgress(for: route.workId)
        guard let anchor = ResumeProgressPolicy.anchorToInstall(
            routeAnchor: route.anchor,
            widgetAnchor: widgetAnchor,
            widgetFreshness: matchingWidgetProgress?.freshnessDate,
            existingUpdatedAt: existing?.updatedAt
        ) else { return }

        ReadingProgressStore.save(
            ao3Id: route.workId,
            anchor: anchor,
            title: matchingWidgetProgress?.title ?? existing?.title ?? "",
            author: matchingWidgetProgress?.author ?? existing?.author ?? "",
            progress: matchingWidgetProgress?.clampedProgress,
            syncWidgetImmediately: false,
            in: context
        )
    }

    private func savedWork(with id: Int) -> Work? {
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == id })
        return (try? context.fetch(descriptor))?.first
    }

    private func readingProgress(for id: Int) -> ReadingProgress? {
        let descriptor = FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.ao3Id == id })
        return (try? context.fetch(descriptor))?.first
    }

    private func parseResumeRoute(from url: URL) -> ResumeWorkRoute? {
        guard url.scheme == "fanficly",
              url.host?.lowercased() == "resume",
              let idString = url.pathComponents.dropFirst().first,
              let id = Int(idString) else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let chapter = components?.queryItems?.first(where: { $0.name == "chapter" })?.value.flatMap(Int.init)
        let paragraph = components?.queryItems?.first(where: { $0.name == "paragraph" })?.value.flatMap(Int.init)
        let anchor = chapter.map { ReadingAnchor(chapter: max($0, 1), paragraph: max(paragraph ?? 0, 0)) }
        return ResumeWorkRoute(workId: id, anchor: anchor)
    }
    
    private func parseWorkId(from url: URL) -> Int? {
        var targetURL = url
        if url.scheme == "fanficly" {
            if url.host == "import" {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItem = components.queryItems?.first(where: { $0.name == "url" }),
                   let urlString = queryItem.value,
                   let decodedURL = URL(string: urlString) {
                    targetURL = decodedURL
                }
            } else if let host = url.host, host == "works" || host == "work",
                      let firstPath = url.pathComponents.dropFirst().first,
                      let id = Int(firstPath) {
                return id
            } else if let firstPath = url.pathComponents.dropFirst().first,
                      let id = Int(firstPath) {
                return id
            }
        }
        
        let path = targetURL.absoluteString
        guard let regex = try? NSRegularExpression(pattern: #"works/(\d+)"#, options: .caseInsensitive) else { return nil }
        let range = NSRange(location: 0, length: path.utf16.count)
        if let match = regex.firstMatch(in: path, range: range) {
            if let idRange = Range(match.range(at: 1), in: path),
               let id = Int(path[idRange]) {
                return id
            }
        }
        return nil
    }

    @discardableResult
    private func handleImportProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in
                        if let workId = self.parseWorkId(from: url) {
                            self.importingWorkId = workId
                        }
                    }
                }
            }
            return true
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                if let text = text,
                   let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Task { @MainActor in
                        if let workId = self.parseWorkId(from: url) {
                            self.importingWorkId = workId
                        }
                    }
                }
            }
            return true
        }
        return false
    }
}

private struct ResumeWorkRoute: Hashable {
    let workId: Int
    let anchor: ReadingAnchor?
}

/// Decides which anchor (if any) a widget-resume tap may install as reading
/// progress. The rule: a resume tap must never move saved progress backwards.
///
/// The URL anchor is a snapshot baked into the widget timeline, and WidgetKit
/// reloads are budget-throttled — the home-screen widget can lag hours behind
/// the last save. The widget-store payload is rewritten on every progress save,
/// so when both exist the store entry is at least as fresh as the URL. And
/// because `ReadingProgressStore.save` stamps the local record and the widget
/// payload with the same date, a store entry only reads *strictly* fresher when
/// it came from somewhere else (progress synced from another device) — which is
/// exactly the one case that may override local progress.
enum ResumeProgressPolicy {
    static func anchorToInstall(
        routeAnchor: ReadingAnchor?,
        widgetAnchor: ReadingAnchor?,
        widgetFreshness: Date?,
        existingUpdatedAt: Date?
    ) -> ReadingAnchor? {
        guard let existingUpdatedAt else {
            // No local progress — seed from whatever we have, preferring the
            // store payload over the possibly-stale URL snapshot.
            return widgetAnchor ?? routeAnchor
        }
        // Local progress exists. Only a strictly fresher widget-store entry may
        // move it; the URL anchor carries no timestamp, so it never can. When
        // the fresher store payload has no chapter there is nothing safe to
        // install — navigate and let the local progress win.
        guard let widgetFreshness, widgetFreshness > existingUpdatedAt else { return nil }
        return widgetAnchor
    }
}

struct ImportOverlay: View {
    let workId: Int
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    var onComplete: (Work) -> Void
    var onCancel: () -> Void
    
    @State private var status = "Connecting to AO3..."
    @State private var error: String? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Importing Work")
                .font(.headline)
                .foregroundStyle(.primary)
            
            if let error {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                Text(error)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Close", action: onCancel)
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(30)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
        .frame(width: 280)
        // Overlay, not a presentation — keep VoiceOver out of the dimmed content.
        .accessibilityAddTraits(.isModal)
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: status)
        }
        .onChange(of: status) { _, newStatus in
            // Announce completion only; the mid-import steps are too chatty.
            guard newStatus == "Done!" else { return }
            UIAccessibility.post(notification: .announcement, argument: newStatus)
        }
        .onChange(of: error) { _, newError in
            guard let newError else { return }
            UIAccessibility.post(notification: .announcement, argument: "Import failed. \(newError)")
        }
        .task {
            do {
                status = "Fetching metadata..."
                let payload = try await client.fetchWork(id: workId)
                status = "Saving to library..."
                let work = WorkPersistence.upsertMetadata(summary: payload.summary, into: context, save: false)
                work.isFollowed = true
                work.followedAt = .now
                work.savedAt = .now
                status = "Done!"
                try? context.save()
                iCloudSyncManager.shared.queueBackup(context: context)
                try? await Task.sleep(for: .seconds(1))
                onComplete(work)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}


enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case search, browse, popular, library, recentlyViewed, authors, bookmarks, subscriptions, stats, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .browse: "Browse"
        case .popular: "Popular"
        case .library: "Library"
        case .stats: "Stats"
        case .recentlyViewed: "Recently Viewed"
        case .authors: "Followed Authors"
        case .bookmarks: "Bookmarks"
        case .subscriptions: "Subscriptions"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .browse: "rectangle.stack"
        case .popular: "flame"
        case .library: "books.vertical"
        case .stats: "chart.bar.xaxis"
        case .recentlyViewed: "clock.arrow.circlepath"
        case .authors: "person.2"
        case .bookmarks: "bookmark"
        case .subscriptions: "bell"
        case .settings: "gearshape"
        }
    }
}

#Preview {
    RootView()
}

extension View {
    @ViewBuilder
    func onPasteCommandIfAvailable(perform action: @escaping ([NSItemProvider]) -> Void) -> some View {
        #if targetEnvironment(macCatalyst)
        self.onKeyPress { press in
            if press.key == KeyEquivalent("v"), press.modifiers.contains(.command) {
                if UIPasteboard.general.hasStrings {
                    let providers = UIPasteboard.general.strings?.map { NSItemProvider(object: $0 as NSString) } ?? []
                    if !providers.isEmpty {
                        action(providers)
                        return .handled
                    }
                }
            }
            return .ignored
        }
        #else
        self
        #endif
    }
}

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RootView: View {
    // Start with no selection so the app opens on the sidebar menu
    // (on iPhone) rather than pushing straight into Search.
    @AppStorage("app.selectedTabRaw") private var selectedTabRaw: String = "search"
    @Environment(\.modelContext) private var context
    @Environment(\.ao3Client) private var client
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(ContentControl.ageConfirmedKey) private var ageConfirmed: Bool = false
    
    @State private var importingWorkId: Int? = nil
    @State private var compactSelection: SidebarItem?
    @State private var detailPath = NavigationPath()

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
    private var innerBody: some View {
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
                    case .library: LibraryView()
                    case .recentlyViewed: RecentlyViewedView()
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
            }
        }
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
        .overlay {
            if let workId = importingWorkId {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                
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
        }
    }

    private func openResumeRoute(_ route: ResumeWorkRoute) {
        installResumeProgressIfAvailable(for: route)
        select(.library)

        Task { @MainActor in
            await Task.yield()
            detailPath.append(route)
        }
    }

    private func installResumeProgressIfAvailable(for route: ResumeWorkRoute) {
        let widgetProgress = WidgetProgressStore.load()
        let matchingWidgetProgress = widgetProgress?.id == route.workId ? widgetProgress : nil

        if let existing = readingProgress(for: route.workId),
           let matchingWidgetProgress,
           existing.updatedAt > matchingWidgetProgress.freshnessDate {
            return
        }

        let widgetAnchor = matchingWidgetProgress.flatMap { progress -> ReadingAnchor? in
            guard let chapter = progress.chapter else { return nil }
            return ReadingAnchor(chapter: max(chapter, 1), paragraph: max(progress.paragraph ?? 0, 0))
        }

        guard let anchor = route.anchor ?? widgetAnchor else { return }

        let existing = readingProgress(for: route.workId)
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
}

private struct ResumeWorkRoute: Hashable {
    let workId: Int
    let anchor: ReadingAnchor?
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
    case search, browse, library, recentlyViewed, subscriptions, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .browse: "Browse"
        case .library: "Library"
        case .recentlyViewed: "Recently Viewed"
        case .subscriptions: "Subscriptions"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .browse: "rectangle.stack"
        case .library: "books.vertical"
        case .recentlyViewed: "clock.arrow.circlepath"
        case .subscriptions: "bell"
        case .settings: "gearshape"
        }
    }
}

#Preview {
    RootView()
}

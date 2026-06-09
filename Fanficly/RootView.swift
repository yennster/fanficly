import SwiftUI
import SwiftData

struct RootView: View {
    // Start with no selection so the app opens on the sidebar menu
    // (on iPhone) rather than pushing straight into Search.
    @State private var selectedTab: SidebarItem? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.ao3Client) private var client
    @AppStorage(ContentControl.ageConfirmedKey) private var ageConfirmed: Bool = false
    
    @State private var importingWorkId: Int? = nil
    @State private var importedWork: Work? = nil

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
            List(selection: $selectedTab) {
                ForEach(SidebarItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            }
            .navigationTitle("Fanficly")
        } detail: {
            NavigationStack {
                switch selectedTab ?? .search {
                case .search: SearchView()
                case .browse: BrowseView()
                case .library: LibraryView()
                case .recentlyViewed: RecentlyViewedView()
                case .subscriptions: SubscriptionsView()
                case .settings: SettingsView()
                }
            }
        }
        .task {
            if FanficlyApp.isDemoMode { DemoSeed.seed(into: context) }
        }
        // 17+ confirmation on first launch (UGC safeguard). Skipped in demo
        // mode so screenshot automation isn't blocked.
        .fullScreenCover(isPresented: .constant(!ageConfirmed && !FanficlyApp.isDemoMode)) {
            AgeGateView()
        }
        .onOpenURL { url in
            if let workId = parseWorkId(from: url) {
                importingWorkId = workId
            }
        }
        .overlay {
            if let workId = importingWorkId {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                
                ImportOverlay(workId: workId) { work in
                    self.importingWorkId = nil
                    selectedTab = .library
                } onCancel: {
                    self.importingWorkId = nil
                }
                .transition(.scale)
            }
        }
        .sheet(item: $importedWork) { work in
            NavigationStack {
                SavedWorkReader(work: work)
                    .navigationTitle(work.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") {
                                importedWork = nil
                            }
                        }
                    }
            }
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

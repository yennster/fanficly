import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(AuthState.self) private var auth
    @Query(sort: [SortDescriptor<SubscriptionRecord>(\.displayName, order: .forward)]) private var subs: [SubscriptionRecord]
    @State private var isRefreshing: Bool = false
    @State private var lastError: String?
    @State private var lastNotifyCount: Int?
    @State private var hasRequestedNotifications: Bool = false
    @State private var browserURL: ShareItem?

    @ViewBuilder
    private func subscriptionRow(_ sub: SubscriptionRecord) -> some View {
        if sub.kind == "work", let workId = workId(from: sub) {
            // Tap a work subscription to open the fic. Render the same
            // LibraryRow when we have the work cached locally — the
            // subscription record alone only carries title + chapter count.
            NavigationLink(value: AO3WorkSummary.stub(id: workId, title: sub.displayName)) {
                if let work = cachedWork(ao3Id: workId) {
                    LibraryRow(work: work, downloaded: WorkPersistence.epubURL(workId: workId) != nil)
                } else {
                    SubscriptionRow(sub: sub)
                }
            }
        } else {
            // Series / author → open the AO3 page.
            Button {
                browserURL = ao3Page(for: sub)
            } label: {
                SubscriptionRow(sub: sub)
            }
            .buttonStyle(.plain)
        }
    }

    private func cachedWork(ao3Id: Int) -> Work? {
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == ao3Id })
        return (try? context.fetch(descriptor))?.first
    }

    private func workId(from sub: SubscriptionRecord) -> Int? {
        let parts = sub.key.split(separator: ":")
        guard parts.count == 2, parts[0] == "work" else { return nil }
        return Int(parts[1])
    }

    private func ao3Page(for sub: SubscriptionRecord) -> ShareItem? {
        let parts = sub.key.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let id = String(parts[1])
        let path: String
        switch parts[0] {
        case "series": path = "/series/\(id)"
        case "user":   path = "/users/\(id)"
        default:       return nil
        }
        return URL(string: "https://archiveofourown.org\(path)").map { ShareItem(url: $0) }
    }

    var body: some View {
        Group {
            if auth.username == nil {
                ContentUnavailableView {
                    Label("Log in to AO3", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Your AO3 subscriptions sync here once you log in. We'll notify you locally when subscribed works post new chapters.")
                } actions: {
                    NavigationLink {
                        LoginView()
                    } label: {
                        Text("Open Settings → AO3 Login").font(.callout)
                    }
                }
            } else if subs.isEmpty && !isRefreshing {
                ContentUnavailableView {
                    Label("No subscriptions yet", systemImage: "bell")
                } description: {
                    Text("Tap Refresh to fetch your subscriptions from AO3.")
                } actions: {
                    Button("Refresh") { Task { await refresh() } }
                }
            } else {
                List {
                    if let lastError {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    if let count = lastNotifyCount {
                        Text(count == 0
                             ? "No new chapters."
                             : "\(count) work\(count == 1 ? "" : "s") have new chapters.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(subs) { sub in
                        subscriptionRow(sub)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.large)
        .workAndAuthorDestinations()
        .sheet(item: $browserURL) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .toolbar {
            if auth.username != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing)
                }
            }
        }
        .task {
            if !hasRequestedNotifications, auth.username != nil {
                hasRequestedNotifications = true
                _ = await NotificationsAuthorization.request()
            }
        }
    }

    private func refresh() async {
        guard let username = auth.username else { return }
        isRefreshing = true
        lastError = nil
        let poller = SubscriptionPoller(client: client, context: context, username: username)
        do {
            // Fetch the subscription list first — this is fast and updates
            // the UI immediately.
            _ = try await poller.syncSubscriptionList()
        } catch let AO3Error.parseFailed(reason) {
            lastError = "Couldn't parse AO3's response: \(reason)"
        } catch AO3Error.unauthorized {
            lastError = "Not logged in. Open Settings → AO3 Login."
        } catch let AO3Error.network(underlying) {
            lastError = "Network: \(underlying)"
        } catch {
            lastError = error.localizedDescription
        }
        isRefreshing = false
        // The per-work new-chapter check is throttled (1 req/sec) and only
        // feeds notifications, so run it after the list is already showing.
        lastNotifyCount = await poller.checkForNewChapters()
    }
}

/// Visually mirrors `LibraryRow` so subscriptions and the library feel like
/// the same list. We don't have full work metadata for uncached subs (no
/// fandom/rating/wordcount), so those rows show kind + chapter/checked stats
/// in the same caption slot that LibraryRow uses for rating/words/chapters.
struct SubscriptionRow: View {
    let sub: SubscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sub.displayName).font(.headline)
            if !sub.authorName.isEmpty {
                Text("by \(sub.authorName)").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.caption2)
                    Text(kindLabel).font(.caption)
                }
                .foregroundStyle(.secondary)
                if sub.kind == "work", let count = sub.lastSeenChapterCount {
                    Text("\(count) chapter\(count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let checked = sub.lastCheckedAt {
                    Text("checked \(checked, style: .relative) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
    }

    private var icon: String {
        switch sub.kind {
        case "work":   "doc.text"
        case "series": "books.vertical"
        case "user":   "person"
        default:       "bell"
        }
    }

    /// "Work" is AO3's term for a fic — show something friendlier.
    private var kindLabel: String {
        switch sub.kind {
        case "work":   "Story"
        case "series": "Series"
        case "user":   "Author"
        default:       sub.kind.capitalized
        }
    }
}

/// The "Bookmarks" tab: the logged-in user's AO3 bookmarks, fetched live with
/// infinite scroll (mirrors the author-works list). Login-gated like
/// Subscriptions, since private bookmarks need the session cookie. Each row
/// reuses `WorkRow` (with its inline save-to-Library button).
struct BookmarksView: View {
    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    @Query private var hiddenWorks: [HiddenWork]
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true

    @State private var works: [AO3WorkSummary] = []
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private var visibleWorks: [AO3WorkSummary] {
        ContentFilter.apply(works, hiddenIds: HiddenWorkStore.ids(hiddenWorks), filterMature: filterMature)
    }

    var body: some View {
        Group {
            if auth.username == nil {
                ContentUnavailableView {
                    Label("Log in to AO3", systemImage: "bookmark.circle")
                } description: {
                    Text("Your AO3 bookmarks show here once you log in, including private ones.")
                } actions: {
                    NavigationLink { LoginView() } label: {
                        Text("Open Settings → AO3 Login").font(.callout)
                    }
                }
            } else if isLoading && works.isEmpty {
                VStack { Spacer(); ProgressView("Loading bookmarks…"); Spacer() }
            } else if let errorMessage, works.isEmpty {
                ContentUnavailableView("Couldn't load bookmarks", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else if works.isEmpty {
                ContentUnavailableView("No bookmarks yet", systemImage: "bookmark",
                    description: Text("Works you bookmark on AO3 will appear here."))
            } else if visibleWorks.isEmpty {
                ContentUnavailableView("Nothing to show", systemImage: "eye.slash",
                    description: Text("Every bookmark is hidden or filtered out by your content settings."))
            } else {
                List {
                    ForEach(visibleWorks) { work in
                        NavigationLink(value: work) { WorkRow(work: work) }
                            .onAppear {
                                if work.id == visibleWorks.last?.id {
                                    Task { await loadMore() }
                                }
                            }
                    }
                    if isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 8)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.large)
        .workAndAuthorDestinations()
        .toolbar {
            if auth.username != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task { await loadFirst() }
        .onChange(of: auth.username) { _, name in
            if name != nil, works.isEmpty { Task { await loadFirst() } }
        }
    }

    private func loadFirst() async {
        guard let username = auth.username, works.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.fetchBookmarks(username: username, page: 1)
            works = result.works
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func refresh() async {
        works = []
        currentPage = 1
        totalPages = 1
        await loadFirst()
    }

    private func loadMore() async {
        guard let username = auth.username, !isLoadingMore, currentPage < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await client.fetchBookmarks(username: username, page: currentPage + 1)
            let existing = Set(works.map(\.id))
            works.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            errorMessage = "\(error)"
        }
    }
}

extension AO3WorkSummary {
    /// A minimal summary carrying just an id (used as a navigation value
    /// when the full work will be fetched by the destination).
    static func stub(id: Int, title: String) -> AO3WorkSummary {
        AO3WorkSummary(
            id: id, title: title, author: "", summary: "", rating: "",
            warnings: [], categories: [], fandoms: [], characters: [],
            relationships: [], freeforms: [], wordCount: 0, chapterCount: 0,
            totalChapters: nil, language: "", kudos: 0, hits: 0,
            isComplete: false, updatedAt: nil
        )
    }
}

#Preview {
    NavigationStack { SubscriptionsView() }
        .environment(\.ao3Client, MockAO3Client())
        .environment(AuthState())
}

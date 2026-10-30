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
            .accessibilityHint("Opens on AO3")
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
            } else if subs.isEmpty && !isRefreshing && !auth.isSessionExpired {
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
                    // The way back from an expired session (#131): Refresh can't help.
                    if auth.isSessionExpired {
                        NavigationLink { LoginView() } label: {
                            Label(SessionExpiry.actionTitle, systemImage: "person.crop.circle.badge.questionmark")
                        }
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
        .onChange(of: auth.isSessionExpired) { _, expired in
            // Signed in again: the expired-session error no longer stands.
            if !expired, lastError?.hasPrefix(SessionExpiry.title) == true { lastError = nil }
        }
        .onAppear { syncIfNew() }
        // Another account (or none): the last run's messages were the old one's.
        .onChange(of: auth.username) { _, _ in
            lastError = nil
            lastNotifyCount = nil
            syncIfNew()
        }
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
                    .accessibilityLabel("Refresh subscriptions")
                }
            }
        }
        .task {
            // Not in demo mode, so screenshot and UI-test runs never get the alert.
            if !hasRequestedNotifications, auth.username != nil, !FanficlyApp.isDemoMode {
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
        var error: String?
        do {
            // Fetch the subscription list first — this is fast and updates
            // the UI immediately.
            _ = try await poller.syncSubscriptionList()
        } catch AO3Error.unauthorized {
            // Signed in here, so AO3 dropped the session (#131).
            if auth.username == username { auth.markSessionExpired() }
            error = "\(SessionExpiry.title). Sign in again to sync your subscriptions."
        } catch let failure {
            error = failure.localizedDescription
        }
        isRefreshing = false
        // Signed out or in as someone else meanwhile: the poller dropped the
        // old account's list (#159), and the new account gets its own sync.
        guard auth.username == username else {
            syncIfNew()
            return
        }
        lastError = error
        // The per-work new-chapter check is throttled (1 req/sec) and only
        // feeds notifications, so run it after the list is already showing.
        let count = await poller.checkForNewChapters()
        if auth.username == username { lastNotifyCount = count }
    }

    /// A new account's list syncs on its own (#159): just signed in, or the
    /// first visit since. After that, Refresh and the background poll keep it.
    private func syncIfNew() {
        guard let username = auth.username, auth.hasSession, !isRefreshing, !FanficlyApp.isDemoMode,
              !SubscriptionPoller(client: client, context: context, username: username).hasSyncedList
        else { return }
        Task { await refresh() }
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
            // Wraps instead of truncating at large text sizes.
            FlowLayout(spacing: 8, lineSpacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.caption2)
                        .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
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
    @State private var badges: [Int: ResultBadge] = [:]
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// A failed next page: shown under the works, which stay (#154).
    @State private var paging = LoadMoreState()
    /// The last load failed because the AO3 session expired (#131).
    @State private var sessionExpired = false

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
            } else if let errorMessage, works.isEmpty, sessionExpired, !auth.hasSession {
                SessionExpiredView(message: errorMessage)
            } else if let errorMessage, works.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load bookmarks", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await refresh() } }
                }
            } else if works.isEmpty {
                ContentUnavailableView("No bookmarks yet", systemImage: "bookmark",
                    description: Text("Works you bookmark on AO3 will appear here."))
            } else if visibleWorks.isEmpty {
                FilteredOutView(message: "Every bookmark so far is hidden or filtered out by your content settings.",
                                canLoadMore: currentPage < totalPages, isLoadingMore: isLoadingMore,
                                loadMoreError: paging.error,
                                sessionExpired: sessionExpired && !auth.hasSession, loadMore: loadMore)
            } else {
                List {
                    ForEach(visibleWorks) { work in
                        NavigationLink(value: work) { WorkRow(work: work, badge: badges[work.id]) }
                            // After a failure, the footer's Try Again loads on.
                            .onAppear {
                                if work.id == visibleWorks.last?.id, paging.error == nil {
                                    Task { await loadMore() }
                                }
                            }
                    }
                    LoadMoreFooter(isLoadingMore: isLoadingMore, error: paging.error,
                                   sessionExpired: sessionExpired && !auth.hasSession,
                                   stoppedOnHiddenPages: paging.stoppedOnHiddenPages, retry: loadMore)
                }
                .listStyle(.plain)
                .resultBadges(for: visibleWorks, into: $badges)
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
                    .accessibilityLabel("Refresh bookmarks")
                }
            }
        }
        .task { await loadFirst() }
        // Another account (or none): the list on screen isn't theirs (#159).
        .onChange(of: auth.username) { _, name in
            forgetList()
            if name != nil { Task { await loadFirst() } }
        }
        // Signed in again after the session expired.
        .onChange(of: auth.hasSession) { _, live in
            if live, works.isEmpty { Task { await loadFirst() } }
        }
    }

    private func loadFirst() async {
        guard let username = auth.username, works.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        sessionExpired = false
        // A next page of the list being replaced must not land in this one.
        paging.restart()
        defer {
            isLoading = false
            // Someone else signed in while this loaded; their list loads now.
            if let name = auth.username, name != username { Task { await loadFirst() } }
        }
        do {
            let page = try await client.fetchBookmarks(username: username, page: 1)
            // Signed out or in as someone else meanwhile (#159).
            guard auth.username == username else { return }
            let result = try auth.check(page)
            works = result.works
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            // A cancelled request is benign: this view's task was torn down
            // mid-flight (the split view settling its detail column, widened by
            // the 1 req/sec throttle), not a load failure. Don't surface it —
            // `.task` re-runs when the view re-appears. Only real errors show.
            guard !Task.isCancelled, auth.username == username else { return }
            sessionExpired = auth.explains(error)
            errorMessage = sessionExpired ? AuthState.message(for: error) : error.localizedDescription
        }
    }

    private func refresh() async {
        works = []
        currentPage = 1
        totalPages = 1
        await loadFirst()
    }

    /// Drops the list on screen, and any next page still on its way to it.
    private func forgetList() {
        works = []
        badges = [:]
        currentPage = 1
        totalPages = 1
        errorMessage = nil
        sessionExpired = false
        paging.restart()
    }

    /// Loads the next page, and the ones after it while the content filter
    /// hides them entirely, since those add no row to scroll to (#155).
    private func loadMore() async {
        guard !isLoadingMore else { return }
        paging.resume()
        while await loadNextPage(), !Task.isCancelled {}
    }

    /// Returns true when the page landed fully hidden and the next one should load.
    private func loadNextPage() async -> Bool {
        guard let username = auth.username, !isLoadingMore, !isLoading, currentPage < totalPages else { return false }
        let generation = paging.begin()
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.fetchBookmarks(username: username, page: currentPage + 1)
            guard paging.isCurrent(generation) else { return false }  // refreshed or signed out meanwhile
            let result = try auth.check(page)
            let shown = visibleWorks.count
            let existing = Set(works.map(\.id))
            works.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
            return paging.landed(newRows: visibleWorks.count - shown, hasMore: currentPage < totalPages)
        } catch {
            // Benign cancellation — see loadFirst.
            guard !Task.isCancelled, paging.isCurrent(generation) else { return false }
            // The bookmarks so far stay; the footer says why and offers Try Again (#154).
            sessionExpired = auth.explains(error)
            let message = sessionExpired ? AuthState.message(for: error) : "Couldn't load more bookmarks: \(error.localizedDescription)"
            paging.fail(message, generation: generation)
            UIAccessibility.post(notification: .announcement, argument: message)
            return false
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

/// A list on AO3's readings page that `ReadingListView` shows.
enum AO3ReadingList: Sendable {
    case markedForLater, history

    var title: String {
        switch self {
        case .markedForLater: "Marked for Later"
        case .history: "AO3 History"
        }
    }

    var systemImage: String {
        switch self {
        case .markedForLater: SidebarItem.markedForLater.systemImage
        case .history: SidebarItem.ao3History.systemImage
        }
    }

    var loginPrompt: String {
        switch self {
        case .markedForLater: "Works you mark for later on AO3 show here once you log in."
        case .history: "The works AO3 remembers you reading show here once you log in, newest first."
        }
    }

    var emptyTitle: String {
        switch self {
        case .markedForLater: "Nothing marked for later"
        case .history: "No AO3 history yet"
        }
    }

    var emptyDescription: String {
        switch self {
        case .markedForLater: "Use \"Mark for Later\" on a work on AO3 and it will appear here."
        case .history: "Works you open on the AO3 website while logged in will appear here."
        }
    }

    func fetch(_ client: any AO3ClientProtocol, username: String, page: Int) async throws -> AO3SearchResults {
        switch self {
        case .markedForLater:
            return try await client.fetchMarkedForLater(username: username, page: page)
        case .history:
            return try await client.fetchReadingHistory(username: username, page: page)
        }
    }
}

/// The "Marked for Later" and "AO3 History" tabs: a list from the logged-in
/// user's AO3 readings page, fetched live with infinite scroll. Built like `BookmarksView`;
/// read-only (marks are added and removed on AO3).
struct ReadingListView: View {
    let list: AO3ReadingList

    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    @Query private var hiddenWorks: [HiddenWork]
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true

    @State private var works: [AO3WorkSummary] = []
    @State private var badges: [Int: ResultBadge] = [:]
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// A failed next page: shown under the works, which stay (#154).
    @State private var paging = LoadMoreState()
    /// The last load failed because the AO3 session expired (#131).
    @State private var sessionExpired = false

    private var visibleWorks: [AO3WorkSummary] {
        ContentFilter.apply(works, hiddenIds: HiddenWorkStore.ids(hiddenWorks), filterMature: filterMature)
    }

    var body: some View {
        Group {
            if auth.username == nil {
                ContentUnavailableView {
                    Label("Log in to AO3", systemImage: list.systemImage)
                } description: {
                    Text(list.loginPrompt)
                } actions: {
                    NavigationLink { LoginView() } label: {
                        Text("Open Settings → AO3 Login").font(.callout)
                    }
                }
            } else if isLoading && works.isEmpty {
                VStack { Spacer(); ProgressView("Loading \(list.title)…"); Spacer() }
            } else if let errorMessage, works.isEmpty, sessionExpired, !auth.hasSession {
                SessionExpiredView(message: errorMessage)
            } else if let errorMessage, works.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load \(list.title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await refresh() } }
                }
            } else if works.isEmpty {
                ContentUnavailableView(list.emptyTitle, systemImage: list.systemImage,
                    description: Text(list.emptyDescription))
            } else if visibleWorks.isEmpty {
                FilteredOutView(message: "Every work here so far is hidden or filtered out by your content settings.",
                                canLoadMore: currentPage < totalPages, isLoadingMore: isLoadingMore,
                                loadMoreError: paging.error,
                                sessionExpired: sessionExpired && !auth.hasSession, loadMore: loadMore)
            } else {
                List {
                    ForEach(visibleWorks) { work in
                        NavigationLink(value: work) { WorkRow(work: work, badge: badges[work.id]) }
                            // After a failure, the footer's Try Again loads on.
                            .onAppear {
                                if work.id == visibleWorks.last?.id, paging.error == nil {
                                    Task { await loadMore() }
                                }
                            }
                    }
                    LoadMoreFooter(isLoadingMore: isLoadingMore, error: paging.error,
                                   sessionExpired: sessionExpired && !auth.hasSession,
                                   stoppedOnHiddenPages: paging.stoppedOnHiddenPages, retry: loadMore)
                }
                .listStyle(.plain)
                .resultBadges(for: visibleWorks, into: $badges)
            }
        }
        .navigationTitle(list.title)
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
                    .accessibilityLabel("Refresh \(list.title)")
                }
            }
        }
        .task { await loadFirst() }
        // Another account (or none): the list on screen isn't theirs (#159).
        .onChange(of: auth.username) { _, name in
            forgetList()
            if name != nil { Task { await loadFirst() } }
        }
        // Signed in again after the session expired.
        .onChange(of: auth.hasSession) { _, live in
            if live, works.isEmpty { Task { await loadFirst() } }
        }
    }

    private func loadFirst() async {
        guard let username = auth.username, works.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        sessionExpired = false
        // A next page of the list being replaced must not land in this one.
        paging.restart()
        defer {
            isLoading = false
            // Someone else signed in while this loaded; their list loads now.
            if let name = auth.username, name != username { Task { await loadFirst() } }
        }
        do {
            let result = try await list.fetch(client, username: username, page: 1)
            // Signed out or in as someone else meanwhile (#159).
            guard auth.username == username else { return }
            works = result.works
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            guard !Task.isCancelled, auth.username == username else { return }   // benign cancellation — see BookmarksView
            sessionExpired = auth.explains(error)
            errorMessage = sessionExpired ? AuthState.message(for: error) : Self.message(for: error)
        }
    }

    private func refresh() async {
        works = []
        currentPage = 1
        totalPages = 1
        await loadFirst()
    }

    /// Drops the list on screen, and any next page still on its way to it.
    private func forgetList() {
        works = []
        badges = [:]
        currentPage = 1
        totalPages = 1
        errorMessage = nil
        sessionExpired = false
        paging.restart()
    }

    /// Loads the next page, and the ones after it while the content filter
    /// hides them entirely, since those add no row to scroll to (#155).
    private func loadMore() async {
        guard !isLoadingMore else { return }
        paging.resume()
        while await loadNextPage(), !Task.isCancelled {}
    }

    /// Returns true when the page landed fully hidden and the next one should load.
    private func loadNextPage() async -> Bool {
        guard let username = auth.username, !isLoadingMore, !isLoading, currentPage < totalPages else { return false }
        let generation = paging.begin()
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await list.fetch(client, username: username, page: currentPage + 1)
            guard paging.isCurrent(generation) else { return false }  // refreshed meanwhile
            let shown = visibleWorks.count
            let existing = Set(works.map(\.id))
            works.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
            return paging.landed(newRows: visibleWorks.count - shown, hasMore: currentPage < totalPages)
        } catch {
            guard !Task.isCancelled, paging.isCurrent(generation) else { return false }
            // The works so far stay; the footer says why and offers Try Again (#154).
            sessionExpired = auth.explains(error)
            let message = sessionExpired ? AuthState.message(for: error) : "Couldn't load more: \(Self.message(for: error))"
            paging.fail(message, generation: generation)
            UIAccessibility.post(notification: .announcement, argument: message)
            return false
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AO3Error.unauthorized: "Your AO3 login has expired. Sign in again."
        case AO3Error.parseFailed(let reason): reason
        default: error.localizedDescription
        }
    }
}

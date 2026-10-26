import SwiftData
import SwiftUI

/// Navigation value for "more by this author" — pushed when the reader's
/// byline is tapped. `displayName` is the byline text; `username` is the AO3
/// login used to fetch the works page.
struct AuthorRef: Hashable {
    let username: String
    let displayName: String
}

/// Lists an author's works (paginated, infinite-scroll), reusing the search
/// blurb parser. Tapping a work opens the reader via the shared destination.
struct AuthorWorksView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(AuthState.self) private var auth
    @Query private var hiddenWorks: [HiddenWork]
    @Query private var blockedTerms: [BlockedTerm]
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true
    let author: AuthorRef

    @State private var works: [AO3WorkSummary] = []
    @State private var badges: [Int: ResultBadge] = [:]
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// The last load failed because the AO3 session expired (#131).
    @State private var sessionExpired = false
    @State private var isFollowingAuthor = false

    /// Opening a blocked author's page is asking for them, so only blocked
    /// tags apply here.
    private var visibleWorks: [AO3WorkSummary] {
        ContentFilter.apply(works, hiddenIds: HiddenWorkStore.ids(hiddenWorks), filterMature: filterMature,
                            blocklist: Blocklist(blockedTerms).lifting(tags: [String](), authors: [author.username, author.displayName]))
    }

    var body: some View {
        Group {
            if isLoading && works.isEmpty {
                VStack { Spacer(); ProgressView("Loading…"); Spacer() }
            } else if let errorMessage, works.isEmpty, sessionExpired, !auth.hasSession {
                SessionExpiredView(message: errorMessage)
            } else if let errorMessage, works.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load works", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await loadFirst() } }
                }
            } else if works.isEmpty {
                ContentUnavailableView("No works to show", systemImage: "person.slash",
                    description: Text("This author has no works published."))
            } else if visibleWorks.isEmpty {
                FilteredOutView(message: "Every work by this author so far is filtered out by your content settings.",
                                canLoadMore: currentPage < totalPages, isLoadingMore: isLoadingMore,
                                loadMore: loadMore)
            } else {
                List {
                    ForEach(visibleWorks) { work in
                        NavigationLink(value: work) { WorkRow(work: work, badge: badges[work.id]) }
                            // Infinite scroll: pull the next page as the last row appears.
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
                    } else if let errorMessage, sessionExpired, !auth.hasSession {
                        SessionExpiredView(message: errorMessage)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .resultBadges(for: visibleWorks, into: $badges)
            }
        }
        .navigationTitle(author.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !author.username.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { followButton }
            }
        }
        .task { await loadFirst() }
        .onAppear {
            isFollowingAuthor = WorkPersistence.isAuthorFollowed(username: author.username, in: context)
        }
    }

    private var followButton: some View {
        Button {
            let newState = WorkPersistence.toggleFollowAuthor(
                username: author.username,
                displayName: author.displayName,
                seedWorkIds: works.map(\.id),
                into: context
            )
            withAnimation(.easeInOut(duration: 0.2)) { isFollowingAuthor = newState }
        } label: {
            Label(isFollowingAuthor ? "Following" : "Follow",
                  systemImage: isFollowingAuthor ? "person.fill.checkmark" : "person.badge.plus")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(isFollowingAuthor
                            ? "Unfollow \(author.displayName)"
                            : "Follow \(author.displayName)")
    }

    private func loadFirst() async {
        guard works.isEmpty else { return }  // don't refetch when returning from a work
        isLoading = true
        errorMessage = nil
        sessionExpired = false
        defer { isLoading = false }
        do {
            // A guest page while signed in leaves out restricted works.
            let result = try auth.check(await client.fetchAuthorWorks(username: author.username, page: 1))
            works = result.works
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            sessionExpired = auth.explains(error)
            errorMessage = sessionExpired ? AuthState.message(for: error) : error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, currentPage < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try auth.check(await client.fetchAuthorWorks(username: author.username, page: currentPage + 1))
            let existing = Set(works.map(\.id))
            works.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            sessionExpired = auth.explains(error)
            errorMessage = sessionExpired ? AuthState.message(for: error) : error.localizedDescription
        }
    }
}

/// The "Authors" tab: the list of authors the user follows. Tapping one opens
/// their works; the background poller notifies when a followed author posts a
/// new work. Follows are added from an author's works page (the Follow button).
struct FollowedAuthorsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor<FollowedAuthor>(\.displayName, order: .forward)])
    private var authors: [FollowedAuthor]

    var body: some View {
        Group {
            if authors.isEmpty {
                ContentUnavailableView {
                    Label("No followed authors", systemImage: "person.2")
                } description: {
                    Text("Open an author's page — from a work's byline or “More by this author” — and tap Follow. New works they post will notify you here.")
                }
            } else {
                List {
                    ForEach(authors) { author in
                        NavigationLink(value: AuthorRef(username: author.username, displayName: author.displayName)) {
                            FollowedAuthorRow(author: author)
                        }
                    }
                    .onDelete(perform: unfollow)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Followed Authors")
        .navigationBarTitleDisplayMode(.large)
        .workAndAuthorDestinations()
    }

    private func unfollow(at offsets: IndexSet) {
        for index in offsets {
            context.delete(authors[index])
        }
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
    }
}

private struct FollowedAuthorRow: View {
    let author: FollowedAuthor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(author.displayName).font(.headline)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "person").font(.caption2)
                        .accessibilityHidden(true)
                    Text("Author").font(.caption)
                }
                .foregroundStyle(.secondary)
                if let checked = author.lastCheckedAt {
                    Text("checked \(checked, style: .relative) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
    }
}

extension View {
    /// Push destinations shared by every stack that can reach a work, an
    /// author or a series: a work summary (or a series' next work) opens the
    /// reader; an `AuthorRef` opens that author's works; a `SeriesRef` opens
    /// the series page. Apply once per `NavigationStack` root.
    func workAndAuthorDestinations() -> some View {
        self
            .navigationDestination(for: AO3WorkSummary.self) { WorkDetailView(workId: $0.id) }
            .navigationDestination(for: AuthorRef.self) { AuthorWorksView(author: $0) }
            .navigationDestination(for: SeriesRef.self) { SeriesView(series: $0) }
            .navigationDestination(for: SeriesWorkRef.self) { WorkDetailView(workId: $0.workId) }
    }
}

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
    @Query private var hiddenWorks: [HiddenWork]
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true
    let author: AuthorRef

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
            if isLoading && works.isEmpty {
                VStack { Spacer(); ProgressView("Loading…"); Spacer() }
            } else if let errorMessage, works.isEmpty {
                ContentUnavailableView("Couldn't load works", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else if visibleWorks.isEmpty {
                ContentUnavailableView("No works to show", systemImage: "person.slash",
                    description: Text("This author has no visible works, or they're all filtered out by your content settings."))
            } else {
                List {
                    ForEach(visibleWorks) { work in
                        NavigationLink(value: work) { WorkRow(work: work) }
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
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(author.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadFirst() }
    }

    private func loadFirst() async {
        guard works.isEmpty else { return }  // don't refetch when returning from a work
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.fetchAuthorWorks(username: author.username, page: 1)
            works = result.works
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, currentPage < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await client.fetchAuthorWorks(username: author.username, page: currentPage + 1)
            let existing = Set(works.map(\.id))
            works.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            errorMessage = "\(error)"
        }
    }
}

extension View {
    /// Push destinations shared by every stack that can reach a work or an
    /// author: a work summary opens the reader; an `AuthorRef` opens that
    /// author's works. Apply once per `NavigationStack` root.
    func workAndAuthorDestinations() -> some View {
        self
            .navigationDestination(for: AO3WorkSummary.self) { WorkDetailView(workId: $0.id) }
            .navigationDestination(for: AuthorRef.self) { AuthorWorksView(author: $0) }
    }
}

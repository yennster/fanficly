import SwiftUI
import SwiftData

/// Main-navigation history of fics the user has opened, most recent first.
/// Entries are written by `WorkDetailView` and `SavedWorkReader` via
/// `WorkPersistence.recordView`. Rows are `WorkRow`s, like AO3 History's:
/// reading badge, stats, summary and the bookmark button.
struct RecentlyViewedView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecentlyViewed.viewedAt, order: .reverse) private var recents: [RecentlyViewed]
    @State private var showingClearConfirmation = false
    @State private var badges: [Int: ResultBadge] = [:]
    /// Library copies of the entries' stories. A saved story's copy wins over
    /// the entry's snapshot, which can be older: the bookmark button writes
    /// the row's summary over the saved Work.
    @State private var savedSummaries: [Int: AO3WorkSummary] = [:]

    var body: some View {
        Group {
            if recents.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Fics you open will appear here, newest first.")
                )
            } else {
                List {
                    ForEach(recents) { item in
                        NavigationLink(value: item.ao3Id) {
                            let summary = rowSummary(for: item)
                            // An entry with no details anywhere hides the
                            // bookmark button: saving from it would put an
                            // empty record in the Library.
                            WorkRow(work: summary, badge: badges[item.ao3Id],
                                    showsBookmark: item.hasDetails || savedSummaries[item.ao3Id] != nil)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                remove(item)
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    // Enables Edit-mode multi-select delete in addition to swipe.
                    .onDelete(perform: removeAt)
                }
                .listStyle(.plain)
                .toolbar { EditButton() }
                .onAppear(perform: refresh)
                .onChange(of: recents.map(\.ao3Id)) { refresh() }
            }
        }
        .navigationTitle("Recently Viewed")
        .navigationDestination(for: Int.self) { id in
            WorkDetailView(workId: id)
        }
        .workAndAuthorDestinations()
        .toolbar {
            if !recents.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { showingClearConfirmation = true }
                }
            }
        }
        .confirmationDialog(
            "Clear recently viewed?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive, action: clearAll)
        } message: {
            Text("This removes all \(recents.count) entries. It won't delete anything from AO3 or your library.")
        }
    }

    /// The Library's copy of a saved story, else the entry's own details
    /// (title, author and fandom alone for an entry recorded before the
    /// history kept details).
    private func rowSummary(for item: RecentlyViewed) -> AO3WorkSummary {
        savedSummaries[item.ao3Id] ?? item.workSummary
    }

    /// Reloads the Library copies, then the badges from them (the
    /// `.resultBadges(for:into:)` lookup, run after the copies are in so a
    /// saved story's completion counts).
    private func refresh() {
        let ids = recents.map(\.ao3Id)
        let saved = ids.isEmpty ? [] : (try? context.fetch(FetchDescriptor<Work>(predicate: #Predicate { ids.contains($0.ao3Id) }))) ?? []
        savedSummaries = Dictionary(saved.map { ($0.ao3Id, $0.workSummary) }, uniquingKeysWith: { first, _ in first })
        badges = WorkPersistence.resultBadges(for: recents.map(rowSummary(for:)), in: context)
    }

    private func remove(_ item: RecentlyViewed) {
        context.delete(item)
        try? context.save()
    }

    private func removeAt(_ offsets: IndexSet) {
        for index in offsets { context.delete(recents[index]) }
        try? context.save()
    }

    private func clearAll() {
        for item in recents { context.delete(item) }
        try? context.save()
    }
}

#Preview {
    NavigationStack { RecentlyViewedView() }
        .environment(\.ao3Client, MockAO3Client())
}

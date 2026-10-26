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
    /// Library copies of entries recorded before the history kept story
    /// details, so those rows can still show them.
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
                .resultBadges(for: recents.map(rowSummary(for:)), into: $badges)
                .onAppear(perform: loadSavedSummaries)
                .onChange(of: recents.map(\.ao3Id)) { loadSavedSummaries() }
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

    /// The entry's own details, or the Library's for an entry recorded
    /// before the history kept them.
    private func rowSummary(for item: RecentlyViewed) -> AO3WorkSummary {
        if !item.hasDetails, let saved = savedSummaries[item.ao3Id] { return saved }
        return item.workSummary
    }

    private func loadSavedSummaries() {
        let ids = recents.filter { !$0.hasDetails }.map(\.ao3Id)
        guard !ids.isEmpty else { savedSummaries = [:]; return }
        let saved = (try? context.fetch(FetchDescriptor<Work>(predicate: #Predicate { ids.contains($0.ao3Id) }))) ?? []
        savedSummaries = Dictionary(saved.map { ($0.ao3Id, $0.workSummary) }, uniquingKeysWith: { first, _ in first })
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

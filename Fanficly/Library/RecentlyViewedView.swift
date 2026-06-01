import SwiftUI
import SwiftData

/// Main-navigation history of fics the user has opened, most recent first.
/// Entries are written by `WorkDetailView` via `WorkPersistence.recordView`.
struct RecentlyViewedView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecentlyViewed.viewedAt, order: .reverse) private var recents: [RecentlyViewed]
    @State private var showingClearConfirmation = false

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
                            RecentlyViewedRow(item: item)
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
            }
        }
        .navigationTitle("Recently Viewed")
        .navigationDestination(for: Int.self) { id in
            WorkDetailView(workId: id)
        }
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

/// Mirrors `LibraryRow`'s visual hierarchy so the two lists feel like one app.
/// `RecentlyViewed` carries less metadata than `Work` (no rating/word/chapter
/// counts), so those rows are omitted rather than faked.
struct RecentlyViewedRow: View {
    let item: RecentlyViewed

    private var fandomShort: String {
        guard !item.fandom.isEmpty else { return "" }
        return item.fandom.components(separatedBy: " - ").first ?? item.fandom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.headline)
            if !item.author.isEmpty {
                Text("by \(item.author)").font(.subheadline).foregroundStyle(.secondary)
            }
            if !fandomShort.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: FandomCatalog.symbol(for: item.fandom)).font(.caption2)
                    Text(fandomShort).font(.caption)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack { RecentlyViewedView() }
        .environment(\.ao3Client, MockAO3Client())
}

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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.body).lineLimit(2)
                                if !item.author.isEmpty {
                                    Text(item.author).font(.caption).foregroundStyle(.secondary)
                                }
                                if !item.fandom.isEmpty {
                                    Text(item.fandom).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
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
        .navigationBarTitleDisplayMode(.inline)
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

#Preview {
    NavigationStack { RecentlyViewedView() }
        .environment(\.ao3Client, MockAO3Client())
}

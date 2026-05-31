import SwiftUI
import SwiftData

/// Main-navigation history of fics the user has opened, most recent first.
/// Entries are written by `WorkDetailView` via `WorkPersistence.recordView`.
struct RecentlyViewedView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecentlyViewed.viewedAt, order: .reverse) private var recents: [RecentlyViewed]

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
                                context.delete(item); try? context.save()
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Recently Viewed")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Int.self) { id in
            WorkDetailView(workId: id)
        }
        .toolbar {
            if !recents.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        for r in recents { context.delete(r) }
                        try? context.save()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack { RecentlyViewedView() }
        .environment(\.ao3Client, MockAO3Client())
}

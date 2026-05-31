import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Work.savedAt, order: .reverse) private var works: [Work]
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if works.isEmpty {
                ContentUnavailableView(
                    "Nothing saved yet",
                    systemImage: "books.vertical",
                    description: Text("Tap 'Save offline' on any work to add it here.")
                )
            } else {
                List {
                    ForEach(works) { work in
                        NavigationLink(value: work) {
                            LibraryRow(work: work)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(work)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: Work.self) { work in
            ReaderView(work: work)
                .toolbar {
                    if let url = WorkPersistence.epubURL(workId: work.ao3Id) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }

    private func delete(_ work: Work) {
        if let url = WorkPersistence.epubURL(workId: work.ao3Id) {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(work)
        try? context.save()
    }
}

struct LibraryRow: View {
    let work: Work

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(work.title).font(.headline)
            Text("by \(work.authorName)").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(work.rating).font(.caption).foregroundStyle(.secondary)
                if work.wordCount > 0 {
                    Text("\(work.wordCount.formatted()) words").font(.caption).foregroundStyle(.secondary)
                }
                if let total = work.totalChapters {
                    Text("\(work.chapterCount)/\(total)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack { LibraryView() }
}

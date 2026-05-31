import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Work.savedAt, order: .reverse) private var works: [Work]
    @Environment(\.modelContext) private var context
    @State private var filter: LibraryFilter = .all

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case following = "Following"
        case downloaded = "Downloaded"
        var id: String { rawValue }
    }

    private var filtered: [Work] {
        switch filter {
        case .all:        works
        case .following:  works.filter(\.isFollowed)
        case .downloaded: works.filter { WorkPersistence.epubURL(workId: $0.ao3Id) != nil }
        }
    }

    var body: some View {
        Group {
            if works.isEmpty {
                ContentUnavailableView(
                    "Nothing saved yet",
                    systemImage: "books.vertical",
                    description: Text("Tap the bookmark to follow a story, or 'Save offline' to download it for reading without a connection. No AO3 account needed.")
                )
            } else {
                List {
                    Section {
                        Picker("Filter", selection: $filter) {
                            ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    }
                    ForEach(filtered) { work in
                        NavigationLink(value: work) {
                            LibraryRow(work: work, downloaded: WorkPersistence.epubURL(workId: work.ao3Id) != nil)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(work)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            if work.isFollowed {
                                Button {
                                    work.isFollowed = false
                                    work.followedAt = nil
                                    try? context.save()
                                } label: {
                                    Label("Unfollow", systemImage: "bookmark.slash")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: Work.self) { work in
            SavedWorkReader(work: work)
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
    let downloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if work.isFollowed {
                    Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Color.accentColor)
                }
                if downloaded {
                    Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.green)
                }
                Text(work.title).font(.headline)
            }
            Text("by \(work.authorName)").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(work.rating).font(.caption).foregroundStyle(.secondary)
                if work.wordCount > 0 {
                    Text("\(work.wordCount.formatted()) words").font(.caption).foregroundStyle(.secondary)
                }
                if let total = work.totalChapters {
                    Text(work.chapterCount == total ? "\(total) ch · complete" : "\(work.chapterCount)/\(total) · WIP")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack { LibraryView() }
}

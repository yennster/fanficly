import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Work.savedAt, order: .reverse) private var works: [Work]
    @Environment(\.modelContext) private var context
    @State private var filter: LibraryFilter = .all

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case starred = "Starred"
        case following = "Following"
        case downloaded = "Downloaded"
        var id: String { rawValue }
    }

    private var filtered: [Work] {
        let base: [Work]
        switch filter {
        case .all:        base = works
        case .starred:    base = works.filter(\.isStarred)
        case .following:  base = works.filter(\.isFollowed)
        case .downloaded: base = works.filter { WorkPersistence.epubURL(workId: $0.ao3Id) != nil }
        }
        
        return base.sorted { a, b in
            if a.isPinned != b.isPinned {
                return a.isPinned && !b.isPinned
            }
            return a.savedAt > b.savedAt
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
                        .swipeActions(edge: .leading) {
                            Button {
                                work.isStarred.toggle()
                                try? context.save()
                            } label: {
                                Label(work.isStarred ? "Unstar" : "Star", systemImage: work.isStarred ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                            
                            Button {
                                work.isPinned.toggle()
                                try? context.save()
                            } label: {
                                Label(work.isPinned ? "Unpin" : "Pin", systemImage: work.isPinned ? "pin.slash" : "pin")
                            }
                            .tint(.blue)
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
        .workAndAuthorDestinations()
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

    /// Show the first fandom, shortened from AO3's canonical form
    /// ("Harry Potter - J. K. Rowling" → "Harry Potter"), plus a count
    /// if the work spans more than one.
    private var fandomLabel: String {
        guard let first = work.fandoms.first else { return "" }
        let short = first.components(separatedBy: " - ").first ?? first
        let extra = work.fandoms.count - 1
        return extra > 0 ? "\(short)  +\(extra)" : short
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if work.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.blue)
                }
                if work.isStarred {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
                if downloaded {
                    Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.green)
                }
                Text(work.title).font(.headline)
            }
            Text("by \(work.authorName)").font(.subheadline).foregroundStyle(.secondary)
            if let firstFandom = work.fandoms.first {
                HStack(spacing: 4) {
                    Image(systemName: FandomCatalog.symbol(for: firstFandom)).font(.caption2)
                    Text(fandomLabel).font(.caption)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
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

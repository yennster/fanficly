import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Work.savedAt, order: .reverse) private var works: [Work]
    @Query(sort: \CustomFolder.name) private var folders: [CustomFolder]
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var filter: LibraryFilter = .all
    @State private var showingCreateFolderAlert = false
    @State private var newFolderName = ""
    @State private var workMovingToFolder: Work?
    @State private var searchText = ""

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case starred = "Starred"
        case downloaded = "Downloaded"
        case folders = "Folders"
        var id: String { rawValue }

        var title: String { rawValue }

        var compactTitle: String {
            switch self {
            case .downloaded: "Offline"
            default: rawValue
            }
        }

        var symbol: String {
            switch self {
            case .all:        "books.vertical"
            case .starred:    "star"
            case .downloaded: "arrow.down.circle"
            case .folders:    "folder"
            }
        }
    }

    private var usesCompactFilterBar: Bool {
        horizontalSizeClass == .compact
    }

    private var filtered: [Work] {
        var base: [Work]
        switch filter {
        case .all:        base = works
        case .starred:    base = works.filter(\.isStarred)
        case .downloaded: base = works.filter { WorkPersistence.epubURL(workId: $0.ao3Id) != nil }
        case .folders:    base = []
        }
        
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            base = base.filter { $0.matches(query: query) }
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
                        Group {
                            if usesCompactFilterBar {
                                LibraryFilterBar(selection: $filter)
                            } else {
                                Picker("Filter", selection: $filter) {
                                    ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 8, trailing: 12))
                    }
                    if filter == .folders {
                        Section {
                            Button {
                                showingCreateFolderAlert = true
                            } label: {
                                Label("New Folder...", systemImage: "folder.badge.plus")
                                    .foregroundStyle(Color.accentColor)
                            }
                            
                            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            let filteredFolders = query.isEmpty ? folders : folders.filter { $0.name.lowercased().contains(query) }
                            ForEach(filteredFolders) { folder in
                                NavigationLink(value: folder) {
                                    HStack {
                                        Image(systemName: "folder").foregroundStyle(.blue)
                                        Text(folder.name).font(.headline)
                                        Spacer()
                                        Text("\(folder.works.count) stories")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                    .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteFolder(folder)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } else {
                        ForEach(filtered) { work in
                            NavigationLink(value: work) {
                                LibraryRow(work: work, downloaded: WorkPersistence.epubURL(workId: work.ao3Id) != nil)
                            }
                            .hoverEffect(.highlight)
                            .help("Read \(work.title)")
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
                                        iCloudSyncManager.shared.queueBackup(context: context)
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
                                    iCloudSyncManager.shared.queueBackup(context: context)
                                } label: {
                                    Label(work.isStarred ? "Unstar" : "Star", systemImage: work.isStarred ? "star.slash" : "star")
                                }
                                .tint(.yellow)
                                
                                Button {
                                    work.isPinned.toggle()
                                    try? context.save()
                                    iCloudSyncManager.shared.queueBackup(context: context)
                                } label: {
                                    Label(work.isPinned ? "Unpin" : "Pin", systemImage: work.isPinned ? "pin.slash" : "pin")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                NavigationLink(value: work) {
                                    Label("Read Now", systemImage: "book")
                                }
                                
                                Button {
                                    work.isStarred.toggle()
                                    try? context.save()
                                    iCloudSyncManager.shared.queueBackup(context: context)
                                } label: {
                                    Label(work.isStarred ? "Unstar" : "Star", systemImage: work.isStarred ? "star.slash" : "star")
                                }
                                
                                Button {
                                    work.isPinned.toggle()
                                    try? context.save()
                                    iCloudSyncManager.shared.queueBackup(context: context)
                                } label: {
                                    Label(work.isPinned ? "Unpin" : "Pin", systemImage: work.isPinned ? "pin.slash" : "pin")
                                }
                                
                                Button {
                                    workMovingToFolder = work
                                } label: {
                                    Label("Move to Folder...", systemImage: "folder")
                                }
                                
                                if let url = URL(string: "https://archiveofourown.org/works/\(work.ao3Id)") {
                                    ShareLink(item: url, subject: Text(work.title), message: Text("Check out this story: \(work.title)")) {
                                        Label("Share Story...", systemImage: "square.and.arrow.up")
                                    }
                                }
                                
                                Divider()
                                
                                Button(role: .destructive) {
                                    delete(work)
                                } label: {
                                    Label("Delete from Library", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if filter != .folders && filtered.isEmpty && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else if filter == .folders && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if !folders.contains(where: { $0.name.lowercased().contains(query) }) {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles, authors, or tags")
        .navigationDestination(for: Work.self) { work in
            SavedWorkReader(work: work)
        }
        .navigationDestination(for: CustomFolder.self) { folder in
            FolderDetailView(folder: folder)
        }
        .workAndAuthorDestinations()
        .sheet(item: $workMovingToFolder) { work in
            FolderSelectionSheet(work: work)
        }
        .alert("New Folder", isPresented: $showingCreateFolderAlert) {
            TextField("Folder Name", text: $newFolderName)
            Button("Create") {
                createFolder()
            }
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
    }

    private func delete(_ work: Work) {
        if let url = WorkPersistence.epubURL(workId: work.ao3Id) {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(work)
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
    }

    private func deleteFolder(_ folder: CustomFolder) {
        context.delete(folder)
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        
        let descriptor = FetchDescriptor<CustomFolder>(predicate: #Predicate { $0.name == name })
        let existing = (try? context.fetch(descriptor))?.first
        if existing == nil {
            let newFolder = CustomFolder(name: name)
            context.insert(newFolder)
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
        }
        newFolderName = ""
    }
}

private struct LibraryFilterBar: View {
    @Binding var selection: LibraryView.LibraryFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryView.LibraryFilter.allCases) { filter in
                    Button {
                        selection = filter
                    } label: {
                        Label(filter.compactTitle, systemImage: filter.symbol)
                            .font(.subheadline.weight(selection == filter ? .semibold : .medium))
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(selection == filter ? Color.accentColor : .primary)
                            .background {
                                Capsule()
                                    .fill(selection == filter ? Color.accentColor.opacity(0.14) : Color(.secondarySystemFill))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(filter.title)
                    .accessibilityValue(selection == filter ? "Selected" : "")
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
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

    private var metadataItems: [String] {
        var items = [work.rating]
        if work.wordCount > 0 {
            items.append("\(work.wordCount.formatted()) words")
        }
        if let total = work.totalChapters {
            items.append(work.chapterCount == total ? "\(total) ch complete" : "\(work.chapterCount)/\(total) WIP")
        }
        if let folder = work.folder {
            items.append(folder.name)
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(work.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                LibraryStatusBadges(
                    pinned: work.isPinned,
                    starred: work.isStarred,
                    downloaded: downloaded
                )
            }
            Text("by \(work.authorName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let firstFandom = work.fandoms.first {
                HStack(spacing: 4) {
                    Image(systemName: FandomCatalog.symbol(for: firstFandom)).font(.caption2)
                    Text(fandomLabel).font(.caption)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            FlowLayout(spacing: 6, lineSpacing: 5) {
                ForEach(metadataItems, id: \.self) { item in
                    LibraryMetadataPill(text: item, isFolder: work.folder?.name == item)
                }
            }
        }
        .padding(.vertical, 6)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
    }
}

private struct LibraryStatusBadges: View {
    let pinned: Bool
    let starred: Bool
    let downloaded: Bool

    var body: some View {
        HStack(spacing: 5) {
            if pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Pinned")
            }
            if starred {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Starred")
            }
            if downloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryMetadataPill: View {
    let text: String
    var isFolder = false

    var body: some View {
        HStack(spacing: 4) {
            if isFolder {
                Image(systemName: "folder")
                    .font(.caption2)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(isFolder ? Color.accentColor : .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(isFolder ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill))
        }
    }
}

#Preview {
    NavigationStack { LibraryView() }
}

struct FolderDetailView: View {
    let folder: CustomFolder
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            ForEach(folder.works.sorted { $0.savedAt > $1.savedAt }) { work in
                NavigationLink(value: work) {
                    LibraryRow(work: work, downloaded: WorkPersistence.epubURL(workId: work.ao3Id) != nil)
                }
                .hoverEffect(.highlight)
                .help("Read \(work.title)")
                .contextMenu {
                    NavigationLink(value: work) {
                        Label("Read Now", systemImage: "book")
                    }
                    
                    Button {
                        work.isStarred.toggle()
                        try? context.save()
                        iCloudSyncManager.shared.queueBackup(context: context)
                    } label: {
                        Label(work.isStarred ? "Unstar" : "Star", systemImage: work.isStarred ? "star.slash" : "star")
                    }
                    
                    Button {
                        work.isPinned.toggle()
                        try? context.save()
                        iCloudSyncManager.shared.queueBackup(context: context)
                    } label: {
                        Label(work.isPinned ? "Unpin" : "Pin", systemImage: work.isPinned ? "pin.slash" : "pin")
                    }
                    
                    if let url = URL(string: "https://archiveofourown.org/works/\(work.ao3Id)") {
                        ShareLink(item: url, subject: Text(work.title), message: Text("Check out this story: \(work.title)")) {
                            Label("Share Story...", systemImage: "square.and.arrow.up")
                        }
                    }
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        work.folder = nil
                        try? context.save()
                        iCloudSyncManager.shared.queueBackup(context: context)
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FolderSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomFolder.name) private var folders: [CustomFolder]
    let work: Work
    
    @State private var showingCreateFolderAlert = false
    @State private var newFolderName = ""
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        work.folder = nil
                        try? context.save()
                        iCloudSyncManager.shared.queueBackup(context: context)
                        dismiss()
                    } label: {
                        HStack {
                            Label("None (Remove from Folder)", systemImage: "folder.badge.minus")
                                .foregroundStyle(.red)
                            Spacer()
                            if work.folder == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                
                Section("All Folders") {
                    ForEach(folders) { folder in
                        Button {
                            work.folder = folder
                            try? context.save()
                            iCloudSyncManager.shared.queueBackup(context: context)
                            dismiss()
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                if work.folder?.id == folder.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.grouped)
            .navigationTitle("Move to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreateFolderAlert = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .alert("New Folder", isPresented: $showingCreateFolderAlert) {
                TextField("Folder Name", text: $newFolderName)
                Button("Create") {
                    createFolder()
                }
                Button("Cancel", role: .cancel) {
                    newFolderName = ""
                }
            } message: {
                Text("Enter a name for the new folder.")
            }
        }
    }
    
    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        
        let descriptor = FetchDescriptor<CustomFolder>(predicate: #Predicate { $0.name == name })
        let existing = (try? context.fetch(descriptor))?.first
        if existing == nil {
            let newFolder = CustomFolder(name: name)
            context.insert(newFolder)
            work.folder = newFolder
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
            dismiss()
        }
        newFolderName = ""
    }
}

extension Work {
    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        return title.lowercased().contains(trimmed) ||
            authorName.lowercased().contains(trimmed) ||
            fandoms.contains { $0.lowercased().contains(trimmed) } ||
            characters.contains { $0.lowercased().contains(trimmed) } ||
            relationships.contains { $0.lowercased().contains(trimmed) } ||
            freeforms.contains { $0.lowercased().contains(trimmed) } ||
            rating.lowercased().contains(trimmed) ||
            warnings.contains { $0.lowercased().contains(trimmed) } ||
            categories.contains { $0.lowercased().contains(trimmed) }
    }
}

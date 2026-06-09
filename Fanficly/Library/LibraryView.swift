import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Work.savedAt, order: .reverse) private var works: [Work]
    @Query(sort: \CustomFolder.name) private var folders: [CustomFolder]
    @Environment(\.modelContext) private var context
    @State private var filter: LibraryFilter = .all
    @State private var showingCreateFolderAlert = false
    @State private var newFolderName = ""
    @State private var workMovingToFolder: Work?

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case starred = "Starred"
        case following = "Following"
        case downloaded = "Downloaded"
        case folders = "Folders"
        var id: String { rawValue }
    }

    private var filtered: [Work] {
        let base: [Work]
        switch filter {
        case .all:        base = works
        case .starred:    base = works.filter(\.isStarred)
        case .following:  base = works.filter(\.isFollowed)
        case .downloaded: base = works.filter { WorkPersistence.epubURL(workId: $0.ao3Id) != nil }
        case .folders:    base = []
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
                    if filter == .folders {
                        Section {
                            Button {
                                showingCreateFolderAlert = true
                            } label: {
                                Label("New Folder...", systemImage: "folder.badge.plus")
                                    .foregroundStyle(Color.accentColor)
                            }
                            
                            ForEach(folders) { folder in
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
            }
        }
        .navigationTitle("Library")
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
                if let folder = work.folder {
                    Text("📁 \(folder.name)").font(.caption).foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
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

import SwiftUI
import SwiftData
import UIKit

struct LibraryView: View {
    @Query(sort: \Work.savedAt, order: .reverse) private var works: [Work]
    @Query(sort: \CustomFolder.name) private var folders: [CustomFolder]
    @Query private var readingStats: [ReadingStat]
    @AppStorage("app.selectedTabRaw") private var selectedTabRaw: String = "search"
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
                    if !readingStats.isEmpty {
                        Section {
                            Button {
                                selectedTabRaw = SidebarItem.stats.rawValue
                            } label: {
                                LibraryStatsStrip(
                                    summary: ReadingStatsAggregator.summarize(readingStats.map(\.snapshot), interval: nil),
                                    streak: StreakStore.loadStreakInfo().currentStreak
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
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
                            let filteredFolders = query.isEmpty ? folders : folders.filter {
                                $0.name.lowercased().contains(query) || $0.works.contains(where: { $0.matches(query: query) })
                            }
                            ForEach(filteredFolders) { folder in
                                NavigationLink(value: folder) {
                                    HStack {
                                        Image(systemName: "folder").foregroundStyle(.blue)
                                        Text(folder.name).font(.headline)
                                        Spacer()
                                        let totalCount = folder.works.count
                                        let matchingCount = query.isEmpty ? totalCount : folder.works.filter { $0.matches(query: query) }.count
                                        if query.isEmpty {
                                            Text("\(totalCount) stories")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("\(matchingCount) of \(totalCount) stories")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
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
                                // Following tracks new chapters, so it's only
                                // meaningful for in-progress works — hide Unfollow
                                // on completed ones (nothing new will ever drop).
                                if work.isFollowed && !work.isComplete {
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

                                if !work.authorUsername.isEmpty {
                                    NavigationLink(value: AuthorRef(username: work.authorUsername, displayName: work.authorName)) {
                                        Label("More by this author", systemImage: "person.crop.circle")
                                    }
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
                                    Label("Folders...", systemImage: "folder")
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
            FolderDetailView(folder: folder, initialSearchText: searchText)
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
    @AppStorage("library.showReadingProgress") private var showReadingProgress = true

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
        } else if work.chapterCount > 0 {
            // WIP whose author hasn't declared a final chapter count (AO3 shows
            // "12/?"). Still surface progress here, mirroring the search row and
            // reader header — otherwise the chapter/WIP badge silently vanishes.
            items.append("\(work.chapterCount)/? WIP")
        }
        for folder in work.folders.sorted(by: { $0.name < $1.name }) {
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
                    let isFolder = work.folders.contains(where: { $0.name == item })
                    LibraryMetadataPill(text: item, isFolder: isFolder)
                }
            }

            if showReadingProgress {
                readingProgress
            }
        }
        .padding(.vertical, 6)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
    }

    /// Reading-progress strip: a bar plus a "% read · Ch n · last read …" line,
    /// shown for any work the user has started. Finished works read "Finished"
    /// instead of a near-full bar.
    @ViewBuilder
    private var readingProgress: some View {
        if let raw = work.lastReadProgress, raw > 0 {
            let progress = min(max(raw, 0), 1)
            let finished = progress >= 0.99 || (work.isComplete && progress >= 0.95)
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress)
                    .tint(finished ? .green : .accentColor)
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)
                HStack(spacing: 6) {
                    if finished {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Finished")
                        }
                        .foregroundStyle(.green)
                    } else {
                        Text("\(Int(progress * 100))% read")
                        if let chapter = work.lastReadChapter, (work.totalChapters ?? 0) > 1 {
                            Text("· Ch \(chapter)")
                        }
                    }
                    Spacer(minLength: 4)
                    if let lastReadAt = work.lastReadAt {
                        Text(lastReadAt, format: .relative(presentation: .named))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(finished ? "Finished reading" : "\(Int(progress * 100)) percent read")
        }
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
            // A rounded rectangle, not a Capsule: a capsule's semicircular left
            // cap only touches the leading edge at its vertical center, so the
            // pill reads as inset from the flush title/author text. A near-
            // vertical left edge lines the pills up with the text.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isFolder ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill))
        }
    }
}

#Preview {
    NavigationStack { LibraryView() }
}

struct FolderDetailView: View {
    let folder: CustomFolder
    @State private var searchText: String
    @Environment(\.modelContext) private var context

    @State private var editMode: EditMode = .inactive
    @State private var selectedWorkIds = Set<PersistentIdentifier>()

    init(folder: CustomFolder, initialSearchText: String = "") {
        self.folder = folder
        self._searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredWorks = query.isEmpty ? folder.works : folder.works.filter { $0.matches(query: query) }
        let sortedWorks = filteredWorks.sorted { $0.savedAt > $1.savedAt }

        VStack(spacing: 0) {
            List(selection: $selectedWorkIds) {
                ForEach(sortedWorks) { work in
                    if editMode == .active {
                        LibraryRow(work: work, downloaded: WorkPersistence.epubURL(workId: work.ao3Id) != nil)
                            .tag(work.id)
                    } else {
                        NavigationLink(value: work) {
                            LibraryRow(work: work, downloaded: WorkPersistence.epubURL(workId: work.ao3Id) != nil)
                        }
                        .hoverEffect(.highlight)
                        .help("Read \(work.title)")
                        .contextMenu {
                            NavigationLink(value: work) {
                                Label("Read Now", systemImage: "book")
                            }

                            if !work.authorUsername.isEmpty {
                                NavigationLink(value: AuthorRef(username: work.authorUsername, displayName: work.authorName)) {
                                    Label("More by this author", systemImage: "person.crop.circle")
                                }
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
                                work.folders.removeAll { $0.id == folder.id }
                                try? context.save()
                                iCloudSyncManager.shared.queueBackup(context: context)
                                WidgetDataStore.updateAll(context: context)
                            } label: {
                                Label("Remove from Folder", systemImage: "folder.badge.minus")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)

            if editMode == .active {
                Divider()
                HStack {
                    Button(role: .destructive) {
                        removeSelectedWorks()
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.minus")
                            Text("Remove (\(selectedWorkIds.count))")
                        }
                        .font(.headline)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(selectedWorkIds.isEmpty)
                    .padding()
                }
                .background(.background)
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search stories in folder")
        .overlay {
            if !query.isEmpty && filteredWorks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode == .active ? "Done" : "Edit") {
                    withAnimation {
                        if editMode == .active {
                            editMode = .inactive
                            selectedWorkIds.removeAll()
                        } else {
                            editMode = .active
                        }
                    }
                }
            }
        }
    }

    private func removeSelectedWorks() {
        for workId in selectedWorkIds {
            if let work = folder.works.first(where: { $0.id == workId }) {
                work.folders.removeAll { $0.id == folder.id }
            }
        }
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
        WidgetDataStore.updateAll(context: context)
        
        withAnimation {
            selectedWorkIds.removeAll()
            editMode = .inactive
        }
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
                    Button(role: .destructive) {
                        work.folders = []
                        try? context.save()
                        iCloudSyncManager.shared.queueBackup(context: context)
                    } label: {
                        HStack {
                            Label("Remove from All Folders", systemImage: "folder.badge.minus")
                            Spacer()
                        }
                    }
                    .disabled(work.folders.isEmpty)
                }
                
                Section("All Folders") {
                    ForEach(folders) { folder in
                        Button {
                            if work.folders.contains(where: { $0.id == folder.id }) {
                                work.folders.removeAll { $0.id == folder.id }
                            } else {
                                work.folders.append(folder)
                            }
                            try? context.save()
                            iCloudSyncManager.shared.queueBackup(context: context)
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                if work.folders.contains(where: { $0.id == folder.id }) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.grouped)
            .navigationTitle("Select Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .bold()
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
            work.folders.append(newFolder)
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
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

// MARK: - Reading statistics

/// The period the Stats screen aggregates over. `allTime` has no date interval.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case week, month, year, allTime
    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .allTime: "All Time"
        }
    }

    /// The calendar unit this period steps by; nil for all-time.
    var component: Calendar.Component? {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .allTime: nil
        }
    }
}

/// The Stats tab: reading totals and top fandoms/ships/authors for a chosen
/// period (week / month / year / all-time), with ‹ › to page through periods.
/// Works for everyone, on-device; iCloud only syncs the underlying
/// `ReadingStat` rows and the streak across the user's own devices. Reading
/// time is the real active time the reader was open and foregrounded.
struct StatsView: View {
    @Query private var stats: [ReadingStat]
    @Environment(\.displayScale) private var displayScale
    @Environment(\.calendar) private var calendar

    @State private var period: StatsPeriod = .month
    /// A date inside the period currently shown; ‹ › moves it by one unit.
    @State private var anchor: Date = Date()
    @State private var shareItem: ShareImageItem?

    private var snapshots: [ReadingStatSnapshot] { stats.map(\.snapshot) }

    /// The date interval for the selected period; nil for all-time.
    private var interval: DateInterval? {
        guard let component = period.component else { return nil }
        return calendar.dateInterval(of: component, for: anchor)
    }

    private var summary: ReadingStatsSummary {
        ReadingStatsAggregator.summarize(snapshots, interval: interval, calendar: calendar)
    }

    /// Human label for the current period ("This Week", "June 2026", "2025", …).
    private var scopeTitle: String {
        guard let interval else { return "All Time" }
        switch period {
        case .allTime:
            return "All Time"
        case .week:
            if interval.contains(Date()) { return "This Week" }
            let f = DateFormatter()
            f.calendar = calendar
            f.dateFormat = "MMM d"
            let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return "\(f.string(from: interval.start)) – \(f.string(from: end))"
        case .month:
            let f = DateFormatter()
            f.calendar = calendar
            f.dateFormat = "LLLL yyyy"
            return f.string(from: interval.start)
        case .year:
            return "\(calendar.component(.year, from: interval.start))"
        }
    }

    /// Disable forward paging once the period reaches the one containing today.
    private var canPageForward: Bool {
        guard let interval else { return false }
        return interval.end <= Date()
    }

    /// Disable backward paging when there's no reading data before this period.
    private var canPageBackward: Bool {
        guard let interval,
              let range = ReadingStatsAggregator.dataDateRange(snapshots, calendar: calendar)
        else { return false }
        return range.lowerBound < interval.start
    }

    private func page(_ direction: Int) {
        guard let component = period.component,
              let moved = calendar.date(byAdding: component, value: direction, to: anchor) else { return }
        anchor = moved
    }

    var body: some View {
        Group {
            if stats.isEmpty {
                ContentUnavailableView(
                    "No Reading Stats Yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Open a story in the reader and your reading time, top fandoms, and yearly wrap-up will show up here.")
                )
            } else {
                let summary = summary
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        periodControl
                        headerCards(summary)
                        topList("Top Fandoms", systemImage: "books.vertical", items: summary.topFandoms)
                        topList("Top Categories", systemImage: "person.2.square.stack", items: summary.topCategories)
                        topList("Top Ships", systemImage: "heart", items: summary.topRelationships)
                        topList("Top Authors", systemImage: "person", items: summary.topAuthors)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !stats.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: shareWrap) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share your reading wrap-up")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.image])
        }
    }

    /// Render the wrap-up card to an image and present the share sheet.
    @MainActor private func shareWrap() {
        let card = WrapShareCard(scopeTitle: scopeTitle, summary: summary)
        let renderer = ImageRenderer(content: card)
        renderer.scale = max(displayScale, 2)
        if let image = renderer.uiImage {
            shareItem = ShareImageItem(image: image)
        }
    }

    private var periodControl: some View {
        VStack(spacing: Spacing.sm) {
            Picker("Period", selection: $period) {
                ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            // Reset to the current period when switching granularity.
            .onChange(of: period) { _, _ in anchor = Date() }

            if period != .allTime {
                HStack {
                    Button { page(-1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canPageBackward)

                    Spacer()
                    Text(scopeTitle)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Spacer()

                    Button { page(1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canPageForward)
                }
                .buttonStyle(.borderless)
                .font(.body.weight(.semibold))
            }
        }
    }

    private func headerCards(_ summary: ReadingStatsSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(scopeTitle)
                .font(.title2.bold())
            // Adaptive grid so the four stat tiles wrap nicely on phone & iPad.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)], spacing: Spacing.md) {
                StatTile(value: "\(summary.storiesRead)",
                         label: summary.storiesRead == 1 ? "Story Read" : "Stories Read",
                         systemImage: "book.closed")
                StatTile(value: Self.formatDuration(summary.totalSeconds),
                         label: "Time Read",
                         systemImage: "clock")
                StatTile(value: Self.formatWords(summary.totalWords),
                         label: "Words Read",
                         systemImage: "text.alignleft")
                StatTile(value: "\(StreakStore.loadStreakInfo().currentStreak)",
                         label: "Day Streak",
                         systemImage: "flame")
            }
        }
    }

    @ViewBuilder
    private func topList(_ title: String, systemImage: String, items: [ReadingTagCount]) -> some View {
        if !items.isEmpty {
            let maxCount = items.map(\.count).max() ?? 1
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                ForEach(items) { item in
                    StatBarRow(name: item.name, count: item.count, fraction: Double(item.count) / Double(maxCount))
                }
            }
        }
    }

    /// "12h 34m" / "45m" / "<1m". Active reading time, never zero-padded.
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return total <= 0 ? "0m" : "<1m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// Compact word count: "1.2M", "340K", "8,500".
    static func formatWords(_ words: Int) -> String {
        if words >= 1_000_000 {
            return String(format: "%.1fM", Double(words) / 1_000_000)
        } else if words >= 10_000 {
            return "\(words / 1000)K"
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: words)) ?? "\(words)"
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(value)
                .font(.title.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StatBarRow: View {
    let name: String
    let count: Int
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Compact reading-stats summary shown atop the Library list; taps through to
/// the Stats tab.
private struct LibraryStatsStrip: View {
    let summary: ReadingStatsSummary
    let streak: Int

    var body: some View {
        HStack(spacing: 0) {
            metric(value: "\(summary.storiesRead)", label: "Read", systemImage: "book.closed")
            divider
            metric(value: StatsView.formatDuration(summary.totalSeconds), label: "Time", systemImage: "clock")
            divider
            metric(value: "\(streak)", label: "Streak", systemImage: "flame")
            Spacer(minLength: Spacing.sm)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.lg)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading stats: \(summary.storiesRead) read, \(StatsView.formatDuration(summary.totalSeconds)) read, \(streak) day streak")
        .accessibilityHint("Opens the Stats tab")
    }

    private func metric(value: String, label: String, systemImage: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.tint)
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 1, height: 26)
    }
}

/// Carries a rendered share image into `.sheet(item:)`.
struct ShareImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// A polished, portrait "Year in Review" card rendered to an image for sharing.
/// Sized for a clean 3:4 export; `ImageRenderer` rasterises it off-screen.
struct WrapShareCard: View {
    let scopeTitle: String
    let summary: ReadingStatsSummary

    /// Fanficly brand indigo (#3B2E8C), matching the App Store marketing canvas.
    private let brand = Color(red: 0x3B / 255, green: 0x2E / 255, blue: 0x8C / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("My Reading")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(scopeTitle)
                    .font(.system(size: 34, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 14) {
                bigStat("\(summary.storiesRead)", summary.storiesRead == 1 ? "story" : "stories")
                bigStat(StatsView.formatDuration(summary.totalSeconds), "read")
                bigStat(StatsView.formatWords(summary.totalWords), "words")
            }

            if !summary.topFandoms.isEmpty {
                listBlock("Top Fandoms", items: summary.topFandoms.prefix(4))
            }
            if !summary.topRelationships.isEmpty {
                listBlock("Top Ships", items: summary.topRelationships.prefix(3))
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "book.pages")
                Text("Made with Fanficly")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(28)
        .frame(width: 360, height: 480, alignment: .topLeading)
        .background(
            LinearGradient(colors: [brand, brand.opacity(0.78), .black.opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listBlock(_ title: String, items: ArraySlice<ReadingTagCount>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
            ForEach(Array(items)) { item in
                HStack {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text("\(item.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}

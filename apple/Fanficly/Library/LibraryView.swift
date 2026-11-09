import SwiftUI
import SwiftData
import UIKit

struct LibraryView: View {
    @Query(sort: \Work.savedAt, order: .reverse) private var works: [Work]
    @Query(sort: \CustomFolder.name) private var folders: [CustomFolder]
    @Query private var readingStats: [ReadingStat]
    @AppStorage("app.selectedTabRaw") private var selectedTabRaw: String = "search"
    @AppStorage(LibrarySort.keyStorageKey) private var sortKeyRaw = LibrarySort.default.key.rawValue
    @AppStorage(LibrarySort.ascendingStorageKey) private var sortAscending = LibrarySort.default.ascending
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.undoToastHost) private var undoHost
    @State private var filter: LibraryFilter = .all
    @State private var showingCreateFolderAlert = false
    @State private var newFolderName = ""
    @State private var workMovingToFolder: Work?
    @State private var workEditingNotes: Work?
    @State private var searchText = ""
    @State private var showingEPUBImporter = false
    @State private var epubImport = EPUBImportCenter.shared
    @Environment(\.ao3Client) private var client
    @State private var downloads = LibraryDownloads.shared
    @State private var workRemovingDownload: Work?
    @State private var downloadError: String?
    @State private var folderRenaming: CustomFolder?
    @State private var folderRenameText = ""
    @State private var folderRenameTaken: String?

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

    /// The chip row scrolls, so it also stands in for the segmented filter
    /// (which clips "Downloaded") at accessibility text sizes.
    private var usesCompactFilterBar: Bool {
        horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
    }

    /// The library without works or folders waiting behind the Undo toast.
    private var visibleWorks: [Work] {
        works.filter { !UndoCenter.shared.isPending(UndoCenter.Key.work($0.ao3Id)) }
    }

    private var visibleFolders: [CustomFolder] {
        folders.filter { !UndoCenter.shared.isPending(UndoCenter.Key.folder($0.name)) }
    }

    private var filtered: [Work] {
        let works = visibleWorks
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

        return LibrarySort(keyRaw: sortKeyRaw, ascending: sortAscending).sorted(base)
    }

    var body: some View {
        Group {
            if visibleWorks.isEmpty {
                ContentUnavailableView {
                    Label("Nothing saved yet", systemImage: "books.vertical")
                } description: {
                    Text("Tap the bookmark to follow a story, or 'Save offline' to download it for reading without a connection. No AO3 account needed. Already have EPUB files, like AO3 downloads? Import them to read here.")
                } actions: {
                    Button("Import EPUB…") { showingEPUBImporter = true }
                        .disabled(epubImport.isImporting)
                }
            } else {
                // Read here so a row's Downloaded badge updates when its
                // menu's download ends (#191).
                let _ = downloads.inFlight
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
                            // Sorting rides in this row rather than the nav bar.
                            // In Folders it orders the stories inside each folder.
                            if usesCompactFilterBar {
                                LibraryFilterBar(selection: $filter)
                            } else {
                                HStack(spacing: 10) {
                                    LibrarySortMenu()
                                    Picker("Filter", selection: $filter) {
                                        ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                }
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
                            let folders = visibleFolders
                            let filteredFolders = query.isEmpty ? folders : folders.filter {
                                $0.name.lowercased().contains(query) || $0.works.contains(where: {
                                    $0.matches(query: query) && !UndoCenter.shared.isPending(UndoCenter.Key.work($0.ao3Id))
                                })
                            }
                            ForEach(filteredFolders) { folder in
                                NavigationLink(value: folder) {
                                    // At accessibility text sizes the count goes under the name.
                                    let rowLayout = dynamicTypeSize.isAccessibilitySize
                                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                        : AnyLayout(HStackLayout())
                                    rowLayout {
                                        HStack {
                                            Image(systemName: "folder").foregroundStyle(.blue)
                                                .accessibilityHidden(true)
                                            Text(folder.name).font(.headline)
                                        }
                                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                        let folderWorks = folder.works.filter { !UndoCenter.shared.isPending(UndoCenter.Key.work($0.ao3Id)) }
                                        let totalCount = folderWorks.count
                                        let matchingCount = query.isEmpty ? totalCount : folderWorks.filter { $0.matches(query: query) }.count
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
                                    .accessibilityElement(children: .combine)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteFolder(folder)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                // A mouse can't swipe, so the same actions are here too (#189).
                                .contextMenu {
                                    NavigationLink(value: folder) {
                                        Label("Open", systemImage: "folder")
                                    }
                                    Button {
                                        startRenaming(folder)
                                    } label: {
                                        Label("Rename...", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        deleteFolder(folder)
                                    } label: {
                                        Label("Delete Folder", systemImage: "trash")
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
                                        unfollow(work)
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

                                Button {
                                    workEditingNotes = work
                                } label: {
                                    Label("Note & Tags...", systemImage: "note.text")
                                }

                                // The swipe's Unfollow, for a mouse (#189).
                                if work.isFollowed && !work.isComplete {
                                    Button {
                                        unfollow(work)
                                    } label: {
                                        Label("Unfollow", systemImage: "bookmark.slash")
                                    }
                                }

                                LibraryDownloadMenuItem(work: work) {
                                    download(work)
                                } removeDownload: {
                                    workRemovingDownload = work
                                }
                                
                                if !EPUBImport.isLocalWork(work.ao3Id),
                                   let url = URL(string: "https://archiveofourown.org/works/\(work.ao3Id)") {
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
                        if !visibleFolders.contains(where: { $0.name.lowercased().contains(query) }) {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles, authors, tags, or notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingEPUBImporter = true
                } label: {
                    if epubImport.isImporting {
                        ProgressView()
                    } else {
                        Label("Import EPUB", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(epubImport.isImporting)
                .help("Import EPUB files, like AO3 downloads, to read offline")
                .accessibilityLabel("Import EPUB")
                .accessibilityHint("Adds EPUB files from your device to the Library to read offline.")
            }
        }
        .epubImporter(isPresented: $showingEPUBImporter, context: context)
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
        .sheet(item: $workEditingNotes) { work in
            WorkNotesSheet(work: work)
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
        .folderRenameAlerts(folder: $folderRenaming, name: $folderRenameText,
                            taken: $folderRenameTaken, context: context)
        .libraryDownloadAlerts(removing: $workRemovingDownload, error: $downloadError, context: context)
    }

    private func startRenaming(_ folder: CustomFolder) {
        folderRenameText = folder.name
        folderRenaming = folder
    }

    private func download(_ work: Work) {
        let client = client
        let context = context
        Task {
            if let message = await downloads.download(work, client: client, context: context) {
                downloadError = message
            }
        }
    }

    /// Waits behind the Undo toast (#169): the delete takes the offline
    /// text, EPUB, note, tags and folder links, and AO3 may no longer have it.
    private func delete(_ work: Work) {
        let context = context
        UndoCenter.shared.schedule(String(localized: "Deleted “\(work.title)”"),
                                   keys: [UndoCenter.Key.work(work.ao3Id)],
                                   host: undoHost) {
            guard !work.isDeleted, work.modelContext != nil else { return }
            iCloudSyncManager.recordDeletion(.work, key: String(work.ao3Id))
            WorkPersistence.delete(work, in: context)
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
        }
    }

    /// Stops following a work's new chapters; it stays in the Library.
    private func unfollow(_ work: Work) {
        work.isFollowed = false
        work.followedAt = nil
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
    }

    private func deleteFolder(_ folder: CustomFolder) {
        let context = context
        UndoCenter.shared.schedule(String(localized: "Deleted folder “\(folder.name)”"),
                                   keys: [UndoCenter.Key.folder(folder.name)],
                                   host: undoHost) {
            guard !folder.isDeleted, folder.modelContext != nil else { return }
            iCloudSyncManager.recordDeletion(.folder, key: folder.name)
            context.delete(folder)
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Making it again keeps a folder deleted a moment ago (#169).
        UndoCenter.shared.cancel(UndoCenter.Key.folder(name))
        
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
                LibrarySortMenu()
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
                    .accessibilityAddTraits(selection == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
    }
}

#Preview {
    NavigationStack { LibraryView() }
        .environment(AuthState())
}

struct FolderDetailView: View {
    let folder: CustomFolder
    @State private var searchText: String
    @Environment(\.modelContext) private var context
    @AppStorage(LibrarySort.keyStorageKey) private var sortKeyRaw = LibrarySort.default.key.rawValue
    @AppStorage(LibrarySort.ascendingStorageKey) private var sortAscending = LibrarySort.default.ascending

    @State private var editMode: EditMode = .inactive
    @State private var selectedWorkIds = Set<PersistentIdentifier>()
    @State private var workEditingNotes: Work?
    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    @State private var pendingDownloadIds: [Int]?
    @State private var downloads = LibraryDownloads.shared
    @State private var workRemovingDownload: Work?
    @State private var downloadError: String?
    @State private var folderRenaming: CustomFolder?
    @State private var folderRenameText = ""
    @State private var folderRenameTaken: String?

    init(folder: CustomFolder, initialSearchText: String = "") {
        self.folder = folder
        self._searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Without a work deleted from the Library a moment ago (#169).
        let folderWorks = folder.works.filter { !UndoCenter.shared.isPending(UndoCenter.Key.work($0.ao3Id)) }
        let filteredWorks = query.isEmpty ? folderWorks : folderWorks.filter { $0.matches(query: query) }
        let sortedWorks = LibrarySort(keyRaw: sortKeyRaw, ascending: sortAscending).sorted(filteredWorks)
        // Any run's progress (it also re-renders the rows as each download
        // lands, so their Downloaded badges update).
        let downloadProgress = RestoreDownloadCenter.shared.progress
        // Likewise for a row menu's download (#191).
        let _ = downloads.inFlight

        VStack(spacing: 0) {
            List(selection: $selectedWorkIds) {
                if editMode != .active && !sortedWorks.isEmpty {
                    HStack {
                        Text(sortedWorks.count == 1 ? "1 story" : "\(sortedWorks.count) stories")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        LibrarySortMenu()
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
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

                            Button {
                                workEditingNotes = work
                            } label: {
                                Label("Note & Tags...", systemImage: "note.text")
                            }

                            LibraryDownloadMenuItem(work: work) {
                                download(work)
                            } removeDownload: {
                                workRemovingDownload = work
                            }
                            
                            if !EPUBImport.isLocalWork(work.ao3Id),
                               let url = URL(string: "https://archiveofourown.org/works/\(work.ao3Id)") {
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
                                .accessibilityHidden(true)
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
        .sheet(item: $workEditingNotes) { work in
            WorkNotesSheet(work: work)
        }
        .folderRenameAlerts(folder: $folderRenaming, name: $folderRenameText,
                            taken: $folderRenameTaken, context: context)
        .libraryDownloadAlerts(removing: $workRemovingDownload, error: $downloadError, context: context)
        .confirmationDialog(downloadPromptTitle, isPresented: Binding(
            get: { pendingDownloadIds != nil },
            set: { if !$0 { pendingDownloadIds = nil } }), titleVisibility: .visible,
            presenting: pendingDownloadIds) { ids in
            // `presenting` hands the ids in, so it works whichever order
            // SwiftUI clears the binding and runs the action.
            Button("Download") {
                let client = client
                let context = context
                RestoreDownloadCenter.shared.startFolderDownload(ids: ids, signedIn: auth.isLoggedIn) { id in
                    try await WorkPersistence.saveOffline(workId: id, client: client, context: context)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Stories download one at a time. You can cancel anytime, and the ones already downloaded stay.")
        }
        .overlay {
            if !query.isEmpty && filteredWorks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .toolbar {
            if editMode != .active {
                ToolbarItem(placement: .topBarTrailing) {
                    let downloadIds = RestoreDownloadCenter.folderDownloadCandidates(
                        LibrarySort(keyRaw: sortKeyRaw, ascending: sortAscending).sorted(folderWorks))
                    Button {
                        pendingDownloadIds = downloadIds
                    } label: {
                        Label("Download All", systemImage: "arrow.down.circle")
                    }
                    .disabled(downloadIds.isEmpty || downloadProgress != nil)
                    .help(downloadIds.isEmpty ? "Every story here is downloaded" : "Download every story in this folder for offline reading")
                    .accessibilityHint(downloadIds.isEmpty
                        ? "Every story in this folder is already downloaded."
                        : "Saves \(downloadIds.count) \(downloadIds.count == 1 ? "story" : "stories") for offline reading, one at a time.")
                }
            }
            if editMode != .active {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        folderRenameText = folder.name
                        folderRenaming = folder
                    } label: {
                        Label("Rename Folder", systemImage: "pencil")
                    }
                    .help("Rename this folder")
                }
            }
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

    private func download(_ work: Work) {
        let client = client
        let context = context
        Task {
            if let message = await downloads.download(work, client: client, context: context) {
                downloadError = message
            }
        }
    }

    private var downloadPromptTitle: String {
        let n = pendingDownloadIds?.count ?? 0
        return "Download \(n) \(n == 1 ? "story" : "stories") for offline reading?"
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
                    ForEach(folders.filter { !UndoCenter.shared.isPending(UndoCenter.Key.folder($0.name)) }) { folder in
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
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(work.folders.contains(where: { $0.id == folder.id }) ? .isSelected : [])
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
                    .accessibilityLabel("New folder")
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
        // Making it again keeps a folder deleted a moment ago (#169).
        UndoCenter.shared.cancel(UndoCenter.Key.folder(name))
        
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
            categories.contains { $0.lowercased().contains(trimmed) } ||
            (note?.lowercased().contains(trimmed) ?? false) ||
            personalTags.contains { $0.lowercased().contains(trimmed) }
    }
}

/// Edits a library work's own note and personal tags (RM-009). Presented
/// from the screen, never from the row's context menu (see Conventions).
struct WorkNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let work: Work

    @State private var noteText: String
    @State private var tagsText: String

    init(work: Work) {
        self.work = work
        self._noteText = State(initialValue: work.note ?? "")
        self._tagsText = State(initialValue: work.personalTags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Why you saved it, what to remember…", text: $noteText, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("Note")
                }
                Section {
                    TextField("for a bad day, reread at Christmas", text: $tagsText)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Your Tags")
                } footer: {
                    Text("Separate tags with commas. Library search finds your note and tags. They're saved in your library, and in your iCloud backup if library sync is on.")
                }
            }
            .navigationTitle(work.title)
            .navigationBarTitleDisplayMode(.inline)
            // Swiping down would silently drop typed edits; Cancel is explicit.
            .interactiveDismissDisabled(noteText != (work.note ?? "")
                                        || tagsText != work.personalTags.joined(separator: ", "))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        work.setNotes(note: noteText, tagsText: tagsText)
                        try? context.save()
                        iCloudSyncManager.shared.queueBackup(context: context)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
}

// MARK: - Reading statistics

/// Compact reading-stats summary shown atop the Library list; taps through to
/// the Stats tab.
private struct LibraryStatsStrip: View {
    let summary: ReadingStatsSummary
    let streak: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 0) {
            // Three metrics side by side shrink to unreadable at accessibility
            // text sizes, so they stack there.
            let metrics = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
                : AnyLayout(HStackLayout(spacing: 0))
            metrics {
                metric(value: "\(summary.storiesRead)", label: "Finished", systemImage: "checkmark.circle")
                divider
                metric(value: StatsView.formatDuration(summary.totalSeconds), label: "Time", systemImage: "clock")
                divider
                metric(value: "\(streak)", label: "Streak", systemImage: "flame")
                // Inside the layout, so the metrics and the spacer share the
                // width four ways as before; stacked, the metrics fill it.
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Spacing.sm) }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.lg)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading stats: \(summary.storiesRead) finished, \(StatsView.formatDuration(summary.totalSeconds)) read, \(streak) day streak")
        .accessibilityHint("Opens the Stats tab")
    }

    @ViewBuilder
    private func metric(value: String, label: String, systemImage: String) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: stacked ? .leading : .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.tint)
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                    // Stacked, there's room for the full size; the audit flagged the shrink.
                    .minimumScaleFactor(stacked ? 1 : 0.6)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: stacked ? .leading : .center)
    }

    @ViewBuilder
    private var divider: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 1, height: 26)
        }
    }
}

extension View {
    /// The Rename Folder prompt (#191), shared by the Folders list and a
    /// folder's own screen: the name field, then an alert when another
    /// folder already has the name.
    func folderRenameAlerts(folder: Binding<CustomFolder?>, name: Binding<String>,
                            taken: Binding<String?>, context: ModelContext) -> some View {
        alert("Rename Folder", isPresented: Binding(
            get: { folder.wrappedValue != nil },
            set: { if !$0 { folder.wrappedValue = nil } }),
            presenting: folder.wrappedValue
        ) { target in
            TextField("Folder Name", text: name)
            Button("Rename") {
                guard !target.isDeleted, target.modelContext != nil else { return }
                let newName = name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                switch WorkPersistence.renameFolder(target, to: newName, in: context) {
                case .renamed:
                    iCloudSyncManager.shared.queueBackup(context: context)
                    LibraryDownloads.announce(String(localized: "Renamed folder to \(newName)"))
                case .taken:
                    taken.wrappedValue = newName
                case .unchanged:
                    break
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Enter a new name for the folder.")
        }
        .alert("Name Already Used", isPresented: Binding(
            get: { taken.wrappedValue != nil },
            set: { if !$0 { taken.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("There's already a folder named “\(taken.wrappedValue ?? "")”.")
        }
    }
}

import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedSearch.savedAt, order: .reverse) private var savedSearches: [SavedSearch]
    @Query private var hiddenWorks: [HiddenWork]
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true
    @State private var prompt: String = ""
    @State private var lastParsed: AO3SearchFilters = AO3SearchFilters()
    @State private var results: [AO3WorkSummary] = []
    @State private var currentPage: Int = 1
    @State private var totalPages: Int = 1
    @State private var isSearching: Bool = false
    @State private var hasSearched = false
    @State private var isLoadingMore: Bool = false
    @State private var errorMessage: String?
    @State private var sortColumn: AO3SearchFilters.SortColumn = .bestMatch
    @State private var sortDirection: AO3SearchFilters.SortDirection = .desc
    @State private var showingSaveDialog: Bool = false
    @State private var saveName: String = ""
    @State private var suppressParse: Bool = false
    @State private var filtersResolved: Bool = false
    @State private var showingHelpSheet: Bool = false
    @FocusState private var searchFocused: Bool
    private let parser = SearchPromptParser()
    private let enricher: any SearchEnricher = SearchEnricherFactory.make()

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .workAndAuthorDestinations()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        saveName = suggestName()
                        showingSaveDialog = true
                    } label: {
                        Label("Save this search", systemImage: "bookmark")
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)

                    if !savedSearches.isEmpty {
                        Section("Saved searches") {
                            ForEach(savedSearches) { saved in
                                Button(saved.name) {
                                    load(saved)
                                    searchFocused = false
                                    hasSearched = false
                                    Task { await runSearch() }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "bookmark")
                }
            }
        }
        .alert("Save search", isPresented: $showingSaveDialog) {
            TextField("Name", text: $saveName)
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the prompt and sort options so you can re-run it later.")
        }
        .sheet(isPresented: $showingHelpSheet) {
            SearchHelpView()
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                TextField("e.g. edward/bella romance all human complete", text: $prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit {
                        searchFocused = false
                        Task { await runSearch() }
                    }
                    .onChange(of: prompt) { _, newValue in
                        if suppressParse { return }
                        // A vertical-axis TextField inserts a newline on Return
                        // rather than firing onSubmit. Treat a trailing newline
                        // as "search now" and drop the keyboard.
                        if newValue.contains("\n") {
                            prompt = newValue.replacingOccurrences(of: "\n", with: "")
                            searchFocused = false
                            lastParsed = parser.parse(prompt)
                            filtersResolved = false
                            hasSearched = false
                            Task { await runSearch() }
                        } else {
                            lastParsed = parser.parse(prompt)
                            filtersResolved = false
                            hasSearched = false
                        }
                    }

                Button {
                    showingHelpSheet = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search Help")
            }

            sortBar

            if !lastParsed.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(filterChips()) { chip in
                        Button {
                            chip.remove()
                        } label: {
                            ChipView(text: chip.label, kind: chip.kind, removable: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
    }

    /// Results minus hidden works and (optionally) Mature/Explicit-rated ones.
    private var visibleResults: [AO3WorkSummary] {
        ContentFilter.apply(results, hiddenIds: HiddenWorkStore.ids(hiddenWorks), filterMature: filterMature)
    }

    @ViewBuilder
    private var contentArea: some View {
        if isSearching {
            VStack {
                Spacer()
                ProgressView("Searching AO3…")
                Spacer()
            }
        } else if let error = errorMessage {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if results.isEmpty && !hasSearched && !savedSearches.isEmpty {
            savedSearchesList
        } else if results.isEmpty && !hasSearched {
            ContentUnavailableView("Type a prompt", systemImage: "sparkle.magnifyingglass",
                description: Text("e.g. \"edward/bella romance all human complete\""))
        } else if results.isEmpty {
            ContentUnavailableView("No results found", systemImage: "magnifyingglass",
                description: Text("Try adjusting your filters or search terms."))
        } else if visibleResults.isEmpty {
            ContentUnavailableView("Nothing to show", systemImage: "eye.slash",
                description: Text("Every match is hidden or filtered out by your content settings."))
        } else {
            List {
                ForEach(visibleResults) { work in
                    NavigationLink(value: work) {
                        WorkRow(work: work)
                            .hoverEffect(.highlight)
                            .help("Read \(work.title)")
                            .contextMenu {
                                NavigationLink(value: work) {
                                    Label("Read Now", systemImage: "book")
                                }
                                
                                Button {
                                    _ = WorkPersistence.toggleFollow(summary: work, into: context)
                                } label: {
                                    if WorkPersistence.isFollowed(workId: work.id, in: context) {
                                        Label("Remove from Library", systemImage: "bookmark.slash")
                                    } else {
                                        Label("Save to Library", systemImage: "bookmark")
                                    }
                                }
                                
                                if let url = URL(string: "https://archiveofourown.org/works/\(work.id)") {
                                    ShareLink(item: url, subject: Text(work.title), message: Text("Check out this story: \(work.title)")) {
                                        Label("Share Story...", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                    }
                    // Infinite scroll: pull the next page as the last row appears.
                    .onAppear {
                        if work.id == visibleResults.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }
                if isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
    }

    private var savedSearchesList: some View {
        List {
            Section("Saved searches") {
                ForEach(savedSearches) { saved in
                    Button {
                        load(saved)
                        Task { await runSearch() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.name).font(.headline).foregroundStyle(.primary)
                            Text(saved.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let col = AO3SearchFilters.SortColumn(rawValue: saved.sortColumn) {
                                Text("Sort: \(col.displayName) \(saved.sortDirection == "asc" ? "↑" : "↓")")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            context.delete(saved)
                            try? context.save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func load(_ saved: SavedSearch) {
        prompt = saved.prompt
        sortColumn = AO3SearchFilters.SortColumn(rawValue: saved.sortColumn) ?? .bestMatch
        sortDirection = AO3SearchFilters.SortDirection(rawValue: saved.sortDirection) ?? .desc
        lastParsed = parser.parse(saved.prompt)
    }

    private func suggestName() -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Untitled" }
        return String(trimmed.prefix(40))
    }

    private func saveCurrent() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.name == name })
        let existing = (try? context.fetch(descriptor))?.first
        if let existing {
            existing.prompt = prompt
            existing.sortColumn = sortColumn.rawValue
            existing.sortDirection = sortDirection.rawValue
            existing.savedAt = .now
        } else {
            let new = SavedSearch(
                name: name,
                prompt: prompt,
                sortColumn: sortColumn.rawValue,
                sortDirection: sortDirection.rawValue
            )
            context.insert(new)
        }
        try? context.save()
    }

    private var sortBar: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Sort by", selection: $sortColumn) {
                    ForEach(AO3SearchFilters.SortColumn.allCases, id: \.self) { column in
                        Text(column.displayName).tag(column)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(sortColumn.displayName)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.subheadline)
            }
            .onChange(of: sortColumn) { _, _ in
                if !results.isEmpty { Task { await executeSearch(resolve: false) } }
            }

            Button {
                sortDirection = sortDirection == .asc ? .desc : .asc
                if !results.isEmpty { Task { await executeSearch(resolve: false) } }
            } label: {
                Image(systemName: sortDirection.symbol)
                    .font(.subheadline)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    private func runSearch() async {
        lastParsed = parser.parse(prompt)
        filtersResolved = false
        await executeSearch(resolve: true)
    }

    /// Searches using the current `lastParsed` (without re-parsing the
    /// prompt, so chip removals stick). Resolves tags to AO3's canonical
    /// names first — the same step Browse uses, so results match. Removing
    /// a chip passes `resolve: false` (tags are already canonical) so the
    /// re-search is instant instead of re-hitting autocomplete per tag.
    private func executeSearch(resolve: Bool) async {
        errorMessage = nil
        withAnimation {
            isSearching = true
        }
        currentPage = 1
        defer {
            withAnimation {
                isSearching = false
            }
        }
        
        var filters = lastParsed
        if resolve {
            if !filters.query.isEmpty {
                filters = await enricher.enrich(filters: filters, prompt: filters.query)
            }
            filters = await TagResolver.resolve(filters, using: client)
            filtersResolved = true
        }
        filters.sortColumn = sortColumn
        filters.sortDirection = sortDirection
        lastParsed = filters  // reflect canonical names in the chips
        
        do {
            let result = try await client.search(filters: filters, page: 1)
            results = result.works
            totalPages = result.totalPages
            currentPage = result.currentPage
            hasSearched = true
        } catch let AO3Error.loginFailed(reason) {
            errorMessage = reason
            hasSearched = false
        } catch let AO3Error.http(status) {
            errorMessage = "AO3 returned HTTP \(status)"
            hasSearched = false
        } catch let AO3Error.parseFailed(reason) {
            errorMessage = "Couldn't parse AO3's response: \(reason)"
            hasSearched = false
        } catch let AO3Error.network(underlying) {
            errorMessage = "Network: \(underlying)"
            hasSearched = false
        } catch {
            errorMessage = error.localizedDescription
            hasSearched = false
        }
    }

    private func loadMore() async {
        // onAppear can fire repeatedly, and there's no page past totalPages.
        guard !isLoadingMore, currentPage < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var filters = lastParsed
        filters.sortColumn = sortColumn
        filters.sortDirection = sortDirection
        do {
            let result = try await client.search(filters: filters, page: currentPage + 1)
            let existing = Set(results.map(\.id))
            results.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            errorMessage = "Couldn't load more: \(error)"
        }
    }

    struct FilterChip: Identifiable {
        let id = UUID()
        let label: String
        let kind: ChipView.Kind
        let remove: () -> Void
    }

    /// Tap a chip to remove that filter and re-run the search.
    private func filterChips() -> [FilterChip] {
        var chips: [FilterChip] = []

        for ship in lastParsed.relationshipNames {
            chips.append(FilterChip(label: "♥ \(ship)", kind: .include) {
                lastParsed.relationshipNames.removeAll { $0 == ship }; chipChanged()
            })
        }
        for character in lastParsed.characterNames {
            chips.append(FilterChip(label: "👤 \(character)", kind: .include) {
                lastParsed.characterNames.removeAll { $0 == character }; chipChanged()
            })
        }
        for fandom in lastParsed.fandomNames {
            chips.append(FilterChip(label: "📚 \(fandom)", kind: .include) {
                lastParsed.fandomNames.removeAll { $0 == fandom }; chipChanged()
            })
        }
        for tag in lastParsed.freeformNames {
            chips.append(FilterChip(label: tag, kind: .include) {
                lastParsed.freeformNames.removeAll { $0 == tag }; chipChanged()
            })
        }
        for rating in lastParsed.ratings.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(FilterChip(label: rating.displayName, kind: .include) {
                lastParsed.ratings.remove(rating); chipChanged()
            })
        }
        for warning in lastParsed.warnings.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(FilterChip(label: warning.displayName, kind: .include) {
                lastParsed.warnings.remove(warning); chipChanged()
            })
        }
        for category in lastParsed.categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(FilterChip(label: category.displayName, kind: .include) {
                lastParsed.categories.remove(category); chipChanged()
            })
        }
        if !lastParsed.wordCount.isEmpty {
            chips.append(FilterChip(label: "words \(lastParsed.wordCount)", kind: .include) {
                lastParsed.wordCount = ""; chipChanged()
            })
        }
        if !lastParsed.languageId.isEmpty {
            chips.append(FilterChip(label: "lang \(lastParsed.languageId)", kind: .include) {
                lastParsed.languageId = ""; chipChanged()
            })
        }
        if lastParsed.singleChapter {
            chips.append(FilterChip(label: "oneshot", kind: .include) {
                lastParsed.singleChapter = false; chipChanged()
            })
        }
        if lastParsed.complete == .yes {
            chips.append(FilterChip(label: "complete", kind: .include) { lastParsed.complete = .any; chipChanged() })
        } else if lastParsed.complete == .no {
            chips.append(FilterChip(label: "WIP", kind: .include) { lastParsed.complete = .any; chipChanged() })
        }
        if lastParsed.crossover == .yes {
            chips.append(FilterChip(label: "crossover", kind: .include) { lastParsed.crossover = .any; chipChanged() })
        } else if lastParsed.crossover == .no {
            chips.append(FilterChip(label: "no crossover", kind: .include) { lastParsed.crossover = .any; chipChanged() })
        }
        if !lastParsed.title.isEmpty {
            chips.append(FilterChip(label: "title \u{201C}\(lastParsed.title)\u{201D}", kind: .include) {
                lastParsed.title = ""; chipChanged()
            })
        }
        if !lastParsed.query.isEmpty {
            chips.append(FilterChip(label: "\u{201C}\(lastParsed.query)\u{201D}", kind: .include) {
                lastParsed.query = ""; chipChanged()
            })
        }
        for excluded in lastParsed.excludedFreeforms {
            chips.append(FilterChip(label: excluded, kind: .exclude) {
                lastParsed.excludedFreeforms.removeAll { $0 == excluded }; chipChanged()
            })
        }
        return chips
    }

    /// After a chip is removed: sync the search box to the remaining
    /// filters (so the corresponding text disappears too) and re-run the
    /// search — without re-resolving, since tags are already canonical.
    private func chipChanged() {
        syncPromptToFilters()
        if !results.isEmpty { Task { await executeSearch(resolve: false) } }
    }

    /// Rewrites the search box to a normalized representation of the active
    /// filters. `suppressParse` prevents the resulting onChange from
    /// re-parsing (which would just reproduce the same filters).
    private func syncPromptToFilters() {
        suppressParse = true
        prompt = lastParsed.promptText()
        DispatchQueue.main.async { suppressParse = false }
    }
}

struct WorkRow: View {
    let work: AO3WorkSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(work.title).font(.headline)
            Text("by \(work.author)").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if !work.rating.isEmpty {
                    Text(work.rating).font(.caption).foregroundStyle(.secondary)
                }
                if work.wordCount > 0 {
                    Text("\(work.wordCount.formatted()) words").font(.caption).foregroundStyle(.secondary)
                }
                if work.totalChapters != nil {
                    Text("\(work.chapterCount)/\(work.totalChapters!)").font(.caption).foregroundStyle(.secondary)
                } else if work.chapterCount > 0 {
                    Text("\(work.chapterCount)/?").font(.caption).foregroundStyle(.secondary)
                }
                if work.kudos > 0 {
                    Label(work.kudos.formatted(), systemImage: "heart").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !work.summary.isEmpty {
                Text(work.summary).font(.callout).lineLimit(3).foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
    }
}

struct ChipView: View {
    enum Kind { case include, exclude }
    let text: String
    let kind: Kind
    var removable: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            if removable {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
        }
        .font(.caption)
        .padding(.leading, 10)
        .padding(.trailing, removable ? 8 : 10)
        .padding(.vertical, 5)
        .background(background)
        .foregroundStyle(foreground)
        .clipShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .include: Color.accentColor.opacity(0.18)
        case .exclude: Color.red.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch kind {
        case .include: Color.accentColor
        case .exclude: Color.red
        }
    }
}

struct WorkDetailView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(ReaderProfile.deviceKey("reader.theme")) private var themeRaw: String = ReaderTheme.system.rawValue
    @Environment(\.dismiss) private var dismiss
    let workId: Int
    @State private var payload: AO3WorkPayload?
    @State private var errorMessage: String?
    @State private var isSavingOffline: Bool = false
    @State private var followed: Bool = false
    @State private var epubURL: URL?
    @State private var showingReport: Bool = false

    /// The reader's themed page colour, computed the same way `ReaderView`
    /// does, so the detail screen is opaque from the first frame.
    private var readerBackground: Color {
        let theme = ReaderTheme(rawValue: themeRaw) ?? .system
        let scheme = theme.preferredColorScheme ?? systemColorScheme
        return theme.background(for: scheme)
    }

    var body: some View {
        Group {
            if let payload {
                ReaderView(payload: payload)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            WorkExportButton(workId: workId, title: payload.summary.title)
                            moreMenu(payload: payload)
                        }
                    }
                    .sheet(isPresented: $showingReport) {
                        SafariView(url: URL(string: "https://archiveofourown.org/abuse_reports/new")!)
                            .ignoresSafeArea()
                    }
            } else if let errorMessage {
                ContentUnavailableView("Couldn't load work", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Opaque, full-bleed backing so the screen we pushed from (e.g. the
        // Browse list with its filter chips) never shows through while the work
        // loads or during the push transition.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(readerBackground.ignoresSafeArea())
        .task { await load() }
    }

    // MARK: - Toolbar buttons

    /// Overflow menu: save-to-library (follow), offline download, plus the
    /// UGC safeguards (App Store guideline 1.2) — report objectionable content
    /// to AO3 (the host/moderator), and hide the work locally so it never
    /// appears in results again. Kept to a single menu so the toolbar matches
    /// the Library reader and the reader's own items (chapters, Aa, minimize)
    /// fit without the system spilling them into a second "…" overflow.
    private func moreMenu(payload: AO3WorkPayload) -> some View {
        Menu {
            Button {
                followed = WorkPersistence.toggleFollow(summary: payload.summary, into: context)
            } label: {
                Label(followed ? "Remove from Library" : "Save to Library",
                      systemImage: followed ? "bookmark.slash" : "bookmark")
            }
            Button {
                Task { await saveOffline(payload) }
            } label: {
                if isSavingOffline {
                    Label("Downloading…", systemImage: "arrow.down.circle")
                } else if epubURL != nil {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .disabled(isSavingOffline || epubURL != nil)

            Divider()

            Button {
                showingReport = true
            } label: {
                Label("Report this work", systemImage: "flag")
            }
            Button(role: .destructive) {
                HiddenWorkStore.hide(ao3Id: payload.summary.id, title: payload.summary.title, into: context)
                dismiss()
            } label: {
                Label("Hide this work", systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Work options")
    }

    // MARK: - Actions

    private func load() async {
        epubURL = WorkPersistence.epubURL(workId: workId)
        followed = WorkPersistence.isFollowed(workId: workId, in: context)

        do {
            let fetched = try await client.fetchWork(id: workId)
            payload = fetched
            WorkPersistence.recordView(summary: fetched.summary, into: context)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func saveOffline(_ payload: AO3WorkPayload) async {
        isSavingOffline = true
        defer { isSavingOffline = false }
        _ = WorkPersistence.upsert(payload: payload, into: context)
        do {
            let url = try await client.downloadEPUB(workId: payload.summary.id)
            epubURL = url
        } catch {
            errorMessage = "Saved metadata but EPUB download failed: \(error)"
        }
    }

}

struct SearchHelpView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Search Syntax Guide")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top)
                    
                    Text("Fanficly supports advanced search prompt parsing to quickly find the exact fanfictions you want.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    
                    Divider()
                    
                    Group {
                        HelpSection(
                            title: "Story Title",
                            icon: "doc.text",
                            color: .blue,
                            examples: [
                                ("title:Gatsby", "Find works with 'Gatsby' in the title."),
                                ("title:\"The Great Gatsby\"", "Use quotes for multi-word titles.")
                            ]
                        )
                        
                        HelpSection(
                            title: "Relationships (Ships)",
                            icon: "heart.fill",
                            color: .red,
                            examples: [
                                ("harry/draco", "Search for relationships using a slash."),
                                ("\"Hermione Granger/Draco Malfoy\"", "Use quotes for full canonical relationships.")
                            ]
                        )
                        
                        HelpSection(
                            title: "Excluding Terms/Tags",
                            icon: "minus.circle.fill",
                            color: .orange,
                            examples: [
                                ("-angst", "Exclude works containing the word 'angst'."),
                                ("not \"happy ending\"", "Exclude works tagged with 'happy ending'.")
                            ]
                        )
                        
                        HelpSection(
                            title: "Word Count",
                            icon: "number",
                            color: .green,
                            examples: [
                                ("under 10k", "Less than 10,000 words."),
                                ("over 50k", "More than 50,000 words."),
                                ("between 10k and 50k", "Range of word count.")
                            ]
                        )
                    }
                    
                    Group {
                        HelpSection(
                            title: "Completion & Format",
                            icon: "checkmark.circle.fill",
                            color: .purple,
                            examples: [
                                ("complete", "Show only completed works."),
                                ("wip", "Show works in progress (unfinished)."),
                                ("oneshot", "Show single-chapter works.")
                            ]
                        )
                        
                        HelpSection(
                            title: "Engagement & Sorting",
                            icon: "arrow.up.arrow.down.circle.fill",
                            color: .teal,
                            examples: [
                                ("popular", "Show works with >1,000 kudos."),
                                ("most kudos", "Sort results by kudos count."),
                                ("most hits", "Sort results by hits count."),
                                ("recently updated", "Sort by update date.")
                            ]
                        )
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Search Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct HelpSection: View {
    let title: String
    let icon: String
    let color: Color
    let examples: [(query: String, description: String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.headline)
                Text(title)
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.query) { example in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(example.query)
                            .font(.system(.subheadline, design: .monospaced))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(4)
                        Text(example.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 8)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environment(\.ao3Client, MockAO3Client())
}

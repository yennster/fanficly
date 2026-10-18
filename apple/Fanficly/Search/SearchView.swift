import SwiftUI
import SwiftData

/// Search AO3. What you type is a keyword search run by AO3's own ranking;
/// suggestions turn the words you're typing into exact tag or filter chips
/// when tapped; the Filters sheet covers everything else. Words are never
/// silently reinterpreted — see `SearchSyntax` for the few phrases that are.
struct SearchView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedSearch.savedAt, order: .reverse) private var savedSearches: [SavedSearch]
    @Query private var hiddenWorks: [HiddenWork]
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true
    @AppStorage("search.pendingQuery") private var pendingQuery: String = ""
    @AppStorage(RecentSearches.storageKey) private var recentRaw: String = ""

    /// The keywords in the search box.
    @State private var text = ""
    /// Everything else, shown as chips: tapped suggestions, the Filters
    /// sheet, and `key:value` tokens typed into the box (moved here when the
    /// search runs). Also carries the sort.
    @State private var active = AO3SearchFilters()
    /// The filters the current results came from (for loading more pages).
    @State private var searched: AO3SearchFilters?
    @State private var results: [AO3WorkSummary] = []
    @State private var totalFound: Int?
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchStartedAt: Date?
    @State private var tagSuggestions: [SuggestionCandidate] = []
    @State private var showingFilters = false
    /// Set once a sort is chosen deliberately (sort bar, Filters sheet, a
    /// saved search); until then the sort follows `SearchSyntax.automaticSort`.
    @State private var userPickedSort = false
    @State private var sortWhenFiltersOpened: AO3SearchFilters.SortColumn?
    @State private var showingHelp = false
    @State private var showingSaveDialog = false
    @State private var saveName = ""
    @FocusState private var searchFocused: Bool

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
            ToolbarItem(placement: .topBarTrailing) { savedSearchesMenu }
        }
        .alert("Save search", isPresented: $showingSaveDialog) {
            TextField("Name", text: $saveName)
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the keywords, filters and sort so you can re-run it later.")
        }
        .sheet(isPresented: $showingFilters) {
            WorkFilterSheet(filters: $active) {
                if active.sortColumn != sortWhenFiltersOpened { userPickedSort = true }
                if hasSearched || !currentFilters.isEmpty { submit() }
            }
        }
        .sheet(isPresented: $showingHelp) {
            SearchHelpView()
        }
        .onAppear(perform: consumePendingQuery)
        .onChange(of: pendingQuery) { _, _ in consumePendingQuery() }
        // Debounced AO3 tag suggestions for the words being typed; restarts
        // (cancelling the last lookup) whenever those words change.
        .task(id: suggestionKey) { await loadTagSuggestions() }
    }

    // MARK: - Header

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                searchField
                filtersButton
            }
            if searchFocused && !suggestionCandidates.isEmpty {
                suggestionRow
            }
            if !activeChips.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(activeChips) { chip in
                        Button {
                            chip.remove(&active)
                            if hasSearched { startSearch() }
                        } label: {
                            ChipView(text: chip.label, kind: chip.kind, removable: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove filter: \(chip.label)")
                        .accessibilityHint(hasSearched ? "Removes this filter and searches again." : "Removes this filter.")
                    }
                }
            }
            if hasSearched && !isSearching && errorMessage == nil {
                sortBar
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Fandoms, ships, tropes, titles…", text: $text)
                // Fandom names and ships aren't dictionary words — autocorrect
                // turned "sterek" into "streak".
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit(submit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search text")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filtersButton: some View {
        let count = activeChips.count
        return Button {
            sortWhenFiltersOpened = active.sortColumn
            showingFilters = true
        } label: {
            Image(systemName: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 4, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filters")
        .accessibilityValue(count > 0 ? "\(count) active" : "None")
        .help("Filters")
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestionCandidates) { candidate in
                    Button {
                        applySuggestion(candidate)
                    } label: {
                        Label(candidate.suggestion.label, systemImage: candidate.suggestion.systemImage)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add filter: \(candidate.suggestion.label)")
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
        .transition(.opacity)
    }

    private var sortBar: some View {
        HStack(spacing: 12) {
            if let totalFound {
                Text(totalFound == 1 ? "1 work" : "\(totalFound.formatted()) works")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Sort by", selection: sortColumnBinding) {
                    ForEach(AO3SearchFilters.SortColumn.allCases, id: \.self) { column in
                        Text(column.displayName).tag(column)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .accessibilityHidden(true)
                    Text(active.sortColumn.displayName)
                    Image(systemName: "chevron.down").font(.caption2)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
            }
            .accessibilityLabel("Sort by")
            .accessibilityValue(active.sortColumn.displayName)

            Button {
                active.sortDirection = active.sortDirection == .asc ? .desc : .asc
                userPickedSort = true
                startSearch()
            } label: {
                Image(systemName: active.sortDirection.symbol)
                    .font(.subheadline)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sort direction")
            .accessibilityValue(active.sortDirection.displayName)
        }
    }

    private var sortColumnBinding: Binding<AO3SearchFilters.SortColumn> {
        Binding {
            active.sortColumn
        } set: { column in
            guard column != active.sortColumn else { return }
            active.sortColumn = column
            userPickedSort = true
            startSearch()
        }
    }

    private var savedSearchesMenu: some View {
        Menu {
            Button {
                saveName = suggestName()
                showingSaveDialog = true
            } label: {
                Label("Save this search", systemImage: "bookmark")
            }
            .disabled(currentFilters.isEmpty)

            if !savedSearches.isEmpty {
                Section("Saved searches") {
                    ForEach(savedSearches) { saved in
                        Button(saved.name) { load(saved) }
                    }
                }
            }

            Divider()
            Button {
                showingHelp = true
            } label: {
                Label("Search tips", systemImage: "questionmark.circle")
            }
        } label: {
            Image(systemName: "bookmark")
        }
        .accessibilityLabel("Saved searches")
    }

    // MARK: - Content

    /// Results minus hidden works and (optionally) Mature/Explicit-rated ones.
    private var visibleResults: [AO3WorkSummary] {
        ContentFilter.apply(results, hiddenIds: HiddenWorkStore.ids(hiddenWorks), filterMature: filterMature)
    }

    @ViewBuilder
    private var contentArea: some View {
        if isSearching {
            searchingView
        } else if let error = errorMessage {
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { startSearch() }
            }
        } else if !hasSearched {
            startView
        } else if results.isEmpty {
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text(activeChips.isEmpty
                     ? "Try different keywords, or fewer of them — AO3 matches every word."
                     : "Try removing a filter, or fewer keywords — AO3 matches every word.")
            } actions: {
                if !activeChips.isEmpty {
                    Button("Remove All Filters") {
                        clearFilters()
                        startSearch()
                    }
                }
            }
        } else if visibleResults.isEmpty {
            ContentUnavailableView("Nothing to show", systemImage: "eye.slash",
                description: Text("Every match is hidden or filtered out by your content settings."))
        } else {
            resultsList
        }
    }

    private var searchingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView("Searching AO3…")
            // AO3 often takes 20–30s to answer a search; say so, and offer a
            // way out, once it's clearly not instant.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                if let start = searchStartedAt, timeline.date.timeIntervalSince(start) >= 5 {
                    VStack(spacing: 10) {
                        Text("AO3 can take up to half a minute to search.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Cancel", action: cancelSearch)
                            .buttonStyle(.bordered)
                    }
                    .transition(.opacity)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private var resultsList: some View {
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
        .scrollDismissesKeyboard(.immediately)
    }

    /// Before the first search: recent and saved searches, or a short intro.
    @ViewBuilder
    private var startView: some View {
        let recents = RecentSearches.list(recentRaw)
        if recents.isEmpty && savedSearches.isEmpty {
            ContentUnavailableView {
                Label("Search AO3", systemImage: "magnifyingglass")
            } description: {
                Text("Type a fandom, ship, trope, title or author. Tap a suggestion to filter by an exact tag.")
            } actions: {
                Button("Search Tips") { showingHelp = true }
            }
        } else {
            List {
                if !recents.isEmpty {
                    Section {
                        ForEach(recents, id: \.self) { prompt in
                            Button {
                                load(prompt: prompt)
                            } label: {
                                Label(prompt, systemImage: "clock.arrow.circlepath")
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    recentRaw = RecentSearches.removing(prompt, from: recentRaw)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Button("Clear") { recentRaw = "" }
                                .font(.subheadline)
                                .textCase(nil)
                        }
                    }
                }
                if !savedSearches.isEmpty {
                    Section("Saved searches") {
                        ForEach(savedSearches) { saved in
                            Button {
                                load(saved)
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
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: - Suggestions

    /// The words at the end of the box, when the box is being typed in.
    private var suggestionKey: String {
        searchFocused ? SearchSuggestions.activeWords(in: text).joined(separator: " ").lowercased() : ""
    }

    /// Instant local suggestions first, then AO3's tags; anything already
    /// applied is left out.
    private var suggestionCandidates: [SuggestionCandidate] {
        var out = SearchSuggestions.local(for: SearchSuggestions.activeWords(in: text))
        for candidate in tagSuggestions where !out.contains(where: {
            $0.suggestion.label.caseInsensitiveCompare(candidate.suggestion.label) == .orderedSame
        }) {
            out.append(candidate)
        }
        return out.filter { candidate in
            var probe = active
            candidate.suggestion.apply(to: &probe)
            return probe != active
        }
    }

    private func loadTagSuggestions() async {
        tagSuggestions = []
        let words = SearchSuggestions.activeWords(in: text)
        guard searchFocused, !words.isEmpty else { return }
        // Wait for a pause in typing: every lookup is a throttled AO3 request.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        // The longest trailing phrase AO3 has tags for: "teen wolf slow"
        // backs off to "wolf slow", then "slow".
        for n in stride(from: words.count, through: 1, by: -1) {
            let phrase = words.suffix(n).joined(separator: " ")
            guard phrase.count >= 2 else { continue }
            let names: [String]
            if let cached = await TagSuggestionCache.shared.value(for: phrase) {
                names = cached
            } else {
                guard let fetched = try? await client.autocomplete(field: .tag, term: phrase) else { return }
                await TagSuggestionCache.shared.set(fetched, for: phrase)
                names = fetched
            }
            guard !Task.isCancelled else { return }
            let ranked = SearchSuggestions.rankTags(names, for: phrase)
            if !ranked.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) {
                    tagSuggestions = ranked.map { SuggestionCandidate(suggestion: .tag($0), consumedWords: n) }
                }
                return
            }
        }
    }

    private func applySuggestion(_ candidate: SuggestionCandidate) {
        SearchSuggestions.apply(candidate, text: &text, filters: &active)
        tagSuggestions = []
        UIAccessibility.post(notification: .announcement, argument: "Added filter: \(candidate.suggestion.label)")
        // Refining results that are already showing: keep them in step with
        // the chips. Before the first search, keep composing instead.
        if hasSearched { startSearch() }
    }

    // MARK: - Chips

    private struct ActiveChip: Identifiable {
        let id: String
        let label: String
        var kind: ChipView.Kind = .include
        let remove: (inout AO3SearchFilters) -> Void
    }

    /// Every active filter as a removable chip (keywords stay in the box).
    private var activeChips: [ActiveChip] {
        let f = active
        var chips: [ActiveChip] = []
        func list(_ names: [String], _ key: String, prefix: String = "", kind: ChipView.Kind = .include,
                  _ path: WritableKeyPath<AO3SearchFilters, [String]>) {
            for name in names {
                chips.append(ActiveChip(id: "\(key)|\(name)", label: prefix + name, kind: kind) {
                    $0[keyPath: path].removeAll { $0 == name }
                })
            }
        }
        if !f.title.isEmpty {
            chips.append(ActiveChip(id: "title", label: "Title: \(f.title)") { $0.title = "" })
        }
        if !f.creators.isEmpty {
            chips.append(ActiveChip(id: "creators", label: "By \(f.creators)") { $0.creators = "" })
        }
        list(f.otherTagNames, "tag", \.otherTagNames)
        list(f.fandomNames, "fandom", \.fandomNames)
        list(f.relationshipNames, "ship", \.relationshipNames)
        list(f.characterNames, "character", \.characterNames)
        list(f.freeformNames, "freeform", \.freeformNames)
        list(f.excludedTagNames, "-tag", prefix: "Not ", kind: .exclude, \.excludedTagNames)
        list(f.excludedFreeforms, "exclude", prefix: "Not ", kind: .exclude, \.excludedFreeforms)
        for rating in f.ratings.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(ActiveChip(id: "rating|\(rating.rawValue)", label: "Rated \(rating.displayName)") { $0.ratings.remove(rating) })
        }
        for warning in f.warnings.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(ActiveChip(id: "warning|\(warning.rawValue)", label: warning.displayName) { $0.warnings.remove(warning) })
        }
        for category in f.categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(ActiveChip(id: "category|\(category.rawValue)", label: category.displayName) { $0.categories.remove(category) })
        }
        if f.complete != .any {
            chips.append(ActiveChip(id: "complete", label: f.complete == .yes ? "Complete works" : "Works in progress") { $0.complete = .any })
        }
        if f.crossover != .any {
            chips.append(ActiveChip(id: "crossover", label: f.crossover == .yes ? "Crossovers" : "No crossovers") { $0.crossover = .any })
        }
        if f.singleChapter {
            chips.append(ActiveChip(id: "oneshot", label: "One-shots") { $0.singleChapter = false })
        }
        if !f.wordCount.isEmpty {
            chips.append(ActiveChip(id: "words", label: AO3SearchFilters.wordCountLabel(f.wordCount)) { $0.wordCount = "" })
        }
        if !f.languageId.isEmpty {
            chips.append(ActiveChip(id: "lang", label: "In \(SearchSyntax.languageNames[f.languageId] ?? f.languageId)") { $0.languageId = "" })
        }
        if !f.kudosCount.isEmpty {
            chips.append(ActiveChip(id: "kudos", label: "Kudos \(f.kudosCount)") { $0.kudosCount = "" })
        }
        if !f.hits.isEmpty {
            chips.append(ActiveChip(id: "hits", label: "Hits \(f.hits)") { $0.hits = "" })
        }
        if !f.commentsCount.isEmpty {
            chips.append(ActiveChip(id: "comments", label: "Comments \(f.commentsCount)") { $0.commentsCount = "" })
        }
        if !f.bookmarksCount.isEmpty {
            chips.append(ActiveChip(id: "bookmarks", label: "Bookmarks \(f.bookmarksCount)") { $0.bookmarksCount = "" })
        }
        if !f.revisedAt.isEmpty {
            chips.append(ActiveChip(id: "updated", label: "Updated \(f.revisedAt)") { $0.revisedAt = "" })
        }
        return chips
    }

    private func clearFilters() {
        let sort = (active.sortColumn, active.sortDirection)
        active = AO3SearchFilters()
        (active.sortColumn, active.sortDirection) = sort
    }

    // MARK: - Searching

    /// The whole search: chips plus the keywords in the box.
    private var currentFilters: AO3SearchFilters {
        var filters = active
        filters.query = SearchSyntax.collapseWhitespace(text)
        return filters
    }

    /// Runs the search box: explicit tokens and filter phrases typed there
    /// become chips; the rest stays as keywords.
    private func submit() {
        let parsed = SearchSyntax.parse(text)
        active = active.merging(parsed)
        text = parsed.query
        searchFocused = false
        startSearch()
    }

    private func startSearch() {
        guard !currentFilters.isEmpty else { return }
        if !userPickedSort {
            active.sortColumn = SearchSyntax.automaticSort(hasKeywords: !currentFilters.query.isEmpty)
            active.sortDirection = .desc
        }
        let filters = currentFilters
        recentRaw = RecentSearches.adding(filters.promptText(), to: recentRaw)
        // A newer search replaces an in-flight one, so a slow earlier
        // response can never overwrite the results you asked for last.
        searchTask?.cancel()
        searchTask = Task { await performSearch(filters) }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchStartedAt = nil
        withAnimation { isSearching = false }
    }

    private func performSearch(_ requested: AO3SearchFilters) async {
        errorMessage = nil
        searchStartedAt = .now
        withAnimation { isSearching = true }
        var filters = requested

        // Tags typed into the Filters sheet's fields get AO3's canonical names
        // first (suggestions already are canonical, so they skip this).
        if !(filters.fandomNames + filters.relationshipNames + filters.characterNames + filters.freeformNames).isEmpty {
            filters = await TagResolver.resolve(filters, using: client)
            guard !Task.isCancelled else { return }
            active.fandomNames = filters.fandomNames
            active.relationshipNames = filters.relationshipNames
            active.characterNames = filters.characterNames
            active.freeformNames = filters.freeformNames
        }

        do {
            let result = try await client.search(filters: filters, page: 1)
            guard !Task.isCancelled else { return }
            results = result.works
            totalFound = result.totalFound
            totalPages = result.totalPages
            currentPage = result.currentPage
            searched = filters
            hasSearched = true
            // VoiceOver gets no cue from the list swap alone.
            UIAccessibility.post(notification: .announcement, argument: result.totalFound.map {
                "Search finished. \($0) works found."
            } ?? "Search finished. \(results.count) works on this page.")
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = Self.message(for: error)
        }
        searchStartedAt = nil
        withAnimation { isSearching = false }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AO3Error.loginFailed(let reason): return reason
        case AO3Error.http(let status): return "AO3 returned HTTP \(status)."
        case AO3Error.parseFailed(let reason): return "Couldn't read AO3's response: \(reason)"
        case AO3Error.network(let underlying): return "Network: \(underlying)"
        case AO3Error.rateLimited: return "AO3 is asking us to slow down. Try again in a minute."
        default: return error.localizedDescription
        }
    }

    private func loadMore() async {
        // onAppear can fire repeatedly, and there's no page past totalPages.
        guard !isLoadingMore, !isSearching, currentPage < totalPages, let searched else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await client.search(filters: searched, page: currentPage + 1)
            guard searched == self.searched else { return }  // a new search started meanwhile
            let existing = Set(results.map(\.id))
            results.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            errorMessage = "Couldn't load more: \(Self.message(for: error))"
        }
    }

    // MARK: - Saved, recent and linked searches

    /// Loads a stored search (saved, recent, widget or Shortcut link) into the
    /// box and chips, then runs it.
    private func load(prompt: String, sortColumn: AO3SearchFilters.SortColumn? = nil,
                      sortDirection: AO3SearchFilters.SortDirection? = nil) {
        let parsed = SearchSyntax.parse(prompt)
        var filters = AO3SearchFilters().merging(parsed)
        filters.sortColumn = sortColumn ?? active.sortColumn
        filters.sortDirection = sortDirection ?? active.sortDirection
        active = filters
        text = parsed.query
        searchFocused = false
        startSearch()
    }

    private func load(_ saved: SavedSearch) {
        userPickedSort = true
        load(prompt: saved.prompt,
             sortColumn: AO3SearchFilters.SortColumn(rawValue: saved.sortColumn) ?? .bestMatch,
             sortDirection: AO3SearchFilters.SortDirection(rawValue: saved.sortDirection) ?? .desc)
    }

    private func consumePendingQuery() {
        guard !pendingQuery.isEmpty else { return }
        let prompt = pendingQuery
        pendingQuery = ""
        load(prompt: prompt)
    }

    private func suggestName() -> String {
        let prompt = currentFilters.promptText()
        return prompt.isEmpty ? "Untitled" : String(prompt.prefix(40))
    }

    private func saveCurrent() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let prompt = currentFilters.promptText()
        let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.name == name })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.prompt = prompt
            existing.sortColumn = active.sortColumn.rawValue
            existing.sortDirection = active.sortDirection.rawValue
            existing.savedAt = .now
        } else {
            context.insert(SavedSearch(
                name: name,
                prompt: prompt,
                sortColumn: active.sortColumn.rawValue,
                sortDirection: active.sortDirection.rawValue
            ))
        }
        try? context.save()
    }
}

struct WorkRow: View {
    let work: AO3WorkSummary
    @Environment(\.modelContext) private var context
    // Reflects the local follow ("bookmark") state; seeded on appear and
    // updated when the inline button is tapped.
    @State private var isFollowed = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
                        HStack(spacing: 4) {
                            Image(systemName: "heart")
                                .accessibilityHidden(true)
                            Text(work.kudos.formatted())
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if !work.summary.isEmpty {
                    Text(work.summary).font(.callout).lineLimit(3).foregroundStyle(.primary)
                }
            }
            // Combine only the text stack, so the inline bookmark button stays
            // its own focusable element.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            bookmarkButton
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
        .onAppear { isFollowed = WorkPersistence.isFollowed(workId: work.id, in: context) }
    }

    /// Inline one-tap follow/unfollow, so a story can be saved to the Library
    /// straight from a results list without opening it. `.borderless` keeps the
    /// tap from also triggering the row's NavigationLink.
    private var bookmarkButton: some View {
        Button {
            let newState = WorkPersistence.toggleFollow(summary: work, into: context)
            withAnimation(.easeInOut(duration: 0.2)) { isFollowed = newState }
        } label: {
            Image(systemName: isFollowed ? "bookmark.fill" : "bookmark")
                .font(.body)
                .foregroundStyle(isFollowed ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .padding(.vertical, 4)
                .padding(.leading, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isFollowed ? "Remove \(work.title) from Library"
                                       : "Save \(work.title) to Library")
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
                    .accessibilityHidden(true)
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
    @State private var showingComments: Bool = false
    @State private var currentChapterIndex = 1
    @State private var exporter = WorkExporter()

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
                ReaderView(payload: payload, currentChapter: $currentChapterIndex)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                followed = WorkPersistence.toggleFollow(summary: payload.summary, into: context)
                            } label: {
                                Image(systemName: followed ? "bookmark.fill" : "bookmark")
                            }
                            .accessibilityLabel(followed ? "Remove from Library" : "Save to Library")
                            
                            moreMenu(payload: payload)
                        }
                    }
                    .sheet(isPresented: $showingReport) {
                        SafariView(url: URL(string: "https://archiveofourown.org/abuse_reports/new")!)
                            .ignoresSafeArea()
                    }
                    .sheet(isPresented: $showingComments) {
                        CommentsView(workId: workId, workTitle: payload.summary.title,
                                     chapterId: payload.chapters.first(where: { $0.index == currentChapterIndex })?.aoId,
                                     chapterNumber: currentChapterIndex,
                                     totalChapters: payload.chapters.count)
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
        // On the screen view, NOT inside the menu — see WorkExporter's docs.
        .workExportPresentation(exporter)
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
                showingComments = true
            } label: {
                Label("Comments", systemImage: "bubble.left.and.bubble.right")
            }

            Divider()

            WorkExportButton(workId: workId, title: payload.summary.title,
                             exporter: exporter, useTextLabel: true)
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
            if exporter.isExporting {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle")
            }
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

/// Reads a work's comment thread and, when logged in, lets you post a comment.
/// Live-fetched (no caching), presented as a sheet from the reader's options
/// menu. Posting reuses the proven CSRF-token flow (scrape the work page's
/// authenticity_token + pseud, then POST), like login and subscribe.
struct CommentsView: View {
    let workId: Int
    let workTitle: String
    /// The chapter whose thread to show/post to (AO3 comments are per-chapter).
    /// nil → work-level (first chapter), the fallback when the id is unknown.
    var chapterId: Int? = nil
    var chapterNumber: Int? = nil
    var totalChapters: Int? = nil
    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [AO3Comment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var draft = ""
    @State private var isPosting = false
    @State private var postError: String?
    @FocusState private var composerFocused: Bool

    /// Show the chapter only for multi-chapter works; single-chapter works read
    /// plainly as "Comments".
    private var navTitle: String {
        if let chapterNumber, (totalChapters ?? 1) > 1 { return "Comments · Ch \(chapterNumber)" }
        return "Comments"
    }

    /// Per-chapter empty state names the chapter, so an empty later chapter
    /// reads as "this chapter has none" rather than "comments failed to load".
    private var emptyTitle: String {
        if let chapterNumber, (totalChapters ?? 1) > 1 { return "No comments on Chapter \(chapterNumber) yet" }
        return "No comments yet"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && comments.isEmpty {
                    VStack { Spacer(); ProgressView("Loading comments…"); Spacer() }
                } else if let errorMessage, comments.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load comments", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else if comments.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "bubble.left",
                        description: Text(auth.username == nil
                            ? "Be the first to comment — log in to AO3 to post."
                            : "Be the first to comment."))
                } else {
                    List {
                        ForEach(comments) { comment in
                            CommentRow(comment: comment)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh comments")
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .task { await load() }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            if auth.username == nil {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .accessibilityHidden(true)
                    Text("Log in to AO3 (Settings) to post a comment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let postError {
                        Text(postError).font(.caption).foregroundStyle(.red)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Add a comment as \(auth.username ?? "you")…", text: $draft, axis: .vertical)
                            .lineLimit(1...5)
                            .textFieldStyle(.roundedBorder)
                            .focused($composerFocused)
                            .disabled(isPosting)
                        Button {
                            Task { await post() }
                        } label: {
                            if isPosting {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.up.circle.fill").font(.title2)
                            }
                        }
                        .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Post comment")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            comments = try await client.fetchComments(workId: workId, chapterId: chapterId)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isPosting = true
        postError = nil
        defer { isPosting = false }
        do {
            try await client.postComment(workId: workId, chapterId: chapterId, text: text)
            draft = ""
            composerFocused = false
            // Re-fetch so the new comment shows (AO3 may hold it for moderation).
            await load()
        } catch {
            postError = "Couldn't post: \(error.localizedDescription). Your comment may be awaiting moderation, or try again."
        }
    }
}

private struct CommentRow: View {
    let comment: AO3Comment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Thread guide line for nested replies, so the indentation reads as
            // a reply rather than a stray offset.
            if comment.depth > 0 {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: comment.commenterUsername.isEmpty ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(comment.commenterName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !comment.dateText.isEmpty {
                        Text(comment.dateText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                // Combine only the header (name + date); the body may carry
                // links, which combining would flatten.
                .accessibilityElement(children: .combine)
                HTMLText(html: comment.bodyHTML)
                    .font(.callout)
            }
        }
        .padding(.leading, CGFloat(min(comment.depth, 6)) * 16)
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
    }
}

struct SearchHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("How search works")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top)

                    Text("Type anything — AO3 searches titles, summaries, tags and authors, and a work has to match every word. A few distinctive words beat a long sentence.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)

                    Divider()

                    HelpSection(
                        title: "Tap a suggestion for an exact tag",
                        icon: "tag.fill",
                        color: .blue,
                        examples: [
                            ("teen wolf", "Suggests the Teen Wolf (TV) fandom — tap it to filter by the tag instead of the words."),
                            ("derek stiles", "Suggests their ship and characters."),
                            ("slow burn", "Suggests the Slow Burn tag."),
                        ]
                    )

                    HelpSection(
                        title: "Filters",
                        icon: "line.3.horizontal.decrease.circle.fill",
                        color: .purple,
                        examples: [
                            ("Filters button", "Rating, warnings, categories, complete or in progress, length, language, sort and more."),
                        ]
                    )

                    HelpSection(
                        title: "Shortcuts you can type",
                        icon: "bolt.fill",
                        color: .orange,
                        examples: [
                            ("complete · wip · one shot", "Completion and single-chapter works."),
                            ("explicit · nsfw · sfw", "Ratings (\"teen\" and \"mature\" stay words — use a suggestion or Filters)."),
                            ("m/m · f/f · f/m", "Categories."),
                            ("under 10k · over 50k · between 10k and 50k", "Word count."),
                            ("in spanish · no crossovers · no mcd", "Language, crossovers, and leaving out Major Character Death."),
                        ]
                    )

                    HelpSection(
                        title: "Precise searching",
                        icon: "scope",
                        color: .green,
                        examples: [
                            ("\"enemies to lovers\"", "An exact phrase."),
                            ("-angst", "Leave out works mentioning a word."),
                            ("title:\"The Long Way Home\"", "Search titles only."),
                            ("by:astolat", "Works by an author."),
                            ("tag:\"Slow Burn\" -tag:\"Major Character Death\"", "Include or exclude an exact tag."),
                        ]
                    )
                }
                .padding(.horizontal)
            }
            .navigationTitle("Search Tips")
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
                    .accessibilityHidden(true)
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

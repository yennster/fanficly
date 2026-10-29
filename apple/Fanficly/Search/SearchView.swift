import SwiftUI
import SwiftData

/// Search AO3. What you type is a keyword search run by AO3's own ranking;
/// suggestions turn the words you're typing into exact tag or filter chips
/// when tapped; the Filters sheet covers everything else. Words are never
/// silently reinterpreted — see `SearchSyntax` for the few phrases that are.
struct SearchView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(AuthState.self) private var auth
    @Query(sort: \SavedSearch.savedAt, order: .reverse) private var savedSearches: [SavedSearch]
    @Query private var hiddenWorks: [HiddenWork]
    @Query private var blockedTerms: [BlockedTerm]
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
    @State private var badges: [Int: ResultBadge] = [:]
    @State private var totalFound: Int?
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    /// A failed next page: shown under the results, which stay (#154).
    @State private var paging = LoadMoreState()
    /// The error is an expired AO3 session (#131): offer Sign In Again.
    @State private var sessionExpired = false
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
    @State private var showingAlertLimit = false
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
        .alert("Too many alerts", isPresented: $showingAlertLimit) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can have new-fic alerts on for up to \(SavedSearchAlerts.maxAlertingSearches) saved searches. Turn one off to add another.")
        }
        // Saved searches with alerts on are checked here too: the background
        // refresh rarely has time for an AO3 search (see
        // `SubscriptionPoller.checkStaleSavedSearches`).
        .task {
            guard !FanficlyApp.isDemoMode else { return }
            let poller = SubscriptionPoller(client: client, context: context, username: auth.username)
            _ = await poller.checkStaleSavedSearches()
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

    /// Results minus hidden works, blocked tags and authors (except ones this
    /// search asked for by name) and (optionally) Mature/Explicit-rated ones.
    private var visibleResults: [AO3WorkSummary] {
        ContentFilter.apply(results, hiddenIds: HiddenWorkStore.ids(hiddenWorks), filterMature: filterMature,
                            blocklist: Blocklist(blockedTerms).lifting(searched ?? active))
    }

    @ViewBuilder
    private var contentArea: some View {
        if isSearching {
            searchingView
        } else if let error = errorMessage, sessionExpired, !auth.hasSession {
            SessionExpiredView(message: error)
        } else if errorMessage != nil, sessionExpired {
            // Signed in again since: the expiry note no longer stands.
            ContentUnavailableView {
                Label("Signed in again", systemImage: "magnifyingglass")
            } description: {
                Text("Search again to see every result, restricted works included.")
            } actions: {
                Button("Try Again") { startSearch() }
            }
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
            FilteredOutView(message: "Every match so far is hidden or filtered out by your content settings.",
                            canLoadMore: currentPage < totalPages, isLoadingMore: isLoadingMore,
                            loadMoreError: paging.error,
                            sessionExpired: sessionExpired && !auth.hasSession, loadMore: loadMore)
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
                    WorkRow(work: work, badge: badges[work.id])
                        .hoverEffect(.highlight)
                        .help("Read \(work.title)")
                        .contextMenu {
                            NavigationLink(value: work) {
                                Label("Read Now", systemImage: "book")
                            }

                            Button {
                                _ = WorkPersistence.toggleFollow(summary: work, into: context)
                                badges = WorkPersistence.resultBadges(for: visibleResults, in: context)
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
                // Infinite scroll: pull the next page as the last row appears
                // (after a failure, the footer's Try Again does).
                .onAppear {
                    if work.id == visibleResults.last?.id, paging.error == nil {
                        Task { await loadMore() }
                    }
                }
            }
            LoadMoreFooter(isLoadingMore: isLoadingMore, error: paging.error,
                           sessionExpired: sessionExpired && !auth.hasSession,
                           stoppedOnHiddenPages: paging.stoppedOnHiddenPages, retry: loadMore)
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .resultBadges(for: visibleResults, into: $badges)
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
                                    if saved.alertsEnabled {
                                        alertStatus(saved)
                                    }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    toggleAlerts(saved)
                                } label: {
                                    Label(saved.alertsEnabled ? "Alerts Off" : "Alerts On",
                                          systemImage: saved.alertsEnabled ? "bell.slash" : "bell")
                                }
                                .tint(.indigo)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(saved)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    toggleAlerts(saved)
                                } label: {
                                    Label(saved.alertsEnabled ? "Turn Off New-Fic Alerts" : "Alert Me About New Fics",
                                          systemImage: saved.alertsEnabled ? "bell.slash" : "bell")
                                }
                                Button(role: .destructive) {
                                    delete(saved)
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

    /// "Alerts on", or how many alerted fics haven't been looked at yet.
    private func alertStatus(_ saved: SavedSearch) -> some View {
        let newCount = saved.alertNewWorkIds.count
        return Label(newCount > 0 ? "\(newCount) new" : "Alerts on",
                     systemImage: newCount > 0 ? "bell.badge.fill" : "bell.fill")
            .font(.caption.weight(newCount > 0 ? .semibold : .regular))
            .foregroundStyle(newCount > 0 ? Color.accentColor : Color.secondary)
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

    /// Every active filter as a removable chip (keywords stay in the box).
    private var activeChips: [FilterChip] { FilterChip.all(in: active) }

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
        sessionExpired = false
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
            _ = try auth.check(result)
            // Restarting only now, not when the search starts, lets a next
            // page already in flight still land if this search is cancelled.
            paging.restart()
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
            paging.restart()
            sessionExpired = auth.explains(error)
            errorMessage = sessionExpired ? AuthState.message(for: error) : Self.message(for: error)
        }
        searchStartedAt = nil
        withAnimation { isSearching = false }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AO3Error.unauthorized: "AO3 sent its login page instead of results. Sign in again, then try again."
        // Every other AO3Error reads as a sentence (AO3Error: LocalizedError).
        default: error.localizedDescription
        }
    }

    /// Loads the next page, and the ones after it while the content filter
    /// hides them entirely, since those add no row to scroll to (#155).
    private func loadMore() async {
        guard !isLoadingMore else { return }
        paging.resume()
        while await loadNextPage(), !Task.isCancelled {}
    }

    /// Returns true when the page landed fully hidden and the next one should load.
    private func loadNextPage() async -> Bool {
        // onAppear can fire repeatedly, and there's no page past totalPages.
        guard !isLoadingMore, !isSearching, currentPage < totalPages, let searched else { return false }
        let generation = paging.begin()
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await client.search(filters: searched, page: currentPage + 1)
            guard paging.isCurrent(generation) else { return false }  // a new search started meanwhile
            _ = try auth.check(result)
            let shown = visibleResults.count
            let existing = Set(results.map(\.id))
            results.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
            return paging.landed(newRows: visibleResults.count - shown, hasMore: currentPage < totalPages)
        } catch {
            guard paging.isCurrent(generation), !Task.isCancelled else { return false }
            // The results so far stay; the footer says why and offers Try
            // Again, which picks up at the page that failed (#154).
            let expired = auth.explains(error)
            sessionExpired = expired
            let message = expired ? AuthState.message(for: error) : "Couldn't load more: \(Self.message(for: error))"
            paging.fail(message, generation: generation)
            UIAccessibility.post(notification: .announcement, argument: message)
            return false
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
        SavedSearchAlerts.markSeen(saved, context: context)
        userPickedSort = true
        load(prompt: saved.prompt,
             sortColumn: AO3SearchFilters.SortColumn(rawValue: saved.sortColumn) ?? .bestMatch,
             sortDirection: AO3SearchFilters.SortDirection(rawValue: saved.sortDirection) ?? .desc)
    }

    private func consumePendingQuery() {
        guard !pendingQuery.isEmpty else { return }
        let query = pendingQuery
        pendingQuery = ""
        guard let saved = AO3SearchFilters.savedFilter(fromRouteQuery: query) else {
            load(prompt: query)
            return
        }
        // A saved filter runs as saved, sort included. Reading it back as a
        // prompt would turn keywords like "complete" into filters.
        userPickedSort = true
        active = saved
        text = saved.query
        searchFocused = false
        startSearch()
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
            // Alerts for an edited search start over: what the old search
            // saw says nothing about the new one.
            let edited = existing.prompt != prompt
            if edited { SavedSearchAlerts.resetBaseline(of: existing) }
            existing.prompt = prompt
            existing.sortColumn = active.sortColumn.rawValue
            existing.sortDirection = active.sortDirection.rawValue
            existing.savedAt = .now
            if edited && existing.alertsEnabled { Task { await takeAlertBaseline(existing) } }
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

    private func delete(_ saved: SavedSearch) {
        iCloudSyncManager.recordDeletion(.search, key: saved.name)
        context.delete(saved)
        try? context.save()
    }

    /// Switches a saved search's new-fic alerts (#309) on or off, up to
    /// `SavedSearchAlerts.maxAlertingSearches` at once.
    private func toggleAlerts(_ saved: SavedSearch) {
        let on = !saved.alertsEnabled
        if on && !SavedSearchAlerts.canEnableMore(in: context) {
            showingAlertLimit = true
            return
        }
        SavedSearchAlerts.setAlerts(on, for: saved, context: context)
        UIAccessibility.post(notification: .announcement,
                             argument: on ? "New-fic alerts on for \(saved.name)" : "New-fic alerts off for \(saved.name)")
        if on { Task { await takeAlertBaseline(saved) } }
    }

    /// Records what the search finds now, so only fics posted after this
    /// alert. If it fails, the next check takes the baseline instead.
    private func takeAlertBaseline(_ saved: SavedSearch) async {
        guard !FanficlyApp.isDemoMode else { return }
        let poller = SubscriptionPoller(client: client, context: context, username: auth.username)
        _ = await poller.checkSavedSearch(saved)
        try? context.save()
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environment(\.ao3Client, MockAO3Client())
        .environment(AuthState())
}

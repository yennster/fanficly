import SwiftUI
import SwiftData

struct BrowseView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedFilter.savedAt, order: .reverse) private var savedFilters: [SavedFilter]

    var body: some View {
        List {
            if !savedFilters.isEmpty {
                Section("Saved filters") {
                    ForEach(savedFilters) { saved in
                        NavigationLink(value: saved) {
                            Label(saved.name, systemImage: "line.3.horizontal.decrease.circle")
                                .font(.body)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                context.delete(saved); try? context.save()
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            Section(savedFilters.isEmpty ? "" : "Categories") {
                ForEach(FandomCatalog.all) { category in
                    NavigationLink(value: category) {
                        Label(category.name, systemImage: category.symbol)
                            .font(.body)
                    }
                }
            }
        }
        .navigationTitle("Browse")
        .navigationDestination(for: FandomCategory.self) { category in
            CategoryFandomsView(category: category)
        }
        .navigationDestination(for: BrowseFandom.self) { fandom in
            FandomWorksView(fandom: fandom)
        }
        .navigationDestination(for: SavedFilter.self) { saved in
            FandomWorksView(savedFilter: saved)
        }
        .workAndAuthorDestinations()
    }
}

struct CategoryFandomsView: View {
    @Environment(\.ao3Client) private var client
    let category: FandomCategory
    @State private var liveFandoms: [BrowseFandom] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var query: String = ""

    /// The source list: live data once loaded, otherwise the curated
    /// seed — but only as a fallback after the live fetch fails, never
    /// during loading (which would flash the short list then swap).
    private var source: [BrowseFandom] {
        if !liveFandoms.isEmpty { return liveFandoms }
        if errorMessage != nil { return category.fandoms }
        return []
    }

    private var displayed: [BrowseFandom] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return source }
        return source.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if source.isEmpty && isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading fandoms…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                    Section {
                        ForEach(displayed) { fandom in
                            NavigationLink(value: fandom) {
                                Text(fandom.displayName).font(.body)
                            }
                        }
                    } header: {
                        Text(headerText).textCase(nil)
                    }
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search fandoms")
        .task { await loadLive() }
    }

    private var headerText: String {
        if !liveFandoms.isEmpty {
            return "\(displayed.count) of \(liveFandoms.count) fandoms"
        }
        return "\(displayed.count) popular fandoms"
    }

    private func loadLive() async {
        guard liveFandoms.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            liveFandoms = try await client.fetchFandomsInCategory(categoryName: category.ao3CanonicalName)
        } catch let AO3Error.http(status) where status == 404 {
            errorMessage = "AO3 didn't recognise that category. Showing popular fandoms only."
        } catch {
            errorMessage = "Couldn't load full list (\(error)). Showing popular fandoms only."
        }
    }
}

struct FandomWorksView: View {
    @Environment(\.ao3Client) private var client
    @Query private var hiddenWorks: [HiddenWork]
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true
    let title: String
    @State private var works: [AO3WorkSummary] = []
    @State private var currentPage: Int = 1
    @State private var totalPages: Int = 1
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var errorMessage: String?
    @State private var filters: AO3SearchFilters
    @State private var showingFilters = false

    init(filters: AO3SearchFilters, title: String) {
        self.title = title
        _filters = State(initialValue: filters)
    }

    init(fandom: BrowseFandom) {
        var initial = AO3SearchFilters()
        initial.fandomNames = [fandom.canonicalName]
        initial.sortColumn = .revisedAt
        initial.sortDirection = .desc
        self.init(filters: initial, title: fandom.displayName)
    }

    /// Applies a fandom-agnostic saved filter from the Browse landing page.
    init(savedFilter: SavedFilter) {
        let initial = AO3SearchFilters.from(savedJSON: savedFilter.filtersJSON) ?? AO3SearchFilters()
        self.init(filters: initial, title: savedFilter.name)
    }

    /// Works minus hidden ones and (optionally) Mature/Explicit-rated ones.
    private var visibleWorks: [AO3WorkSummary] {
        ContentFilter.apply(works, hiddenIds: HiddenWorkStore.ids(hiddenWorks), filterMature: filterMature)
    }

    var body: some View {
        Group {
            if isLoading && works.isEmpty {
                VStack { Spacer(); ProgressView("Loading…"); Spacer() }
            } else if let errorMessage, works.isEmpty {
                ContentUnavailableView("Couldn't load works", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else if works.isEmpty {
                ContentUnavailableView("No works found", systemImage: "magnifyingglass",
                    description: Text("Try adjusting your filters or search terms."))
            } else if visibleWorks.isEmpty {
                ContentUnavailableView("Nothing to show", systemImage: "eye.slash",
                    description: Text("Every match is hidden or filtered out by your content settings."))
            } else {
                List {
                    Section {
                        ForEach(visibleWorks) { work in
                            NavigationLink(value: work) { WorkRow(work: work) }
                                // Infinite scroll: when the last loaded row comes
                                // into view, pull the next page automatically.
                                .onAppear {
                                    if work.id == visibleWorks.last?.id {
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
                    } header: {
                        activeFilterSummary
                    }
                }
                .listStyle(.plain)
            }
        }
        // When re-filtering with results already showing, dim + spin so it's
        // clear the search is running (filter changes resolve tags + refetch,
        // which takes a moment).
        .overlay {
            if isLoading && !works.isEmpty {
                ZStack {
                    Color(.systemBackground).opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Applying filters…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Image(systemName: activeFilterCount > 0
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            WorkFilterSheet(filters: $filters) {
                Task { await applyFilters() }
            }
        }
        .task { await loadFirst() }
    }

    @ViewBuilder
    private var activeFilterSummary: some View {
        if !filterChips.isEmpty {
            // Tapping the summary opens the filter dialog.
            Button {
                showingFilters = true
            } label: {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(filterChips, id: \.self) { chip in
                            Text(chip)
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .padding(.leading, 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .padding(.vertical, 2)
        }
    }

    private var filterChips: [String] {
        var chips: [String] = ["\(filters.sortColumn.displayName) \(filters.sortDirection == .asc ? "↑" : "↓")"]
        chips += filters.ratings.map(\.displayName)
        chips += filters.warnings.map { $0.displayName }
        chips += filters.categories.map(\.displayName)
        chips += filters.relationshipNames
        chips += filters.characterNames
        chips += filters.freeformNames
        chips += filters.excludedFreeforms.map { "−\($0)" }
        switch filters.complete {
        case .yes: chips.append("Complete")
        case .no:  chips.append("WIP")
        case .any: break
        }
        switch filters.crossover {
        case .yes: chips.append("Crossovers only")
        case .no:  chips.append("No crossovers")
        case .any: break
        }
        if filters.singleChapter { chips.append("Oneshot") }
        if !filters.wordCount.isEmpty { chips.append("words \(filters.wordCount)") }
        if !filters.languageId.isEmpty { chips.append("lang \(filters.languageId)") }
        return chips
    }

    private var activeFilterCount: Int {
        filters.ratings.count + filters.warnings.count + filters.categories.count
            + filters.relationshipNames.count + filters.characterNames.count
            + filters.freeformNames.count + filters.excludedFreeforms.count
            + (filters.complete != .any ? 1 : 0)
            + (filters.crossover != .any ? 1 : 0)
            + (filters.singleChapter ? 1 : 0)
            + (filters.wordCount.isEmpty ? 0 : 1)
            + (filters.languageId.isEmpty ? 0 : 1)
    }

    /// Resolve user-typed tags to AO3's canonical names, then search.
    private func applyFilters() async {
        isLoading = true
        errorMessage = nil
        // The fandom is already an AO3-canonical name (picked from the live
        // fandom list), so skip resolving it — fewer throttled round-trips.
        filters = await TagResolver.resolve(filters, using: client, resolveFandoms: false)
        // Filters changed: force a page-1 refetch even though `works` is
        // populated (loadFirst would no-op). `reload` swaps in the new results
        // only once they arrive, so the old list stays visible (dimmed by the
        // overlay) during the fetch.
        await reload()
    }

    /// Initial load driven by `.task`. Navigating into a work and back makes
    /// SwiftUI re-run the `.task`, so guard against re-fetching: a blind reload
    /// would reset `works`/`currentPage`/`totalPages` to page 1, and because the
    /// already-mounted first-page rows keep their identities, the last row's
    /// `.onAppear` never re-fires — leaving infinite scroll permanently stuck on
    /// page 1. Re-filtering still refetches unconditionally via `reload`.
    private func loadFirst() async {
        guard works.isEmpty else { return }
        await reload()
    }

    /// Unconditional page-1 fetch, used on first appearance and after the user
    /// changes the active filters.
    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.search(filters: filters, page: 1)
            works = result.works
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func loadMore() async {
        // Re-entrancy / bounds guard: onAppear can fire repeatedly, and there's
        // no page beyond totalPages.
        guard !isLoadingMore, currentPage < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await client.search(filters: filters, page: currentPage + 1)
            let existing = Set(works.map(\.id))
            works.append(contentsOf: result.works.filter { !existing.contains($0.id) })
            currentPage = result.currentPage
            totalPages = result.totalPages
        } catch {
            errorMessage = "\(error)"
        }
    }
}

#Preview {
    NavigationStack { BrowseView() }
        .environment(\.ao3Client, MockAO3Client())
}

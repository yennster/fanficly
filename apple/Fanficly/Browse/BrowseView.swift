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

/// Navigation value for a popular tag tapped in the Popular tab.
struct PopularTag: Hashable {
    enum Kind: String, CaseIterable, Identifiable, Hashable {
        case fandom, ship, character
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fandom: "Fandoms"
            case .ship: "Ships"
            case .character: "Characters"
            }
        }
        var symbol: String {
            switch self {
            case .fandom: "books.vertical"
            case .ship: "heart"
            case .character: "person"
            }
        }
    }
    let kind: Kind
    let name: String
}

/// On-device cache for the live popular snapshot. Refreshed at most once a day
/// (the data is AO3's cumulative work counts, which barely move day to day), so
/// opening the Popular tab doesn't re-scrape AO3 every time. Falls back to the
/// curated `PopularTags` seed whenever there's no fresh snapshot.
enum PopularStore {
    private static let key = "popular.snapshot.v1"
    private static let maxAge: TimeInterval = 24 * 60 * 60

    static func cached() -> PopularSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PopularSnapshot.self, from: data)
    }

    static func isStale(_ snapshot: PopularSnapshot?) -> Bool {
        guard let snapshot else { return true }
        return Date.now.timeIntervalSince(snapshot.fetchedAt) > maxAge
    }

    /// Returns a fresh snapshot, fetching + caching only when the cache is
    /// missing or older than a day. Never throws — keeps the existing cache on
    /// failure so the UI just keeps showing what it had (or the curated seed).
    @discardableResult
    static func refreshIfStale(client: any AO3ClientProtocol) async -> PopularSnapshot? {
        let current = cached()
        guard isStale(current) else { return current }
        guard let fresh = try? await client.fetchPopularSnapshot() else { return current }
        if let data = try? JSONEncoder().encode(fresh) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return fresh
    }
}

/// The "Popular" tab: popular fandoms, ships, and characters. Pick a segment,
/// tap a tag, and see its works sorted by kudos. The lists are live — ranked
/// from AO3's work counts (`PopularStore`, cached ~daily) — and fall back to
/// the curated `PopularTags` seed when no snapshot is available yet.
struct PopularView: View {
    @Environment(\.ao3Client) private var client
    @State private var segment: PopularTag.Kind = .fandom
    @State private var snapshot: PopularSnapshot? = PopularStore.cached()

    private var names: [String] {
        let all: [String]
        switch segment {
        case .fandom:    all = live(snapshot?.fandoms, fallback: PopularTags.fandoms)
        case .ship:      all = live(snapshot?.ships, fallback: PopularTags.ships)
        case .character: all = live(snapshot?.characters, fallback: PopularTags.characters)
        }
        return Array(all.prefix(30))   // top 30 per segment
    }

    /// The live list when present and non-empty, otherwise the curated seed.
    private func live(_ list: [String]?, fallback: [String]) -> [String] {
        if let list, !list.isEmpty { return list }
        return fallback
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Category", selection: $segment) {
                ForEach(PopularTag.Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                ForEach(names, id: \.self) { name in
                    NavigationLink(value: PopularTag(kind: segment, name: name)) {
                        Label {
                            Text(displayName(name)).font(.body)
                        } icon: {
                            Image(systemName: segment == .fandom ? FandomCatalog.symbol(for: name) : segment.symbol)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Popular")
        .navigationDestination(for: PopularTag.self) { tag in
            FandomWorksView(popular: tag)
        }
        .workAndAuthorDestinations()
        // Refresh in the background (≤ once/day); the curated/cached lists show
        // immediately and swap to live data when the fetch lands.
        .task {
            if let fresh = await PopularStore.refreshIfStale(client: client) {
                snapshot = fresh
            }
        }
    }

    /// Trim AO3's canonical disambiguation noise for display only — the search
    /// still uses the full canonical `name`. "Harry Potter - J. K. Rowling" →
    /// "Harry Potter"; "Castiel (Supernatural)" keeps its qualifier.
    private func displayName(_ name: String) -> String {
        if segment == .fandom {
            return name.components(separatedBy: " - ").first ?? name
        }
        return name
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

    /// A popular tag (fandom / ship / character), sorted by kudos so the
    /// most-loved works surface first.
    init(popular tag: PopularTag) {
        var initial = AO3SearchFilters()
        switch tag.kind {
        case .fandom:    initial.fandomNames = [tag.name]
        case .ship:      initial.relationshipNames = [tag.name]
        case .character: initial.characterNames = [tag.name]
        }
        initial.sortColumn = .kudosCount
        initial.sortDirection = .desc
        self.init(filters: initial, title: tag.name)
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
                .accessibilityLabel("Filters")
                .accessibilityValue(activeFilterCount > 0 ? "\(activeFilterCount) active" : "None")
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
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Active filters: \(filterChips.joined(separator: ", "))")
            .accessibilityHint("Opens filter options.")
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

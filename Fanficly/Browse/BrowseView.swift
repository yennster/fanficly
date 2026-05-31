import SwiftUI

struct BrowseView: View {
    var body: some View {
        List(FandomCatalog.all) { category in
            NavigationLink(value: category) {
                Label(category.name, systemImage: category.symbol)
                    .font(.body)
            }
        }
        .navigationTitle("Browse")
        .navigationDestination(for: FandomCategory.self) { category in
            CategoryFandomsView(category: category)
        }
        .navigationDestination(for: BrowseFandom.self) { fandom in
            FandomWorksView(fandom: fandom)
        }
        .navigationDestination(for: AO3WorkSummary.self) { work in
            WorkDetailView(workId: work.id)
        }
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
    let fandom: BrowseFandom
    @State private var works: [AO3WorkSummary] = []
    @State private var currentPage: Int = 1
    @State private var totalPages: Int = 1
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var errorMessage: String?
    @State private var filters: AO3SearchFilters
    @State private var showingFilters = false

    init(fandom: BrowseFandom) {
        self.fandom = fandom
        var initial = AO3SearchFilters()
        initial.fandomNames = [fandom.canonicalName]
        initial.sortColumn = .revisedAt
        initial.sortDirection = .desc
        _filters = State(initialValue: initial)
    }

    var body: some View {
        Group {
            if isLoading && works.isEmpty {
                VStack { Spacer(); ProgressView("Loading…"); Spacer() }
            } else if let errorMessage, works.isEmpty {
                ContentUnavailableView("Couldn't load works", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else if works.isEmpty {
                ContentUnavailableView("No works found", systemImage: "tray",
                    description: Text("Nothing matched these filters. Try loosening them."))
            } else {
                List {
                    Section {
                        ForEach(works) { work in
                            NavigationLink(value: work) { WorkRow(work: work) }
                        }
                        if currentPage < totalPages {
                            HStack {
                                Spacer()
                                if isLoadingMore {
                                    ProgressView()
                                } else {
                                    Button("Load more (page \(currentPage + 1) of \(totalPages))") {
                                        Task { await loadMore() }
                                    }
                                    .font(.callout)
                                }
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
        .navigationTitle(fandom.displayName)
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
                Task { await loadFirst() }
            }
        }
        .task { await loadFirst() }
    }

    @ViewBuilder
    private var activeFilterSummary: some View {
        if !filterChips.isEmpty {
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
                }
            }
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

    private func loadFirst() async {
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

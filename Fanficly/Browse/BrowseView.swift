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

    private var displayed: [BrowseFandom] {
        let base = liveFandoms.isEmpty ? category.fandoms : liveFandoms
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return base }
        return base.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
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
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                }
            } header: {
                let count = displayed.count
                let total = liveFandoms.isEmpty ? category.fandoms.count : liveFandoms.count
                if liveFandoms.isEmpty && isLoading {
                    Text("\(category.fandoms.count) popular · loading full list…")
                        .textCase(nil)
                } else if !liveFandoms.isEmpty {
                    Text("\(count) of \(total) fandoms")
                        .textCase(nil)
                } else {
                    Text("\(count) popular fandoms")
                        .textCase(nil)
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search fandoms")
        .task { await loadLive() }
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
    @State private var sortColumn: AO3SearchFilters.SortColumn = .revisedAt
    @State private var sortDirection: AO3SearchFilters.SortDirection = .desc

    var body: some View {
        Group {
            if isLoading && works.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Loading…")
                    Spacer()
                }
            } else if let errorMessage, works.isEmpty {
                ContentUnavailableView("Couldn't load works", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else if works.isEmpty {
                ContentUnavailableView("No works found", systemImage: "tray",
                    description: Text("This fandom doesn't seem to have any visible works."))
            } else {
                List {
                    Section {
                        ForEach(works) { work in
                            NavigationLink(value: work) {
                                WorkRow(work: work)
                            }
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
                        HStack {
                            sortMenu
                            Spacer()
                        }
                        .textCase(nil)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(fandom.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadFirst() }
    }

    private var sortMenu: some View {
        HStack(spacing: 10) {
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
            .onChange(of: sortColumn) { _, _ in Task { await loadFirst() } }

            Button {
                sortDirection = sortDirection == .asc ? .desc : .asc
                Task { await loadFirst() }
            } label: {
                Image(systemName: sortDirection.symbol)
                    .font(.subheadline)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func makeFilters() -> AO3SearchFilters {
        var filters = AO3SearchFilters()
        filters.fandomNames = [fandom.canonicalName]
        filters.sortColumn = sortColumn
        filters.sortDirection = sortDirection
        return filters
    }

    private func loadFirst() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.search(filters: makeFilters(), page: 1)
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
            let result = try await client.search(filters: makeFilters(), page: currentPage + 1)
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

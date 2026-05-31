import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedSearch.savedAt, order: .reverse) private var savedSearches: [SavedSearch]
    @State private var prompt: String = ""
    @State private var lastParsed: AO3SearchFilters = AO3SearchFilters()
    @State private var results: [AO3WorkSummary] = []
    @State private var currentPage: Int = 1
    @State private var totalPages: Int = 1
    @State private var isSearching: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var errorMessage: String?
    @State private var sortColumn: AO3SearchFilters.SortColumn = .bestMatch
    @State private var sortDirection: AO3SearchFilters.SortDirection = .desc
    @State private var showingSaveDialog: Bool = false
    @State private var saveName: String = ""
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
        .navigationDestination(for: AO3WorkSummary.self) { work in
            WorkDetailView(workId: work.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    saveName = suggestName()
                    showingSaveDialog = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .alert("Save search", isPresented: $showingSaveDialog) {
            TextField("Name", text: $saveName)
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the prompt and sort options so you can re-run it later.")
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("e.g. edward/bella romance all human complete", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
                .onChange(of: prompt) { _, newValue in
                    // A vertical-axis TextField inserts a newline on Return
                    // rather than firing onSubmit. Treat a trailing newline
                    // as "search now".
                    if newValue.contains("\n") {
                        prompt = newValue.replacingOccurrences(of: "\n", with: "")
                        lastParsed = parser.parse(prompt)
                        Task { await runSearch() }
                    } else {
                        lastParsed = parser.parse(prompt)
                    }
                }

            sortBar

            if !lastParsed.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(includeChips(), id: \.self) { chip in
                        ChipView(text: chip, kind: .include)
                    }
                    ForEach(lastParsed.excludedFreeforms, id: \.self) { tag in
                        ChipView(text: tag, kind: .exclude)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
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
        } else if results.isEmpty && !savedSearches.isEmpty {
            savedSearchesList
        } else if results.isEmpty {
            ContentUnavailableView("Type a prompt", systemImage: "sparkle.magnifyingglass",
                description: Text("e.g. \"edward/bella romance all human complete\""))
        } else {
            List {
                ForEach(results) { work in
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
                if !results.isEmpty { Task { await runSearch() } }
            }

            Button {
                sortDirection = sortDirection == .asc ? .desc : .asc
                if !results.isEmpty { Task { await runSearch() } }
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
        var filters = parser.parse(prompt)
        if !filters.query.isEmpty {
            filters = await enricher.enrich(filters: filters, prompt: filters.query)
        }
        filters.sortColumn = sortColumn
        filters.sortDirection = sortDirection
        lastParsed = filters
        errorMessage = nil
        isSearching = true
        currentPage = 1
        defer { isSearching = false }
        do {
            let result = try await client.search(filters: filters, page: 1)
            results = result.works
            totalPages = result.totalPages
            currentPage = result.currentPage
        } catch let AO3Error.loginFailed(reason) {
            errorMessage = reason
        } catch let AO3Error.http(status) {
            errorMessage = "AO3 returned HTTP \(status)"
        } catch let AO3Error.parseFailed(reason) {
            errorMessage = "Couldn't parse AO3's response: \(reason)"
        } catch let AO3Error.network(underlying) {
            errorMessage = "Network: \(underlying)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
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

    private func includeChips() -> [String] {
        var chips: [String] = []
        chips.append(contentsOf: lastParsed.relationshipNames.map { "♥ \($0)" })
        chips.append(contentsOf: lastParsed.characterNames.map { "👤 \($0)" })
        chips.append(contentsOf: lastParsed.fandomNames.map { "📚 \($0)" })
        chips.append(contentsOf: lastParsed.freeformNames)
        chips.append(contentsOf: lastParsed.ratings.map(\.displayName))
        chips.append(contentsOf: lastParsed.warnings.map(\.displayName))
        chips.append(contentsOf: lastParsed.categories.map(\.displayName))
        if !lastParsed.wordCount.isEmpty { chips.append("words \(lastParsed.wordCount)") }
        if !lastParsed.languageId.isEmpty { chips.append("lang \(lastParsed.languageId)") }
        if lastParsed.singleChapter { chips.append("oneshot") }
        switch lastParsed.complete {
        case .yes: chips.append("complete")
        case .no:  chips.append("WIP")
        case .any: break
        }
        switch lastParsed.crossover {
        case .yes: chips.append("crossover")
        case .no:  chips.append("no crossover")
        case .any: break
        }
        if !lastParsed.query.isEmpty { chips.append("\u{201C}\(lastParsed.query)\u{201D}") }
        return chips
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
    }
}

struct ChipView: View {
    enum Kind { case include, exclude }
    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
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
    @Environment(AuthState.self) private var auth
    let workId: Int
    @State private var payload: AO3WorkPayload?
    @State private var errorMessage: String?
    @State private var isSavingOffline: Bool = false
    @State private var isKudosing: Bool = false
    @State private var isSubscribing: Bool = false
    @State private var kudosed: Bool = false
    @State private var subscribed: Bool = false
    @State private var followed: Bool = false
    @State private var epubURL: URL?
    @State private var showingComments: Bool = false

    var body: some View {
        Group {
            if let payload {
                ReaderView(payload: payload)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            followButton(payload: payload)

                            if auth.isLoggedIn {
                                kudosButton
                            }

                            WorkExportButton(workId: workId, title: payload.summary.title)

                            moreMenu(payload: payload)
                        }
                    }
                    .sheet(isPresented: $showingComments) {
                        if let url = try? AO3Endpoints.workComments(id: workId, base: URL(string: "https://archiveofourown.org")!) {
                            SafariView(url: url)
                                .ignoresSafeArea()
                        }
                    }
            } else if let errorMessage {
                ContentUnavailableView("Couldn't load work", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    // MARK: - Toolbar buttons

    private func followButton(payload: AO3WorkPayload) -> some View {
        Button {
            followed = WorkPersistence.toggleFollow(summary: payload.summary, into: context)
        } label: {
            Image(systemName: followed ? "bookmark.fill" : "bookmark")
                .foregroundStyle(followed ? Color.accentColor : Color.primary)
        }
        .accessibilityLabel(followed ? "Following" : "Follow")
    }

    private var kudosButton: some View {
        Button {
            Task { await postKudos() }
        } label: {
            if isKudosing {
                ProgressView()
            } else {
                Image(systemName: kudosed ? "heart.fill" : "heart")
                    .foregroundStyle(kudosed ? .pink : .primary)
            }
        }
        .disabled(isKudosing || kudosed)
    }

    private func moreMenu(payload: AO3WorkPayload) -> some View {
        Menu {
            saveOfflineRow(payload: payload)
            Button {
                showingComments = true
            } label: {
                Label("Comments", systemImage: "text.bubble")
            }
            if auth.isLoggedIn {
                Button {
                    Task { await subscribe() }
                } label: {
                    Label(subscribed ? "Subscribed on AO3" : "Subscribe on AO3",
                          systemImage: subscribed ? "bell.fill" : "bell")
                }
                .disabled(isSubscribing || subscribed)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func saveOfflineRow(payload: AO3WorkPayload) -> some View {
        Button {
            Task { await saveOffline(payload) }
        } label: {
            Label(epubURL == nil ? "Save offline" : "Saved offline ✓",
                  systemImage: epubURL == nil ? "arrow.down.circle" : "checkmark.circle.fill")
        }
        .disabled(isSavingOffline || epubURL != nil)
    }

    // MARK: - Actions

    private func load() async {
        epubURL = WorkPersistence.epubURL(workId: workId)
        followed = WorkPersistence.isFollowed(workId: workId, in: context)
        do {
            payload = try await client.fetchWork(id: workId)
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

    private func postKudos() async {
        isKudosing = true
        defer { isKudosing = false }
        do {
            try await client.postKudos(workId: workId)
            kudosed = true
        } catch {
            errorMessage = "Couldn't post kudos: \(error)"
        }
    }

    private func subscribe() async {
        isSubscribing = true
        defer { isSubscribing = false }
        do {
            try await client.subscribeToWork(workId: workId)
            subscribed = true
        } catch {
            errorMessage = "Couldn't subscribe: \(error)"
        }
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environment(\.ao3Client, MockAO3Client())
}

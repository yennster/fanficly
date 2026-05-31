import SwiftUI

struct SearchView: View {
    @Environment(\.ao3Client) private var client
    @State private var prompt: String = ""
    @State private var lastParsed: AO3SearchFilters = AO3SearchFilters()
    @State private var results: [AO3WorkSummary] = []
    @State private var isSearching: Bool = false
    @State private var errorMessage: String?
    private let parser = SearchPromptParser()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptField

            if !lastParsed.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(includeChips(), id: \.self) { chip in
                            ChipView(text: chip, kind: .include)
                        }
                        ForEach(lastParsed.excludedFreeforms, id: \.self) { tag in
                            ChipView(text: tag, kind: .exclude)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }

            if isSearching {
                ProgressView("Searching AO3…").frame(maxWidth: .infinity).padding()
            } else if let error = errorMessage {
                ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if results.isEmpty {
                ContentUnavailableView("Type a prompt", systemImage: "sparkle.magnifyingglass",
                    description: Text("e.g. \"edward/bella romance all human explicit\""))
            } else {
                List(results) { work in
                    NavigationLink(value: work) {
                        WorkRow(work: work)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Search")
        .navigationDestination(for: AO3WorkSummary.self) { work in
            WorkDetailView(workId: work.id)
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("e.g. edward/bella romance all human explicit -mpreg", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
                .onChange(of: prompt) { _, _ in lastParsed = parser.parse(prompt) }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private func runSearch() async {
        let filters = parser.parse(prompt)
        lastParsed = filters
        errorMessage = nil
        isSearching = true
        defer { isSearching = false }
        do {
            let result = try await client.search(filters: filters, page: 1)
            results = result.works
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

    private func includeChips() -> [String] {
        var chips: [String] = []
        chips.append(contentsOf: lastParsed.relationshipNames.map { "♥ \($0)" })
        chips.append(contentsOf: lastParsed.characterNames.map { "👤 \($0)" })
        chips.append(contentsOf: lastParsed.fandomNames)
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
    let workId: Int
    @State private var payload: AO3WorkPayload?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let payload {
                ReaderView(payload: payload)
            } else if let errorMessage {
                ContentUnavailableView("Couldn't load work", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            payload = try await client.fetchWork(id: workId)
        } catch {
            errorMessage = "\(error)"
        }
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environment(\.ao3Client, MockAO3Client())
}

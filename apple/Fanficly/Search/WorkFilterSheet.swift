import SwiftUI
import SwiftData

/// AO3-style filter panel that edits an `AO3SearchFilters`. The fandom (or
/// any other already-fixed field) is preserved by the caller; this sheet
/// edits ratings, warnings, categories, status, word count, tags, etc.
///
/// It edits a draft and writes it back only on Apply, so Cancel (or a swipe
/// down with nothing changed) leaves the caller's filters, and the chips and
/// results they drive, as they were (#156).
struct WorkFilterSheet: View {
    @Binding var filters: AO3SearchFilters
    let onApply: () -> Void
    @State private var draft: AO3SearchFilters
    /// The caller's filters as the fields would write them back unchanged
    /// (an exact "5000" reads back as "5000-5000"), for `hasChanges`.
    private let original: AO3SearchFilters
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedFilter.savedAt, order: .reverse) private var savedFilters: [SavedFilter]

    // Editable text mirrors for the comma-separated tag fields.
    @State private var relationshipsText: String = ""
    @State private var charactersText: String = ""
    @State private var freeformsText: String = ""
    @State private var excludeText: String = ""
    @State private var wordsFrom: String = ""
    @State private var wordsTo: String = ""
    @State private var showingSaveDialog = false
    @State private var saveName = ""

    init(filters: Binding<AO3SearchFilters>, onApply: @escaping () -> Void) {
        _filters = filters
        let f = filters.wrappedValue
        _draft = State(initialValue: f)
        self.onApply = onApply
        // Seed the text mirrors here, not in onAppear, so the first frame's
        // `hasChanges` already sees them.
        _relationshipsText = State(initialValue: f.relationshipNames.joined(separator: ", "))
        _charactersText = State(initialValue: f.characterNames.joined(separator: ", "))
        _freeformsText = State(initialValue: f.freeformNames.joined(separator: ", "))
        _excludeText = State(initialValue: f.excludedFreeforms.joined(separator: ", "))
        let words = Self.wordFields(f.wordCount)
        _wordsFrom = State(initialValue: words.from)
        _wordsTo = State(initialValue: words.to)
        var normalized = f
        normalized.wordCount = Self.wordCount(from: words.from, to: words.to)
        original = normalized
    }

    /// The draft as Apply would write it: toggles plus the text fields.
    private var committedDraft: AO3SearchFilters {
        var f = draft
        f.relationshipNames = splitTags(relationshipsText)
        f.characterNames = splitTags(charactersText)
        f.freeformNames = splitTags(freeformsText)
        f.excludedFreeforms = splitTags(excludeText)
        f.wordCount = Self.wordCount(from: wordsFrom, to: wordsTo)
        return f
    }

    private var hasChanges: Bool { committedDraft != original }

    var body: some View {
        NavigationStack {
            Form {
                savedFiltersSection
                sortSection
                ratingsSection
                warningsSection
                categoriesSection
                statusSection
                wordCountSection
                tagsSection
                languageSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            // Swiping down would silently drop the edits; Cancel is explicit.
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset", role: .destructive) { reset() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        commitText()
                        filters = draft
                        onApply()
                        dismiss()
                    }
                    .bold()
                }
            }
            .alert("Save filter", isPresented: $showingSaveDialog) {
                TextField("Name", text: $saveName)
                Button("Save") { saveCurrentFilter() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves these filters (rating, tags, status, etc.) so you can apply them to any fandom later. The fandom itself isn't saved.")
            }
        }
    }

    private var savedFiltersSection: some View {
        Section("Saved filters") {
            ForEach(savedFilters) { saved in
                Button {
                    applySaved(saved)
                } label: {
                    Label(saved.name, systemImage: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.primary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        iCloudSyncManager.recordDeletion(.filter, key: saved.name)
                        context.delete(saved)
                        try? context.save()
                        iCloudSyncManager.shared.queueBackup(context: context)
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
            Button {
                commitText()
                saveName = draft.suggestedName()
                showingSaveDialog = true
            } label: {
                Label("Save current filters…", systemImage: "plus.circle")
            }
        }
    }

    private func applySaved(_ saved: SavedFilter) {
        guard var loaded = AO3SearchFilters.from(savedJSON: saved.filtersJSON) else { return }
        loaded.fandomNames = draft.fandomNames  // keep the current fandom
        draft = loaded
        seedText()
    }

    private func saveCurrentFilter() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let json = draft.savedJSON()
        let descriptor = FetchDescriptor<SavedFilter>(predicate: #Predicate { $0.name == name })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.filtersJSON = json
            existing.savedAt = .now
        } else {
            context.insert(SavedFilter(name: name, filtersJSON: json))
        }
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
    }

    // MARK: - Sections

    private var sortSection: some View {
        Section("Sort") {
            Picker("Sort by", selection: $draft.sortColumn) {
                ForEach(AO3SearchFilters.SortColumn.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Picker("Direction", selection: $draft.sortDirection) {
                ForEach(AO3SearchFilters.SortDirection.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
        }
    }

    private var ratingsSection: some View {
        Section("Rating") {
            ForEach(AO3SearchFilters.Rating.allCases, id: \.self) { rating in
                toggleRow(rating.displayName, in: $draft.ratings, element: rating)
            }
        }
    }

    private var warningsSection: some View {
        Section("Archive warnings") {
            ForEach(AO3SearchFilters.ArchiveWarning.allCases, id: \.self) { warning in
                toggleRow(warning.displayName, in: $draft.warnings, element: warning)
            }
        }
    }

    private var categoriesSection: some View {
        Section("Category") {
            ForEach(AO3SearchFilters.Category.allCases, id: \.self) { category in
                toggleRow(category.displayName, in: $draft.categories, element: category)
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            Picker("Completion", selection: $draft.complete) {
                Text("Any").tag(AO3SearchFilters.TriState.any)
                Text("Complete only").tag(AO3SearchFilters.TriState.yes)
                Text("Work in progress").tag(AO3SearchFilters.TriState.no)
            }
            Picker("Crossovers", selection: $draft.crossover) {
                Text("Include").tag(AO3SearchFilters.TriState.any)
                Text("Only crossovers").tag(AO3SearchFilters.TriState.yes)
                Text("Exclude crossovers").tag(AO3SearchFilters.TriState.no)
            }
            Toggle("Single chapter / oneshot", isOn: $draft.singleChapter)
        }
    }

    private var wordCountSection: some View {
        Section("Word count") {
            HStack {
                TextField("From", text: $wordsFrom)
                    .keyboardType(.numberPad)
                Text("–").foregroundStyle(.secondary)
                TextField("To", text: $wordsTo)
                    .keyboardType(.numberPad)
            }
        }
    }

    private var tagsSection: some View {
        Section {
            tagField("Relationships", text: $relationshipsText, example: "Hermione Granger/Draco Malfoy")
            tagField("Characters", text: $charactersText, example: "Hermione Granger")
            tagField("Additional tags", text: $freeformsText, example: "Slow Burn, Fluff")
            tagField("Exclude tags", text: $excludeText, example: "Angst, Major Character Death")
        } header: {
            Text("Tags")
        } footer: {
            Text("Separate multiple tags with commas. Use the AO3 canonical name for best results.")
        }
    }

    private var languageSection: some View {
        Section("Language") {
            Picker("Language", selection: $draft.languageId) {
                Text("Any").tag("")
                Text("English").tag("en")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Chinese").tag("zh")
                Text("Russian").tag("ru")
                Text("Portuguese").tag("pt")
                Text("Italian").tag("it")
                Text("Japanese").tag("ja")
                Text("Korean").tag("ko")
            }
        }
    }

    // MARK: - Helpers

    private func toggleRow<Element: Hashable & Sendable>(
        _ title: String,
        in set: Binding<Set<Element>>,
        element: Element
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { set.wrappedValue.contains(element) },
            set: { on in
                if on { set.wrappedValue.insert(element) } else { set.wrappedValue.remove(element) }
            }
        ))
    }

    private func tagField(_ label: String, text: Binding<String>, example: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(example, text: text, axis: .vertical)
                .textInputAutocapitalization(.words)
        }
    }

    private func seedText() {
        relationshipsText = draft.relationshipNames.joined(separator: ", ")
        charactersText = draft.characterNames.joined(separator: ", ")
        freeformsText = draft.freeformNames.joined(separator: ", ")
        excludeText = draft.excludedFreeforms.joined(separator: ", ")
        (wordsFrom, wordsTo) = Self.wordFields(draft.wordCount)
    }

    private func commitText() {
        draft = committedDraft
    }

    private func splitTags(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parses a "from-to" / ">n" / "<n" / exact "n" word count into the two
    /// fields. Both start empty, so a count with only one bound (or none)
    /// never keeps the other field's old value.
    nonisolated static func wordFields(_ wc: String) -> (from: String, to: String) {
        if wc.contains("-") {
            let parts = wc.split(separator: "-")
            return (parts.first.map(String.init) ?? "", parts.count > 1 ? String(parts[1]) : "")
        } else if wc.hasPrefix(">") {
            return (String(wc.dropFirst()), "")
        } else if wc.hasPrefix("<") {
            return ("", String(wc.dropFirst()))
        } else if !wc.isEmpty, wc.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return (wc, wc)  // an exact count
        }
        return ("", "")
    }

    /// Builds the count from the two fields (an exact count comes back as "n-n").
    nonisolated static func wordCount(from rawFrom: String, to rawTo: String) -> String {
        let from = rawFrom.trimmingCharacters(in: .whitespaces)
        let to = rawTo.trimmingCharacters(in: .whitespaces)
        switch (from.isEmpty, to.isEmpty) {
        case (false, false): return "\(from)-\(to)"
        case (false, true):  return ">\(from)"
        case (true, false):  return "<\(to)"
        case (true, true):   return ""
        }
    }

    private func reset() {
        var fresh = AO3SearchFilters()
        fresh.fandomNames = draft.fandomNames
        draft = fresh
        seedText()
    }
}

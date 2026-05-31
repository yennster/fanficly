import SwiftUI

/// AO3-style filter panel that edits an `AO3SearchFilters`. The fandom (or
/// any other already-fixed field) is preserved by the caller; this sheet
/// edits ratings, warnings, categories, status, word count, tags, etc.
struct WorkFilterSheet: View {
    @Binding var filters: AO3SearchFilters
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    // Editable text mirrors for the comma-separated tag fields.
    @State private var relationshipsText: String = ""
    @State private var charactersText: String = ""
    @State private var freeformsText: String = ""
    @State private var excludeText: String = ""
    @State private var wordsFrom: String = ""
    @State private var wordsTo: String = ""

    var body: some View {
        NavigationStack {
            Form {
                sortSection
                ratingsSection
                warningsSection
                categoriesSection
                statusSection
                wordCountSection
                tagsSection
                languageSection
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset", role: .destructive) { reset() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        commitText()
                        onApply()
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear(perform: seedText)
        }
    }

    // MARK: - Sections

    private var sortSection: some View {
        Section("Sort") {
            Picker("Sort by", selection: $filters.sortColumn) {
                ForEach(AO3SearchFilters.SortColumn.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Picker("Direction", selection: $filters.sortDirection) {
                ForEach(AO3SearchFilters.SortDirection.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
        }
    }

    private var ratingsSection: some View {
        Section("Rating") {
            ForEach(AO3SearchFilters.Rating.allCases, id: \.self) { rating in
                toggleRow(rating.displayName, isOn: filters.ratings.contains(rating)) { on in
                    if on { filters.ratings.insert(rating) } else { filters.ratings.remove(rating) }
                }
            }
        }
    }

    private var warningsSection: some View {
        Section("Archive warnings") {
            ForEach(AO3SearchFilters.ArchiveWarning.allCases, id: \.self) { warning in
                toggleRow(warning.displayName, isOn: filters.warnings.contains(warning)) { on in
                    if on { filters.warnings.insert(warning) } else { filters.warnings.remove(warning) }
                }
            }
        }
    }

    private var categoriesSection: some View {
        Section("Category") {
            ForEach(AO3SearchFilters.Category.allCases, id: \.self) { category in
                toggleRow(category.displayName, isOn: filters.categories.contains(category)) { on in
                    if on { filters.categories.insert(category) } else { filters.categories.remove(category) }
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            Picker("Completion", selection: $filters.complete) {
                Text("Any").tag(AO3SearchFilters.TriState.any)
                Text("Complete only").tag(AO3SearchFilters.TriState.yes)
                Text("Work in progress").tag(AO3SearchFilters.TriState.no)
            }
            Picker("Crossovers", selection: $filters.crossover) {
                Text("Include").tag(AO3SearchFilters.TriState.any)
                Text("Only crossovers").tag(AO3SearchFilters.TriState.yes)
                Text("Exclude crossovers").tag(AO3SearchFilters.TriState.no)
            }
            Toggle("Single chapter / oneshot", isOn: $filters.singleChapter)
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
            Picker("Language", selection: $filters.languageId) {
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

    private func toggleRow(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: set))
    }

    private func tagField(_ label: String, text: Binding<String>, example: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(example, text: text, axis: .vertical)
                .textInputAutocapitalization(.words)
        }
    }

    private func seedText() {
        relationshipsText = filters.relationshipNames.joined(separator: ", ")
        charactersText = filters.characterNames.joined(separator: ", ")
        freeformsText = filters.freeformNames.joined(separator: ", ")
        excludeText = filters.excludedFreeforms.joined(separator: ", ")
        // Parse an existing "from-to" / ">n" / "<n" word count back into fields.
        let wc = filters.wordCount
        if wc.contains("-") {
            let parts = wc.split(separator: "-")
            wordsFrom = parts.first.map(String.init) ?? ""
            wordsTo = parts.count > 1 ? String(parts[1]) : ""
        } else if wc.hasPrefix(">") {
            wordsFrom = String(wc.dropFirst())
        } else if wc.hasPrefix("<") {
            wordsTo = String(wc.dropFirst())
        }
    }

    private func commitText() {
        filters.relationshipNames = splitTags(relationshipsText)
        filters.characterNames = splitTags(charactersText)
        filters.freeformNames = splitTags(freeformsText)
        filters.excludedFreeforms = splitTags(excludeText)
        filters.wordCount = buildWordCount()
    }

    private func splitTags(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func buildWordCount() -> String {
        let from = wordsFrom.trimmingCharacters(in: .whitespaces)
        let to = wordsTo.trimmingCharacters(in: .whitespaces)
        switch (from.isEmpty, to.isEmpty) {
        case (false, false): return "\(from)-\(to)"
        case (false, true):  return ">\(from)"
        case (true, false):  return "<\(to)"
        case (true, true):   return ""
        }
    }

    private func reset() {
        let preservedFandoms = filters.fandomNames
        var fresh = AO3SearchFilters()
        fresh.fandomNames = preservedFandoms
        filters = fresh
        seedText()
        wordsFrom = ""; wordsTo = ""
    }
}

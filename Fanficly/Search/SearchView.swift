import SwiftUI

struct SearchView: View {
    @State private var prompt: String = ""
    @State private var lastParsed: AO3SearchFilters = AO3SearchFilters()
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

            Spacer()
            Text("Results will appear here once the AO3 search parser is wired up.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
            Spacer()
        }
        .navigationTitle("Search")
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("e.g. edward/bella romance all human explicit -mpreg", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { runParse() }
                .onChange(of: prompt) { _, _ in runParse() }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private func runParse() {
        lastParsed = parser.parse(prompt)
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
        case .no: chips.append("WIP")
        case .any: break
        }
        switch lastParsed.crossover {
        case .yes: chips.append("crossover")
        case .no: chips.append("no crossover")
        case .any: break
        }
        if !lastParsed.query.isEmpty { chips.append("\u{201C}\(lastParsed.query)\u{201D}") }
        return chips
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

#Preview {
    NavigationStack { SearchView() }
}

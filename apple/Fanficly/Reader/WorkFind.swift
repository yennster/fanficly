import SwiftUI

/// Find in this work (#183): searches the loaded chapters' text on the
/// device (nothing goes to AO3) and lists the paragraphs that hold the words,
/// with their chapter. Paragraph indices are the reader's own
/// (`HTMLToAttributed.speechParagraphs` is index-aligned with the rendered
/// paragraphs), so a match is a `ReadingAnchor` every reading mode can show.
enum WorkFind {
    /// One chapter's text, a string per rendered paragraph (an image slot is "").
    struct Chapter: Sendable {
        let index: Int
        let title: String
        let paragraphs: [String]
    }

    /// One paragraph holding the words. Several matches in one paragraph are
    /// one result, since choosing either shows the same paragraph.
    struct Match: Identifiable, Hashable, Sendable {
        let chapter: Int
        let paragraph: Int
        /// The paragraph's text around the first match, "…" where it's cut.
        let snippet: String
        /// Where the words sit in `snippet`, in characters.
        let highlight: Range<Int>
        /// How many times the words appear in this paragraph.
        let count: Int
        /// Where the words start in the paragraph, in characters.
        var offset: Int = 0

        var id: String { ChapterTracking.key(chapter: chapter, paragraph: paragraph) }
        var anchor: ReadingAnchor { ReadingAnchor(chapter: chapter, paragraph: paragraph) }
    }

    struct Result: Sendable, Equatable {
        var matches: [Match] = []
        /// More paragraphs matched than `limit`; only the first ones are listed.
        var truncated = false
        /// Every occurrence counted, including those past the limit.
        var total = 0
    }

    /// The most paragraphs listed: a one-letter search in a long work would
    /// otherwise list tens of thousands of rows.
    static let limit = 500

    /// Characters of context kept before the match in a snippet.
    static let leadingContext = 40
    /// The longest snippet, in characters.
    static let snippetLength = 140

    /// The chapters' paragraphs as the reader renders them. The conversion is
    /// cached, so after the first search (or the reader having drawn the
    /// chapter) this is cheap; it's safe off the main actor.
    static func chapters(from payloads: [AO3ChapterPayload], includeImages: Bool) -> [Chapter] {
        payloads.map {
            Chapter(index: $0.index, title: $0.title,
                    paragraphs: HTMLToAttributed.speechParagraphs($0.bodyHTML, includeImages: includeImages))
        }
    }

    /// Case, accent and width don't matter, and curly quotes match straight
    /// ones (fics use ’ where a keyboard types '). Every replacement swaps one
    /// character for one, so offsets in the folded text are offsets in the
    /// original too.
    static func fold(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201F}", "\u{2033}": out.append("\"")
            case "\u{2013}", "\u{2014}": out.append("-")
            case "\u{00A0}": out.append(" ")
            default: out.append(ch)
            }
        }
        return out
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// The query as searched: trimmed and folded; nil when there's nothing to find.
    static func normalizedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only marks the search ignores (a lone accent, a soft hyphen) would
        // match everywhere with nothing to show.
        let ignorable: Set<Unicode.GeneralCategory> = [.nonspacingMark, .enclosingMark, .format]
        let findable = trimmed.unicodeScalars.contains { !ignorable.contains($0.properties.generalCategory) }
        return findable ? fold(trimmed) : nil
    }

    /// Every paragraph holding `query`, in reading order.
    static func search(_ query: String, in chapters: [Chapter], limit: Int = WorkFind.limit) -> Result {
        guard let needle = normalizedQuery(query) else { return Result() }
        var result = Result()
        for chapter in chapters.sorted(by: { $0.index < $1.index }) {
            // A newer query superseded this one.
            if Task.isCancelled { return result }
            for (index, paragraph) in chapter.paragraphs.enumerated() where !paragraph.isEmpty {
                let folded = fold(paragraph)
                guard let first = folded.range(of: needle, options: options), !first.isEmpty else { continue }
                var count = 1
                var searchFrom = first.upperBound
                while searchFrom < folded.endIndex,
                      let next = folded.range(of: needle, options: options, range: searchFrom..<folded.endIndex),
                      next.upperBound > searchFrom {
                    count += 1
                    searchFrom = next.upperBound
                }
                result.total += count
                guard result.matches.count < limit else {
                    result.truncated = true
                    continue
                }
                let start = folded.distance(from: folded.startIndex, to: first.lowerBound)
                let length = folded.distance(from: first.lowerBound, to: first.upperBound)
                let (snippet, highlight) = snippet(of: paragraph, matchStart: start, matchLength: length)
                result.matches.append(Match(chapter: chapter.index, paragraph: index,
                                            snippet: snippet, highlight: highlight, count: count, offset: start))
            }
        }
        return result
    }

    /// `paragraph` cut to about `snippetLength` characters around the match,
    /// starting at a word, with "…" where text was left out.
    static func snippet(of paragraph: String, matchStart: Int, matchLength: Int) -> (String, Range<Int>) {
        let chars = Array(paragraph)
        var from = max(0, matchStart - leadingContext)
        // Start at a word, not mid-way through one.
        if from > 0 {
            var i = from
            while i < matchStart, !chars[i - 1].isWhitespace { i += 1 }
            from = i
        }
        let to = min(chars.count, max(matchStart + matchLength, from + snippetLength))
        let prefix = from > 0 ? "…" : ""
        let suffix = to < chars.count ? "…" : ""
        let body = String(chars[from..<to]).trimmingCharacters(in: .whitespaces)
        let leadingTrimmed = String(chars[from..<to]).prefix { $0.isWhitespace }.count
        let start = prefix.count + (matchStart - from) - leadingTrimmed
        return (prefix + body + suffix, start..<(start + matchLength))
    }

    /// A chapter's name as the reader's menus show it.
    static func chapterLabel(index: Int, title: String) -> String {
        title.isEmpty ? "Chapter \(index)" : "Chapter \(index): \(title)"
    }
}

/// The Find sheet: a search field and the paragraphs that match, by chapter.
/// Choosing one hands its place to the reader, which shows it.
struct WorkFindView: View {
    let chapters: [AO3ChapterPayload]
    let includeImages: Bool
    /// Kept by the reader, so Find opens again on the last search.
    @Binding var query: String
    let onSelect: (WorkFind.Match) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var result = WorkFind.Result()
    @State private var searchedQuery = ""
    @State private var searching = false
    @State private var fieldPresented = true
    /// The chapters' text, made once per sheet on the first search.
    @State private var searchable: [WorkFind.Chapter]?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Find in This Work")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, isPresented: $fieldPresented,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Words in this work")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .task(id: query) { await runSearch() }
    }

    @ViewBuilder
    private var content: some View {
        if WorkFind.normalizedQuery(query) == nil {
            ContentUnavailableView("Find in This Work",
                                   systemImage: "text.magnifyingglass",
                                   description: Text("Search every loaded chapter's text. Nothing leaves your device."))
        } else if result.matches.isEmpty || searchedQuery != query {
            // The last query's rows go while a new search runs, so a tap
            // can't pick one of them.
            if searching || searchedQuery != query {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            List {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .accessibilityAddTraits(.isHeader)
                ForEach(groupedMatches, id: \.chapter) { group in
                    Section(chapterLabel(group.chapter)) {
                        ForEach(group.matches) { match in
                            row(match)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var summary: String {
        let paragraphs = result.matches.count
        let base = result.total == 1 ? "1 match" : "\(result.total) matches"
        if result.truncated { return "\(base), showing the first \(paragraphs) paragraphs" }
        return paragraphs == 1 || paragraphs == result.total
            ? base : "\(base) in \(paragraphs) paragraphs"
    }

    private var groupedMatches: [(chapter: Int, matches: [WorkFind.Match])] {
        var groups: [(chapter: Int, matches: [WorkFind.Match])] = []
        for match in result.matches {
            if groups.last?.chapter == match.chapter {
                groups[groups.count - 1].matches.append(match)
            } else {
                groups.append((match.chapter, [match]))
            }
        }
        return groups
    }

    private func chapterLabel(_ index: Int) -> String {
        let title = chapters.first { $0.index == index }?.title ?? ""
        return WorkFind.chapterLabel(index: index, title: title)
    }

    private func row(_ match: WorkFind.Match) -> some View {
        Button {
            onSelect(match)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(highlighted(match))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if match.count > 1 {
                    Text("\(match.count) times in this paragraph")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this place in the reader.")
    }

    private func highlighted(_ match: WorkFind.Match) -> AttributedString {
        var text = AttributedString(match.snippet)
        let chars = text.characters
        guard match.highlight.lowerBound >= 0, match.highlight.upperBound <= chars.count else { return text }
        let lower = chars.index(chars.startIndex, offsetBy: match.highlight.lowerBound)
        let upper = chars.index(chars.startIndex, offsetBy: match.highlight.upperBound)
        text[lower..<upper].font = .callout.bold()
        text[lower..<upper].backgroundColor = Color.accentColor.opacity(0.2)
        return text
    }

    /// Searches once typing pauses, off the main actor; a newer query cancels it.
    private func runSearch() async {
        let current = query
        guard WorkFind.normalizedQuery(current) != nil else {
            result = WorkFind.Result()
            searchedQuery = current
            searching = false
            return
        }
        searching = true
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let payloads = chapters
        let include = includeImages
        let cached = searchable
        // Detached, so the main actor stays free; cancelled with this task
        // when the query changes (search checks between chapters).
        let work = Task.detached(priority: .userInitiated) { () -> ([WorkFind.Chapter], WorkFind.Result) in
            let text = cached ?? WorkFind.chapters(from: payloads, includeImages: include)
            return (text, WorkFind.search(current, in: text))
        }
        let (text, found) = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if searchable == nil { searchable = text }
        guard !Task.isCancelled else { return }
        result = found
        searchedQuery = current
        searching = false
        UIAccessibility.post(notification: .announcement,
                             argument: found.total == 0 ? "No matches" : summary)
    }
}

/// The reader's Find, for the Reader menu's ⌘F (Mac, and iPad with a
/// keyboard): a focused scene value, so it acts on the reader in front.
struct FindInWorkAction {
    let perform: @MainActor () -> Void

    @MainActor
    func callAsFunction() {
        perform()
    }
}

private struct FindInWorkKey: FocusedValueKey {
    typealias Value = FindInWorkAction
}

extension FocusedValues {
    var findInWork: FindInWorkAction? {
        get { self[FindInWorkKey.self] }
        set { self[FindInWorkKey.self] = newValue }
    }
}

/// The Reader menu's Find item: enabled only while a reader is in front.
struct FindInWorkMenuButton: View {
    @FocusedValue(\.findInWork) private var findInWork

    var body: some View {
        Button("Find in This Work…") { findInWork?() }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(findInWork == nil)
    }
}

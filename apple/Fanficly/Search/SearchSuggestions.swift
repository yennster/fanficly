import Foundation

/// Something the search box can offer while you type. Nothing here is applied
/// unless tapped — that opt-in is what keeps search predictable.
enum SearchSuggestion: Hashable, Sendable {
    /// An exact AO3 tag (fandom, character, ship or trope).
    case tag(String)
    case rating(AO3SearchFilters.Rating)
    case completion(AO3SearchFilters.TriState)
    case singleChapter
    case crossover(AO3SearchFilters.TriState)
    case category(AO3SearchFilters.Category)
    case language(String)
    case wordCount(String)

    var label: String {
        switch self {
        case .tag(let name): name
        case .rating(let rating): "Rated \(rating.displayName)"
        case .completion(let state): state == .no ? "Works in progress" : "Complete works"
        case .singleChapter: "One-shots"
        case .crossover(let state): state == .no ? "No crossovers" : "Crossovers"
        case .category(let category): category.displayName
        case .language(let code): "In \(SearchSyntax.languageNames[code] ?? code)"
        case .wordCount(let range): AO3SearchFilters.wordCountLabel(range)
        }
    }

    var systemImage: String {
        switch self {
        case .tag(let name): name.contains("/") ? "heart" : "tag"
        case .rating: "exclamationmark.shield"
        case .completion: "checkmark.circle"
        case .singleChapter: "1.circle"
        case .crossover: "arrow.triangle.merge"
        case .category: "person.2"
        case .language: "globe"
        case .wordCount: "text.alignleft"
        }
    }

    func apply(to filters: inout AO3SearchFilters) {
        switch self {
        case .tag(let name):
            if !filters.otherTagNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                filters.otherTagNames.append(name)
            }
        case .rating(let rating): filters.ratings.insert(rating)
        case .completion(let state): filters.complete = state
        case .singleChapter: filters.singleChapter = true
        case .crossover(let state): filters.crossover = state
        case .category(let category): filters.categories.insert(category)
        case .language(let code): filters.languageId = code
        case .wordCount(let range): filters.wordCount = range
        }
    }
}

/// A suggestion plus how many trailing words of the search text it replaces.
struct SuggestionCandidate: Hashable, Identifiable, Sendable {
    let suggestion: SearchSuggestion
    let consumedWords: Int
    var id: String { "\(suggestion.label)|\(consumedWords)" }
}

enum SearchSuggestions {
    /// The words being typed at the end of the search text — what suggestions
    /// are for. Up to three plain words; stops at `key:value` tokens, quoted
    /// phrases and `-exclusions`, and is empty inside an unclosed quote.
    static func activeWords(in text: String, limit: Int = 3) -> [String] {
        let normalized = SearchSyntax.normalizeQuotes(text)
        if normalized.filter({ $0 == "\"" }).count % 2 == 1 { return [] }
        var words: [String] = []
        for word in normalized.split(whereSeparator: \.isWhitespace).reversed() {
            let w = String(word)
            if w.contains(":") || w.hasPrefix("-") || w.contains("\"") { break }
            words.insert(w, at: 0)
            if words.count == limit { break }
        }
        return words
    }

    /// Instant, offline suggestions: fandom abbreviations AO3's autocomplete
    /// wouldn't match ("hp", "mcu"), and filters people otherwise type as
    /// words ("teen" → Rated Teen And Up, "comp" → Complete works). Longer
    /// phrases win.
    static func local(for words: [String]) -> [SuggestionCandidate] {
        var out: [SuggestionCandidate] = []
        var seen = Set<SearchSuggestion>()
        func add(_ s: SearchSuggestion, _ n: Int) {
            if seen.insert(s).inserted { out.append(SuggestionCandidate(suggestion: s, consumedWords: n)) }
        }
        guard !words.isEmpty else { return [] }
        for n in stride(from: words.count, through: 1, by: -1) {
            let phrase = words.suffix(n).joined(separator: " ").lowercased()
            if let fandom = KnownTags.fandomAliases[phrase] { add(.tag(fandom), n) }
            if let wc = wordCount(in: phrase) { add(.wordCount(wc), n) }
            guard phrase.count >= 3 else { continue }
            for (name, rating) in ratingWords where name.hasPrefix(phrase) { add(.rating(rating), n) }
            if "complete".hasPrefix(phrase) || phrase == "completed" { add(.completion(.yes), n) }
            if phrase == "wip" || "work in progress".hasPrefix(phrase) && phrase.count >= 6 { add(.completion(.no), n) }
            if ["oneshot", "one shot", "one-shot"].contains(where: { $0.hasPrefix(phrase) }) { add(.singleChapter, n) }
            if phrase.count >= 5 && "crossover".hasPrefix(phrase) { add(.crossover(.yes), n) }
            if phrase.hasPrefix("no cross") { add(.crossover(.no), n) }
            if let category = categoryWords[phrase] { add(.category(category), n) }
            let language = phrase.hasPrefix("in ") ? String(phrase.dropFirst(3)) : phrase
            if language.count >= 3 {
                for (code, name) in SearchSyntax.languageNames.sorted(by: { $0.value < $1.value })
                where name.lowercased().hasPrefix(language) {
                    add(.language(code), n)
                }
            }
        }
        // Short category forms ("m/m", "f/f") are only 3 characters.
        if let last = words.last?.lowercased(), let category = categoryWords[last] {
            add(.category(category), 1)
        }
        return out
    }

    private static let ratingWords: [(String, AO3SearchFilters.Rating)] = [
        ("general", .general), ("teen", .teen), ("mature", .mature),
        ("explicit", .explicit), ("not rated", .notRated),
    ]

    private static let categoryWords: [String: AO3SearchFilters.Category] = [
        "m/m": .mm, "f/f": .ff, "f/m": .fm, "femslash": .ff, "slash": .mm, "gen": .gen, "multi": .multi,
    ]

    /// Only when the whole phrase is a word count, so tapping it can't also
    /// swallow the keywords before it ("drarry under 10k").
    private static func wordCount(in phrase: String) -> String? {
        let filters = SearchSyntax.parse(phrase)
        guard !filters.wordCount.isEmpty, filters.query.isEmpty else { return nil }
        return filters.wordCount
    }

    /// Orders AO3's autocomplete results (which aren't ranked for this —
    /// "teen wolf" returns an episode tag before "Teen Wolf (TV)") so the tag
    /// you're most likely typing comes first.
    static func rankTags(_ names: [String], for phrase: String, limit: Int = 6) -> [String] {
        let p = phrase.lowercased()
        let pWords = p.split(separator: " ").map(String.init)
        func score(_ name: String) -> Int {
            let n = name.lowercased()
            var s: Int
            if n == p { s = 100 }
            else if n.hasPrefix(p) { s = 80 }
            else if pWords.allSatisfy({ w in n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(w) } }) { s = 60 }
            else if n.contains(p) { s = 40 }
            else { s = 10 }
            if n.hasPrefix("episode:") { s -= 30 }
            if name.count > 60 { s -= 10 }
            return s
        }
        var seen = Set<String>()
        return names
            .filter { seen.insert($0.lowercased()).inserted }
            .enumerated()
            .sorted { a, b in
                let (sa, sb) = (score(a.element), score(b.element))
                if sa != sb { return sa > sb }
                if a.element.count != b.element.count { return a.element.count < b.element.count }
                return a.offset < b.offset
            }
            .prefix(limit)
            .map(\.element)
    }

    /// Applies a tapped suggestion: the filter goes into `filters`, and the
    /// words it came from leave the search text.
    static func apply(_ candidate: SuggestionCandidate, text: inout String, filters: inout AO3SearchFilters) {
        candidate.suggestion.apply(to: &filters)
        text = removingTrailingWords(candidate.consumedWords, from: text)
    }

    static func removingTrailingWords(_ count: Int, from text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        words.removeLast(min(count, words.count))
        return words.isEmpty ? "" : words.joined(separator: " ") + " "
    }
}

/// Remembers autocomplete answers for the session so retyping a phrase (or
/// backspacing) never costs another throttled AO3 request.
actor TagSuggestionCache {
    static let shared = TagSuggestionCache()
    private var store: [String: [String]] = [:]
    private var order: [String] = []

    func value(for phrase: String) -> [String]? { store[phrase.lowercased()] }

    func set(_ names: [String], for phrase: String) {
        let key = phrase.lowercased()
        if store[key] == nil { order.append(key) }
        store[key] = names
        if order.count > 200 { store[order.removeFirst()] = nil }
    }
}

/// Recent searches, newest first, stored as search-box text one per line (the
/// box is single-line, so a prompt never contains a newline). On-device only.
enum RecentSearches {
    static let storageKey = "search.recent"
    static let limit = 10

    static func list(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    static func adding(_ prompt: String, to raw: String) -> String {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return raw }
        var items = list(raw).filter { $0.caseInsensitiveCompare(p) != .orderedSame }
        items.insert(p, at: 0)
        return items.prefix(limit).joined(separator: "\n")
    }

    static func removing(_ prompt: String, from raw: String) -> String {
        list(raw).filter { $0 != prompt }.joined(separator: "\n")
    }
}

import Foundation

public struct AO3SearchFilters: Equatable, Sendable, Codable {
    public var query: String = ""
    public var title: String = ""
    public var creators: String = ""
    public var revisedAt: String = ""
    public var complete: TriState = .any
    public var crossover: TriState = .any
    public var singleChapter: Bool = false
    public var wordCount: String = ""
    public var languageId: String = ""
    public var fandomNames: [String] = []
    public var characterNames: [String] = []
    public var relationshipNames: [String] = []
    public var freeformNames: [String] = []
    /// Canonical tags of any kind (fandom, character, ship or trope), as
    /// picked from search suggestions → `work_search[other_tag_names]`, which
    /// AO3 matches against every tag type.
    public var otherTagNames: [String] = []
    /// Canonical tags to exclude → `work_search[excluded_tag_names]`.
    public var excludedTagNames: [String] = []
    public var excludedFreeforms: [String] = []
    public var ratings: Set<Rating> = []
    public var warnings: Set<ArchiveWarning> = []
    public var categories: Set<Category> = []
    public var hits: String = ""
    public var kudosCount: String = ""
    public var commentsCount: String = ""
    public var bookmarksCount: String = ""
    public var sortColumn: SortColumn = .bestMatch
    public var sortDirection: SortDirection = .desc

    public init() {}

    public enum TriState: String, Equatable, Sendable, Codable {
        case any
        case yes
        case no
    }

    public enum Rating: String, CaseIterable, Sendable, Codable {
        case general = "10"
        case teen = "11"
        case mature = "12"
        case explicit = "13"
        case notRated = "9"

        public var displayName: String {
            switch self {
            case .general: "General Audiences"
            case .teen: "Teen And Up Audiences"
            case .mature: "Mature"
            case .explicit: "Explicit"
            case .notRated: "Not Rated"
            }
        }
    }

    public enum ArchiveWarning: String, CaseIterable, Sendable, Codable {
        case chooseNotToUse = "14"
        case noWarningsApply = "16"
        case graphicViolence = "17"
        case majorCharacterDeath = "18"
        case rapeNonCon = "19"
        case underage = "20"

        public var displayName: String {
            switch self {
            case .chooseNotToUse: "Creator Chose Not To Use Archive Warnings"
            case .noWarningsApply: "No Archive Warnings Apply"
            case .graphicViolence: "Graphic Depictions Of Violence"
            case .majorCharacterDeath: "Major Character Death"
            case .rapeNonCon: "Rape/Non-Con"
            case .underage: "Underage"
            }
        }
    }

    public enum Category: String, CaseIterable, Sendable, Codable {
        case ff = "116"
        case fm = "22"
        case gen = "21"
        case mm = "23"
        case multi = "2246"
        case other = "24"

        public var displayName: String {
            switch self {
            case .ff: "F/F"
            case .fm: "F/M"
            case .gen: "Gen"
            case .mm: "M/M"
            case .multi: "Multi"
            case .other: "Other"
            }
        }
    }

    public enum SortColumn: String, CaseIterable, Sendable, Hashable, Codable {
        case bestMatch = "_score"
        case author = "authors_to_sort_on"
        case title = "title_to_sort_on"
        case createdAt = "created_at"
        case revisedAt = "revised_at"
        case wordCount = "word_count"
        case hits
        case kudosCount = "kudos_count"
        case commentsCount = "comments_count"
        case bookmarksCount = "bookmarks_count"

        public var displayName: String {
            switch self {
            case .bestMatch:      "Best Match"
            case .author:         "Author"
            case .title:          "Title"
            case .createdAt:      "Date Posted"
            case .revisedAt:      "Date Updated"
            case .wordCount:      "Word Count"
            case .hits:           "Hits"
            case .kudosCount:     "Kudos"
            case .commentsCount:  "Comments"
            case .bookmarksCount: "Bookmarks"
            }
        }
    }

    public enum SortDirection: String, CaseIterable, Sendable, Hashable, Codable {
        case asc, desc
        public var displayName: String { self == .asc ? "Ascending" : "Descending" }
        public var symbol: String { self == .asc ? "arrow.up" : "arrow.down" }
    }

    public var isEmpty: Bool {
        query.isEmpty &&
        title.isEmpty &&
        creators.isEmpty &&
        revisedAt.isEmpty &&
        complete == .any &&
        crossover == .any &&
        singleChapter == false &&
        wordCount.isEmpty &&
        languageId.isEmpty &&
        fandomNames.isEmpty &&
        characterNames.isEmpty &&
        relationshipNames.isEmpty &&
        freeformNames.isEmpty &&
        otherTagNames.isEmpty &&
        excludedTagNames.isEmpty &&
        excludedFreeforms.isEmpty &&
        ratings.isEmpty &&
        warnings.isEmpty &&
        categories.isEmpty &&
        hits.isEmpty &&
        kudosCount.isEmpty &&
        commentsCount.isEmpty &&
        bookmarksCount.isEmpty
    }
}

extension AO3SearchFilters {
    /// The filters as search-box text (explicit `key:value` tokens after the
    /// keywords) — what saved searches, recents and deep links store.
    /// `SearchSyntax.parse` reads it back exactly.
    public func promptText() -> String {
        SearchSyntax.render(self)
    }

    static func wordCountPhrase(_ wc: String) -> String {
        if wc.hasPrefix(">") { return "over \(wc.dropFirst())" }
        if wc.hasPrefix("<") { return "under \(wc.dropFirst())" }
        if wc.contains("-") {
            let p = wc.split(separator: "-")
            if p.count == 2 { return "between \(p[0]) and \(p[1])" }
        }
        return "\(wc) words"
    }

    /// A human-readable default name for a saved filter, built from the
    /// selected tags and options. Fandom names are intentionally excluded —
    /// saved filters are fandom-agnostic (see `savedJSON()`) — and the result
    /// is capped to the few most identifying parts so it stays a short title.
    public func suggestedName() -> String {
        var parts: [String] = []
        parts += relationshipNames
        parts += characterNames
        parts += freeformNames
        parts += ratings.sorted { $0.rawValue < $1.rawValue }.map(\.displayName)
        parts += categories.sorted { $0.rawValue < $1.rawValue }.map(\.displayName)
        switch complete {
        case .yes: parts.append("Complete")
        case .no:  parts.append("WIP")
        case .any: break
        }
        if singleChapter { parts.append("Oneshot") }
        if crossover == .yes { parts.append("Crossover") }
        if !wordCount.isEmpty { parts.append(Self.wordCountPhrase(wordCount)) }
        return parts.prefix(4).joined(separator: " · ")
    }

    /// JSON for persisting a saved filter (fandom names excluded so the
    /// config can be applied to any fandom).
    public func savedJSON() -> String {
        var copy = self
        copy.fandomNames = []
        guard let data = try? JSONEncoder().encode(copy) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func from(savedJSON json: String) -> AO3SearchFilters? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AO3SearchFilters.self, from: data)
    }

    public func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        let composedQuery = composedQueryString()
        if !composedQuery.isEmpty {
            items.append(URLQueryItem(name: "work_search[query]", value: composedQuery))
        }
        if !title.isEmpty {
            items.append(URLQueryItem(name: "work_search[title]", value: title))
        }
        if !creators.isEmpty {
            items.append(URLQueryItem(name: "work_search[creators]", value: creators))
        }
        if !revisedAt.isEmpty {
            items.append(URLQueryItem(name: "work_search[revised_at]", value: revisedAt))
        }
        switch complete {
        case .yes: items.append(URLQueryItem(name: "work_search[complete]", value: "true"))
        case .no:  items.append(URLQueryItem(name: "work_search[complete]", value: "false"))
        case .any: break
        }
        switch crossover {
        case .yes: items.append(URLQueryItem(name: "work_search[crossover]", value: "T"))
        case .no:  items.append(URLQueryItem(name: "work_search[crossover]", value: "F"))
        case .any: break
        }
        if singleChapter {
            items.append(URLQueryItem(name: "work_search[single_chapter]", value: "1"))
        }
        if !wordCount.isEmpty {
            items.append(URLQueryItem(name: "work_search[word_count]", value: wordCount))
        }
        if !languageId.isEmpty {
            items.append(URLQueryItem(name: "work_search[language_id]", value: languageId))
        }
        if !fandomNames.isEmpty {
            items.append(URLQueryItem(name: "work_search[fandom_names]", value: fandomNames.joined(separator: ", ")))
        }
        if !characterNames.isEmpty {
            items.append(URLQueryItem(name: "work_search[character_names]", value: characterNames.joined(separator: ", ")))
        }
        if !relationshipNames.isEmpty {
            items.append(URLQueryItem(name: "work_search[relationship_names]", value: relationshipNames.joined(separator: ", ")))
        }
        if !freeformNames.isEmpty {
            items.append(URLQueryItem(name: "work_search[freeform_names]", value: freeformNames.joined(separator: ", ")))
        }
        if !otherTagNames.isEmpty {
            items.append(URLQueryItem(name: "work_search[other_tag_names]", value: otherTagNames.joined(separator: ", ")))
        }
        if !excludedTagNames.isEmpty {
            items.append(URLQueryItem(name: "work_search[excluded_tag_names]", value: excludedTagNames.joined(separator: ", ")))
        }
        // A single rating uses AO3's dedicated form field; 2+ ratings are
        // OR-ed via the query field in composedQueryString() above, because
        // the array form AND-matches and returns nothing.
        if ratings.count == 1, let only = ratings.first {
            items.append(URLQueryItem(name: "work_search[rating_ids]", value: only.rawValue))
        }
        for warning in warnings.sorted(by: { $0.rawValue < $1.rawValue }) {
            items.append(URLQueryItem(name: "work_search[archive_warning_ids][]", value: warning.rawValue))
        }
        for category in categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            items.append(URLQueryItem(name: "work_search[category_ids][]", value: category.rawValue))
        }
        if !hits.isEmpty {
            items.append(URLQueryItem(name: "work_search[hits]", value: hits))
        }
        if !kudosCount.isEmpty {
            items.append(URLQueryItem(name: "work_search[kudos_count]", value: kudosCount))
        }
        if !commentsCount.isEmpty {
            items.append(URLQueryItem(name: "work_search[comments_count]", value: commentsCount))
        }
        if !bookmarksCount.isEmpty {
            items.append(URLQueryItem(name: "work_search[bookmarks_count]", value: bookmarksCount))
        }
        items.append(URLQueryItem(name: "work_search[sort_column]", value: sortColumn.rawValue))
        items.append(URLQueryItem(name: "work_search[sort_direction]", value: sortDirection.rawValue))
        return items
    }

    func composedQueryString() -> String {
        var parts: [String] = []
        if !query.isEmpty { parts.append(query) }
        for excluded in excludedFreeforms {
            let quoted = excluded.contains(" ") ? "\"\(excluded)\"" : excluded
            parts.append("NOT \(quoted)")
        }
        // AO3's Rating field is a single-select, so a rating_ids[] array is
        // AND-ed and matches nothing (every work has exactly one rating).
        // To OR multiple ratings we fold them into the query field instead —
        // `(rating_ids:12 OR rating_ids:13)` — which AO3's search honors.
        // The single-rating case still goes through the dedicated form field
        // (see queryItems()).
        if ratings.count > 1 {
            let clause = ratings
                .sorted { $0.rawValue < $1.rawValue }
                .map { "rating_ids:\($0.rawValue)" }
                .joined(separator: " OR ")
            parts.append("(\(clause))")
        }
        return parts.joined(separator: " ")
    }
}

extension AO3SearchFilters {
    /// Tolerant decoding: any missing or unreadable field keeps its default,
    /// so filters saved before a field existed (e.g. `otherTagNames`) still
    /// load instead of failing the whole decode and losing the saved filter.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        query = value(.query, query)
        title = value(.title, title)
        creators = value(.creators, creators)
        revisedAt = value(.revisedAt, revisedAt)
        complete = value(.complete, complete)
        crossover = value(.crossover, crossover)
        singleChapter = value(.singleChapter, singleChapter)
        wordCount = value(.wordCount, wordCount)
        languageId = value(.languageId, languageId)
        fandomNames = value(.fandomNames, fandomNames)
        characterNames = value(.characterNames, characterNames)
        relationshipNames = value(.relationshipNames, relationshipNames)
        freeformNames = value(.freeformNames, freeformNames)
        otherTagNames = value(.otherTagNames, otherTagNames)
        excludedTagNames = value(.excludedTagNames, excludedTagNames)
        excludedFreeforms = value(.excludedFreeforms, excludedFreeforms)
        ratings = value(.ratings, ratings)
        warnings = value(.warnings, warnings)
        categories = value(.categories, categories)
        hits = value(.hits, hits)
        kudosCount = value(.kudosCount, kudosCount)
        commentsCount = value(.commentsCount, commentsCount)
        bookmarksCount = value(.bookmarksCount, bookmarksCount)
        sortColumn = value(.sortColumn, sortColumn)
        sortDirection = value(.sortDirection, sortDirection)
    }

    /// Folds `other`'s filters into these (lists and sets union, set scalars
    /// win). The search box uses this to move tokens typed as text into the
    /// active filter chips; `other.query` is ignored.
    func merging(_ other: AO3SearchFilters) -> AO3SearchFilters {
        var m = self
        func union(_ a: [String], _ b: [String]) -> [String] {
            b.reduce(into: a) { list, item in
                if !list.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) { list.append(item) }
            }
        }
        if !other.title.isEmpty { m.title = other.title }
        if !other.creators.isEmpty { m.creators = other.creators }
        if !other.revisedAt.isEmpty { m.revisedAt = other.revisedAt }
        if other.complete != .any { m.complete = other.complete }
        if other.crossover != .any { m.crossover = other.crossover }
        if other.singleChapter { m.singleChapter = true }
        if !other.wordCount.isEmpty { m.wordCount = other.wordCount }
        if !other.languageId.isEmpty { m.languageId = other.languageId }
        m.fandomNames = union(m.fandomNames, other.fandomNames)
        m.characterNames = union(m.characterNames, other.characterNames)
        m.relationshipNames = union(m.relationshipNames, other.relationshipNames)
        m.freeformNames = union(m.freeformNames, other.freeformNames)
        m.otherTagNames = union(m.otherTagNames, other.otherTagNames)
        m.excludedTagNames = union(m.excludedTagNames, other.excludedTagNames)
        m.excludedFreeforms = union(m.excludedFreeforms, other.excludedFreeforms)
        m.ratings.formUnion(other.ratings)
        m.warnings.formUnion(other.warnings)
        m.categories.formUnion(other.categories)
        if !other.hits.isEmpty { m.hits = other.hits }
        if !other.kudosCount.isEmpty { m.kudosCount = other.kudosCount }
        if !other.commentsCount.isEmpty { m.commentsCount = other.commentsCount }
        if !other.bookmarksCount.isEmpty { m.bookmarksCount = other.bookmarksCount }
        return m
    }
}

extension AO3SearchFilters {
    /// "Under 10,000 words" for `<10000`, "1,000–5,000 words" for a range.
    static func wordCountLabel(_ range: String) -> String {
        func n(_ s: Substring) -> String {
            Int(s).map { $0.formatted(.number) } ?? String(s)
        }
        if range.hasPrefix("<") { return "Under \(n(range.dropFirst())) words" }
        if range.hasPrefix(">") { return "Over \(n(range.dropFirst())) words" }
        let parts = range.split(separator: "-")
        if parts.count == 2 { return "\(n(parts[0]))–\(n(parts[1])) words" }
        return "\(n(Substring(range))) words"
    }
}

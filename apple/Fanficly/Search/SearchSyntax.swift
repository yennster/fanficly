import Foundation

/// Turns the search box text into `AO3SearchFilters`, and filters back into
/// text (`render`) for saved searches, recents and deep links.
///
/// The rule that matters: **ordinary words stay keywords.** Whatever isn't
/// recognized goes to AO3's own full-text search (`work_search[query]`), which
/// matches tags, titles and summaries with its own ranking. Only two things
/// become filters:
///
/// 1. Explicit `key:value` tokens (`tag:"Slow Burn"`, `rating:explicit`,
///    `title:…`, `by:…`, …). Nobody types those by accident, and `render`
///    emits them, so saved searches round-trip exactly.
/// 2. A short list of phrases that only ever mean a filter: "complete",
///    "wip", "one shot", "explicit", "nsfw", "m/m", "under 10k", "in
///    spanish", "no crossovers", "no mcd". These have to be filters because
///    AO3 requires every keyword to match: "complete" left as a word would
///    hide every story that doesn't literally contain it.
///
/// Fandoms, characters, ships and tropes are never guessed from words; the
/// suggestion row offers their exact AO3 tags instead (`SearchSuggestions`).
/// The old prompt parser turned "teen wolf" into a Teen rating plus the word
/// "wolf"; that class of bug is gone by construction.
enum SearchSyntax {
    // MARK: - Parse

    static func parse(_ text: String) -> AO3SearchFilters {
        var filters = AO3SearchFilters()
        var working = normalizeQuotes(text)
        extractKeyValues(from: &working, into: &filters)
        extractPhrases(from: &working, into: &filters)
        filters.query = collapseWhitespace(working)
        return filters
    }

    /// Straight quotes only, so `title:“Foo Bar”` from an iOS keyboard works.
    static func normalizeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static let keyValuePattern = try! NSRegularExpression(
        pattern: #"(?<![\w-])(-?[a-z]+):(?:"([^"]*)"|([^\s"]+))"#,
        options: [.caseInsensitive]
    )

    private static func extractKeyValues(from working: inout String, into filters: inout AO3SearchFilters) {
        let ns = working as NSString
        let matches = keyValuePattern.matches(in: working, range: NSRange(location: 0, length: ns.length))
        var consumed: [NSRange] = []
        for match in matches {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let value: String
            if match.range(at: 2).location != NSNotFound {
                value = ns.substring(with: match.range(at: 2))
            } else {
                value = ns.substring(with: match.range(at: 3))
            }
            if apply(key: key, value: value.trimmingCharacters(in: .whitespaces), to: &filters) {
                consumed.append(match.range)
            }
        }
        working = removing(consumed, from: working)
    }

    /// Applies one `key:value`; false leaves the token in the text (unknown
    /// keys like AO3's own `rating_ids:12` pass straight through to AO3).
    private static func apply(key: String, value: String, to f: inout AO3SearchFilters) -> Bool {
        guard !value.isEmpty else { return false }
        switch key {
        case "title": f.title = value
        case "by", "author", "creator", "creators": f.creators = value
        case "tag": appendUnique(value, to: &f.otherTagNames)
        case "-tag": appendUnique(value, to: &f.excludedTagNames)
        case "fandom": appendUnique(value, to: &f.fandomNames)
        case "ship", "relationship": appendUnique(value, to: &f.relationshipNames)
        case "character": appendUnique(value, to: &f.characterNames)
        case "freeform": appendUnique(value, to: &f.freeformNames)
        case "exclude": appendUnique(value, to: &f.excludedFreeforms)
        case "rating":
            guard let rating = rating(named: value) else { return false }
            f.ratings.insert(rating)
        case "warning":
            guard let warning = warning(named: value) else { return false }
            f.warnings.insert(warning)
        case "category":
            guard let category = category(named: value) else { return false }
            f.categories.insert(category)
        case "complete", "status":
            guard let state = completion(value) else { return false }
            f.complete = state
        case "crossover":
            guard let state = yesNo(value) else { return false }
            f.crossover = state
        case "oneshot":
            guard let state = yesNo(value) else { return false }
            f.singleChapter = state == .yes
        case "words":
            guard let range = numericRange(value) else { return false }
            f.wordCount = range
        case "lang", "language":
            guard let code = languageCode(value) else { return false }
            f.languageId = code
        case "kudos":
            guard let range = numericRange(value) else { return false }
            f.kudosCount = range
        case "hits":
            guard let range = numericRange(value) else { return false }
            f.hits = range
        case "comments":
            guard let range = numericRange(value) else { return false }
            f.commentsCount = range
        case "bookmarks":
            guard let range = numericRange(value) else { return false }
            f.bookmarksCount = range
        case "updated": f.revisedAt = value
        default: return false
        }
        return true
    }

    // MARK: Phrases that only ever mean a filter

    /// Immutable: a compiled regex and a capture-free closure.
    private struct Phrase: @unchecked Sendable {
        let regex: NSRegularExpression
        let apply: @Sendable (NSTextCheckingResult, NSString, inout AO3SearchFilters) -> Bool
    }

    private static func phrase(_ pattern: String,
                               _ apply: @escaping @Sendable (NSTextCheckingResult, NSString, inout AO3SearchFilters) -> Bool) -> Phrase {
        Phrase(regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), apply: apply)
    }

    /// Order matters: longer / negated forms run before the shorter ones they
    /// contain ("no crossovers" before "crossover").
    private static let phrases: [Phrase] = [
        phrase(#"\bno\s+crossovers?\b"#) { _, _, f in f.crossover = .no; return true },
        phrase(#"\bcrossovers?\b"#) { _, _, f in f.crossover = .yes; return true },
        phrase(#"\b(?:wips?|incomplete|works?\s+in\s+progress)\b"#) { _, _, f in f.complete = .no; return true },
        phrase(#"\bcomplete(?:d)?\b"#) { _, _, f in f.complete = .yes; return true },
        phrase(#"\bone[\s-]?shots?\b"#) { _, _, f in f.singleChapter = true; return true },
        phrase(#"\bnsfw\b"#) { _, _, f in f.ratings.formUnion([.mature, .explicit]); return true },
        phrase(#"\bsfw\b"#) { _, _, f in f.ratings.formUnion([.general, .teen]); return true },
        phrase(#"\brated\s+(general|teen|mature|explicit|g|t|m|e)\b"#) { m, ns, f in
            guard let r = rating(named: ns.substring(with: m.range(at: 1))) else { return false }
            f.ratings.insert(r); return true
        },
        phrase(#"\b([gtme])-rated\b"#) { m, ns, f in
            guard let r = rating(named: ns.substring(with: m.range(at: 1))) else { return false }
            f.ratings.insert(r); return true
        },
        phrase(#"\bteen\s+and\s+up(?:\s+audiences)?\b"#) { _, _, f in f.ratings.insert(.teen); return true },
        phrase(#"\bgeneral\s+audiences\b"#) { _, _, f in f.ratings.insert(.general); return true },
        phrase(#"\b(?:not\s+rated|unrated)\b"#) { _, _, f in f.ratings.insert(.notRated); return true },
        phrase(#"\bexplicit\b"#) { _, _, f in f.ratings.insert(.explicit); return true },
        phrase(#"(?<![\w/])(m/m|f/f|f/m)(?![\w/])"#) { m, ns, f in
            guard let c = category(named: ns.substring(with: m.range(at: 1))) else { return false }
            f.categories.insert(c); return true
        },
        phrase(#"\bfemslash\b"#) { _, _, f in f.categories.insert(.ff); return true },
        phrase(#"\bno\s+(?:archive\s+)?warnings(?:\s+apply)?\b"#) { _, _, f in
            f.warnings.insert(.noWarningsApply); return true
        },
        phrase(#"\bno\s+(?:mcd|major\s+character\s+death)\b"#) { _, _, f in
            appendUnique("Major Character Death", to: &f.excludedTagNames); return true
        },
        phrase(#"\bbetween\s+(\d+)\s*(k|,000)?\s*(?:words?\s+)?and\s+(\d+)\s*(k|,000)?\s*(words?)?\b"#) { m, ns, f in
            let hasUnit = [2, 4, 5].contains { m.range(at: $0).location != NSNotFound }
            guard hasUnit,
                  let lo = number(ns, m, digits: 1, unit: 2),
                  let hi = number(ns, m, digits: 3, unit: 4) else { return false }
            // "between 10 and 50k" means 10k–50k.
            let low = m.range(at: 2).location == NSNotFound && m.range(at: 4).location != NSNotFound ? lo * 1_000 : lo
            f.wordCount = "\(min(low, hi))-\(max(low, hi))"; return true
        },
        phrase(#"\b(under|less\s+than|fewer\s+than|below|over|more\s+than|above)\s+(\d+)\s*(k|,000)?\s*(words?)?(?!\w)"#) { m, ns, f in
            let hasUnit = m.range(at: 3).location != NSNotFound || m.range(at: 4).location != NSNotFound
            guard hasUnit, let n = number(ns, m, digits: 2, unit: 3) else { return false }
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            let isMax = word.hasPrefix("under") || word.hasPrefix("less") || word.hasPrefix("fewer") || word.hasPrefix("below")
            f.wordCount = isMax ? "<\(n)" : ">\(n)"; return true
        },
        phrase(#"\b(?:in\s+(english|spanish|french|german|russian|chinese|japanese|korean|portuguese|italian)|en\s+español|en\s+français|auf\s+deutsch)\b"#) { m, ns, f in
            let whole = ns.substring(with: m.range).lowercased()
            let name = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)).lowercased() : whole
            guard let code = languageCode(name) ?? languageCode(whole) else { return false }
            f.languageId = code; return true
        },
    ]

    private static func number(_ ns: NSString, _ m: NSTextCheckingResult, digits: Int, unit: Int) -> Int? {
        guard let n = Int(ns.substring(with: m.range(at: digits))) else { return nil }
        return m.range(at: unit).location != NSNotFound ? n * 1_000 : n
    }

    /// Runs the phrase list over the text outside quotes — a quoted
    /// `"complete"` is the user asking for the literal word.
    private static func extractPhrases(from working: inout String, into filters: inout AO3SearchFilters) {
        for phrase in phrases {
            let ns = working as NSString
            let quoted = quotedRanges(in: working)
            var consumed: [NSRange] = []
            for match in phrase.regex.matches(in: working, range: NSRange(location: 0, length: ns.length)) {
                if quoted.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
                if phrase.apply(match, ns, &filters) { consumed.append(match.range) }
            }
            working = removing(consumed, from: working)
        }
    }

    private static let quotedPattern = try! NSRegularExpression(pattern: #""[^"]*""#)

    private static func quotedRanges(in s: String) -> [NSRange] {
        quotedPattern.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
    }

    /// The sort to use when none was chosen: AO3's "best match" needs
    /// keywords to rank by — with only filters its order is arbitrary (a
    /// 100-word podfic topped a 1,200-work Teen Wolf/Slow Burn search) — so
    /// filter-only searches show the most-kudosed works first.
    static func automaticSort(hasKeywords: Bool) -> AO3SearchFilters.SortColumn {
        hasKeywords ? .bestMatch : .kudosCount
    }

    // MARK: - Render

    /// The search as text: keywords first, then explicit tokens. Parsing the
    /// result gives back the same filters.
    static func render(_ f: AO3SearchFilters) -> String {
        var parts: [String] = []
        if !f.query.isEmpty { parts.append(f.query) }
        func token(_ key: String, _ value: String) { parts.append("\(key):\(quoteIfNeeded(value))") }
        if !f.title.isEmpty { token("title", f.title) }
        if !f.creators.isEmpty { token("by", f.creators) }
        f.fandomNames.forEach { token("fandom", $0) }
        f.relationshipNames.forEach { token("ship", $0) }
        f.characterNames.forEach { token("character", $0) }
        f.freeformNames.forEach { token("freeform", $0) }
        f.otherTagNames.forEach { token("tag", $0) }
        f.excludedTagNames.forEach { token("-tag", $0) }
        f.excludedFreeforms.forEach { token("exclude", $0) }
        f.ratings.sorted { $0.rawValue < $1.rawValue }.forEach { token("rating", ratingKey($0)) }
        f.warnings.sorted { $0.rawValue < $1.rawValue }.forEach { token("warning", warningKey($0)) }
        f.categories.sorted { $0.rawValue < $1.rawValue }.forEach { token("category", categoryKey($0)) }
        switch f.complete {
        case .yes: token("complete", "yes")
        case .no: token("complete", "no")
        case .any: break
        }
        switch f.crossover {
        case .yes: token("crossover", "yes")
        case .no: token("crossover", "no")
        case .any: break
        }
        if f.singleChapter { token("oneshot", "yes") }
        if !f.wordCount.isEmpty { token("words", f.wordCount) }
        if !f.languageId.isEmpty { token("lang", f.languageId) }
        if !f.kudosCount.isEmpty { token("kudos", f.kudosCount) }
        if !f.hits.isEmpty { token("hits", f.hits) }
        if !f.commentsCount.isEmpty { token("comments", f.commentsCount) }
        if !f.bookmarksCount.isEmpty { token("bookmarks", f.bookmarksCount) }
        if !f.revisedAt.isEmpty { token("updated", f.revisedAt) }
        return parts.joined(separator: " ")
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\"", with: "")
        return clean.contains(where: { $0.isWhitespace }) ? "\"\(clean)\"" : clean
    }

    // MARK: - Vocabulary

    static func rating(named raw: String) -> AO3SearchFilters.Rating? {
        switch raw.lowercased() {
        case "g", "general", "general audiences": .general
        case "t", "teen", "teen and up", "teen and up audiences": .teen
        case "m", "mature": .mature
        case "e", "explicit": .explicit
        case "nr", "not rated", "notrated", "unrated": .notRated
        default: nil
        }
    }

    static func ratingKey(_ r: AO3SearchFilters.Rating) -> String {
        switch r {
        case .general: "general"
        case .teen: "teen"
        case .mature: "mature"
        case .explicit: "explicit"
        case .notRated: "not rated"
        }
    }

    static func warning(named raw: String) -> AO3SearchFilters.ArchiveWarning? {
        let v = raw.lowercased()
        if let match = AO3SearchFilters.ArchiveWarning.allCases.first(where: { $0.displayName.lowercased() == v }) {
            return match
        }
        switch v {
        case "none", "no warnings", "no archive warnings": return .noWarningsApply
        case "cnow", "choose not to use", "chose not to use": return .chooseNotToUse
        case "violence", "graphic violence": return .graphicViolence
        case "mcd", "death", "character death": return .majorCharacterDeath
        case "noncon", "non-con", "rape": return .rapeNonCon
        case "underage": return .underage
        default: return nil
        }
    }

    static func warningKey(_ w: AO3SearchFilters.ArchiveWarning) -> String {
        switch w {
        case .noWarningsApply: "none"
        case .chooseNotToUse: "cnow"
        case .graphicViolence: "violence"
        case .majorCharacterDeath: "mcd"
        case .rapeNonCon: "noncon"
        case .underage: "underage"
        }
    }

    static func category(named raw: String) -> AO3SearchFilters.Category? {
        switch raw.lowercased() {
        case "f/f", "femslash": .ff
        case "f/m", "het": .fm
        case "gen": .gen
        case "m/m", "slash": .mm
        case "multi": .multi
        case "other": .other
        default: AO3SearchFilters.Category.allCases.first { $0.displayName.lowercased() == raw.lowercased() }
        }
    }

    static func categoryKey(_ c: AO3SearchFilters.Category) -> String {
        switch c {
        case .ff: "f/f"
        case .fm: "f/m"
        case .gen: "gen"
        case .mm: "m/m"
        case .multi: "multi"
        case .other: "other"
        }
    }

    private static func completion(_ raw: String) -> AO3SearchFilters.TriState? {
        switch raw.lowercased() {
        case "complete", "completed": .yes
        case "wip", "incomplete", "in progress": .no
        default: yesNo(raw)
        }
    }

    private static func yesNo(_ raw: String) -> AO3SearchFilters.TriState? {
        switch raw.lowercased() {
        case "yes", "y", "true", "1", "only": .yes
        case "no", "n", "false", "0", "none": .no
        default: nil
        }
    }

    /// AO3's numeric range syntax (`<5000`, `>100`, `1000-5000`, `5000`), with
    /// a `k` shorthand (`<10k`).
    static func numericRange(_ raw: String) -> String? {
        let compact = raw.lowercased().replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        let expanded = compact.replacingOccurrences(
            of: #"(\d+)k"#, with: "$1000", options: .regularExpression
        )
        guard expanded.range(of: #"^(?:[<>]\d+|\d+(?:-\d+)?)$"#, options: .regularExpression) != nil else { return nil }
        return expanded
    }

    static let languageNames: [String: String] = [
        "en": "English", "es": "Spanish", "fr": "French", "de": "German", "ru": "Russian",
        "zh": "Chinese", "ja": "Japanese", "ko": "Korean", "pt": "Portuguese", "it": "Italian",
    ]

    static func languageCode(_ raw: String) -> String? {
        let v = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let alias = KnownTags.languageAliases[v] { return alias }
        if languageNames[v] != nil { return v }
        if v.range(of: #"^[a-z]{2,3}(?:-[a-z]+)?$"#, options: .regularExpression) != nil { return v }
        return nil
    }

    // MARK: - Helpers

    private static func appendUnique(_ value: String, to list: inout [String]) {
        if !list.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            list.append(value)
        }
    }

    private static func removing(_ ranges: [NSRange], from s: String) -> String {
        guard !ranges.isEmpty else { return s }
        let mutable = NSMutableString(string: s)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: " ")
        }
        return mutable as String
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

import Foundation

/// One active filter as a removable chip. Search's chip row and Browse's
/// header both build theirs here, so every field a search or saved filter can
/// set is visible, removable, and worded the same in both (#157).
struct FilterChip: Identifiable {
    let id: String
    let label: String
    var kind: ChipView.Kind = .include
    let remove: (inout AO3SearchFilters) -> Void

    /// Every active filter in `f` as a chip (keywords stay in the box).
    /// `subject` is the tag a Browse screen is about (its fandom, ship or
    /// character): it's the screen's title, so it gets no chip.
    static func all(in f: AO3SearchFilters, subject: String? = nil) -> [FilterChip] {
        var chips: [FilterChip] = []
        func list(_ names: [String], _ key: String, prefix: String = "", kind: ChipView.Kind = .include,
                  _ path: WritableKeyPath<AO3SearchFilters, [String]>) {
            for name in names where name != subject {
                chips.append(FilterChip(id: "\(key)|\(name)", label: prefix + name, kind: kind) {
                    $0[keyPath: path].removeAll { $0 == name }
                })
            }
        }
        if !f.title.isEmpty {
            chips.append(FilterChip(id: "title", label: "Title: \(f.title)") { $0.title = "" })
        }
        if !f.creators.isEmpty {
            chips.append(FilterChip(id: "creators", label: "By \(f.creators)") { $0.creators = "" })
        }
        list(f.otherTagNames, "tag", \.otherTagNames)
        list(f.fandomNames, "fandom", \.fandomNames)
        list(f.relationshipNames, "ship", \.relationshipNames)
        list(f.characterNames, "character", \.characterNames)
        list(f.freeformNames, "freeform", \.freeformNames)
        list(f.excludedTagNames, "-tag", prefix: "Not ", kind: .exclude, \.excludedTagNames)
        list(f.excludedFreeforms, "exclude", prefix: "Not ", kind: .exclude, \.excludedFreeforms)
        for rating in f.ratings.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(FilterChip(id: "rating|\(rating.rawValue)", label: "Rated \(rating.displayName)") { $0.ratings.remove(rating) })
        }
        for warning in f.warnings.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(FilterChip(id: "warning|\(warning.rawValue)", label: warning.displayName) { $0.warnings.remove(warning) })
        }
        for category in f.categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(FilterChip(id: "category|\(category.rawValue)", label: category.displayName) { $0.categories.remove(category) })
        }
        if f.complete != .any {
            chips.append(FilterChip(id: "complete", label: f.complete == .yes ? "Complete works" : "Works in progress") { $0.complete = .any })
        }
        if f.crossover != .any {
            chips.append(FilterChip(id: "crossover", label: f.crossover == .yes ? "Crossovers" : "No crossovers") { $0.crossover = .any })
        }
        if f.singleChapter {
            chips.append(FilterChip(id: "oneshot", label: "One-shots") { $0.singleChapter = false })
        }
        if !f.wordCount.isEmpty {
            chips.append(FilterChip(id: "words", label: AO3SearchFilters.wordCountLabel(f.wordCount)) { $0.wordCount = "" })
        }
        if !f.languageId.isEmpty {
            chips.append(FilterChip(id: "lang", label: "In \(SearchSyntax.languageNames[f.languageId] ?? f.languageId)") { $0.languageId = "" })
        }
        if !f.kudosCount.isEmpty {
            chips.append(FilterChip(id: "kudos", label: "Kudos \(f.kudosCount)") { $0.kudosCount = "" })
        }
        if !f.hits.isEmpty {
            chips.append(FilterChip(id: "hits", label: "Hits \(f.hits)") { $0.hits = "" })
        }
        if !f.commentsCount.isEmpty {
            chips.append(FilterChip(id: "comments", label: "Comments \(f.commentsCount)") { $0.commentsCount = "" })
        }
        if !f.bookmarksCount.isEmpty {
            chips.append(FilterChip(id: "bookmarks", label: "Bookmarks \(f.bookmarksCount)") { $0.bookmarksCount = "" })
        }
        if !f.revisedAt.isEmpty {
            chips.append(FilterChip(id: "updated", label: "Updated \(f.revisedAt)") { $0.revisedAt = "" })
        }
        return chips
    }
}

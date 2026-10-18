import Foundation
import SwiftData

/// App-wide content-control keys and helpers backing the UGC safeguards
/// (App Store guideline 1.2). Centralized so Search, Browse, Settings and the
/// age gate all agree on the same `@AppStorage` keys.
enum ContentControl {
    /// User toggle: hide Mature/Explicit-rated works from results. Default on.
    static let filterMatureKey = "content.filterMatureExplicit"
    /// Set once the user confirms they are 17+. Gates the whole app.
    static let ageConfirmedKey = "content.ageConfirmed"
}

/// Filters a list of works for display: drops anything the user has hidden,
/// anything the blocklist matches, and (when enabled) anything rated Mature or
/// Explicit.
enum ContentFilter {
    static let matureRatings: Set<String> = ["Mature", "Explicit"]

    static func apply(
        _ works: [AO3WorkSummary], hiddenIds: Set<Int>, filterMature: Bool,
        blocklist: Blocklist = .empty
    ) -> [AO3WorkSummary] {
        works.filter { work in
            if hiddenIds.contains(work.id) { return false }
            if filterMature && matureRatings.contains(work.rating) { return false }
            if blocklist.blocks(work) { return false }
            return true
        }
    }
}

/// The user's blocked tags and authors (RM-006), folded for matching. Tags
/// match any of a work's tags (fandoms, relationships, characters, freeforms,
/// warnings, categories) by AO3 name, ignoring case and surrounding spaces;
/// authors match the byline login or display name the same way.
///
/// Lists only: the reader, the Library and the user's own AO3 subscriptions
/// and bookmarks never consult it, so a work opened on purpose always shows.
struct Blocklist: Sendable, Equatable {
    private(set) var tags: Set<String>
    private(set) var authors: Set<String>

    static let empty = Blocklist(tags: [String](), authors: [String]())

    init(tags: some Sequence<String>, authors: some Sequence<String>) {
        self.tags = Set(tags.map(Self.fold).filter { !$0.isEmpty })
        self.authors = Set(authors.map(Self.fold).filter { !$0.isEmpty })
    }

    init(_ terms: [BlockedTerm]) {
        self.init(
            tags: terms.filter { $0.kind == BlockedTermKind.tag.rawValue }.map(\.value),
            authors: terms.filter { $0.kind == BlockedTermKind.author.rawValue }.map(\.value)
        )
    }

    var isEmpty: Bool { tags.isEmpty && authors.isEmpty }

    static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func blocks(_ work: AO3WorkSummary) -> Bool {
        if isEmpty { return false }
        if !authors.isEmpty,
           authors.contains(Self.fold(work.authorUsername)) || authors.contains(Self.fold(work.author)) {
            return true
        }
        guard !tags.isEmpty else { return false }
        let workTags = [work.fandoms, work.relationships, work.characters,
                        work.freeforms, work.warnings, work.categories].joined()
        return workTags.contains { tags.contains(Self.fold($0)) }
    }

    /// The blocklist minus whatever a list was asked for by name: the tags
    /// and creators a search or browse filters on, or the author whose page
    /// is open. Asking for a blocked tag on purpose shows its works.
    func lifting(_ filters: AO3SearchFilters) -> Blocklist {
        let asked = filters.fandomNames + filters.relationshipNames + filters.characterNames
            + filters.freeformNames + filters.otherTagNames
        let creators = filters.creators.split(separator: ",").map(String.init)
        return lifting(tags: asked, authors: creators)
    }

    func lifting(tags asked: some Sequence<String>, authors askedAuthors: some Sequence<String>) -> Blocklist {
        var copy = self
        copy.tags.subtract(asked.map(Self.fold))
        copy.authors.subtract(askedAuthors.map(Self.fold))
        return copy
    }
}

/// Local blocklist storage: block and unblock tags and authors. Stored
/// on-device, and in the optional iCloud backup as a union.
enum BlocklistStore {
    @MainActor
    static func isBlocked(_ kind: BlockedTermKind, _ value: String, in context: ModelContext) -> Bool {
        let key = BlockedTerm.key(kind: kind.rawValue, value: value)
        let descriptor = FetchDescriptor<BlockedTerm>(predicate: #Predicate { $0.key == key })
        return ((try? context.fetch(descriptor))?.first) != nil
    }

    @MainActor
    static func block(_ kind: BlockedTermKind, _ value: String, into context: ModelContext) {
        guard !Blocklist.fold(value).isEmpty, !isBlocked(kind, value, in: context) else { return }
        context.insert(BlockedTerm(kind: kind, value: value))
        try? context.save()
    }

    @MainActor
    static func unblock(_ kind: BlockedTermKind, _ value: String, in context: ModelContext) {
        let key = BlockedTerm.key(kind: kind.rawValue, value: value)
        let descriptor = FetchDescriptor<BlockedTerm>(predicate: #Predicate { $0.key == key })
        for record in (try? context.fetch(descriptor)) ?? [] { context.delete(record) }
        try? context.save()
    }
}

/// Local "block" mechanism — the user can hide a work so it never shows in
/// results again. Stored on-device only.
enum HiddenWorkStore {
    static func ids(_ hidden: [HiddenWork]) -> Set<Int> { Set(hidden.map(\.ao3Id)) }

    @MainActor
    static func isHidden(ao3Id: Int, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<HiddenWork>(predicate: #Predicate { $0.ao3Id == ao3Id })
        return ((try? context.fetch(descriptor))?.first) != nil
    }

    @MainActor
    static func hide(ao3Id: Int, title: String, into context: ModelContext) {
        guard !isHidden(ao3Id: ao3Id, in: context) else { return }
        context.insert(HiddenWork(ao3Id: ao3Id, title: title))
        try? context.save()
    }

    @MainActor
    static func unhide(ao3Id: Int, in context: ModelContext) {
        let descriptor = FetchDescriptor<HiddenWork>(predicate: #Predicate { $0.ao3Id == ao3Id })
        for record in (try? context.fetch(descriptor)) ?? [] { context.delete(record) }
        try? context.save()
    }
}

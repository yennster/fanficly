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

/// Filters a list of works for display: drops anything the user has hidden, and
/// (when enabled) anything rated Mature or Explicit.
enum ContentFilter {
    static let matureRatings: Set<String> = ["Mature", "Explicit"]

    static func apply(_ works: [AO3WorkSummary], hiddenIds: Set<Int>, filterMature: Bool) -> [AO3WorkSummary] {
        works.filter { work in
            if hiddenIds.contains(work.id) { return false }
            if filterMature && matureRatings.contains(work.rating) { return false }
            return true
        }
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

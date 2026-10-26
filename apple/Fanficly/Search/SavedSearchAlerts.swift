import Foundation
import SwiftData

/// New-fic alerts for saved searches (#309). A saved search with alerts on
/// works like a feed: `SubscriptionPoller` runs it, newest posted first, and
/// posts a local notification for works posted since it last looked. Each
/// check is one throttled AO3 search; nothing leaves the device.
enum SavedSearchAlerts {
    /// How many saved searches can have alerts on at once. Every alerting
    /// search costs one AO3 search per poll, and AO3's search is slow (20–30 s
    /// before it answers is normal), so this keeps the load on AO3 small.
    static let maxAlertingSearches = 10
    /// How many seen work ids a search keeps. The newest are kept, which
    /// always includes the newest one `newMatches` compares against.
    static let knownWorkIdLimit = 200
    /// The Search tab checks an alerting search when it's shown and the last
    /// check is older than this (the background refresh rarely has time for
    /// an AO3 search, see `checkStaleSavedSearches`).
    static let foregroundCheckInterval: TimeInterval = 4 * 60 * 60

    /// What a check runs: exactly the saved search's keywords and filters,
    /// nothing inferred, sorted by date posted, newest first.
    static func filters(prompt: String) -> AO3SearchFilters {
        let parsed = SearchSyntax.parse(prompt)
        var filters = AO3SearchFilters().merging(parsed)
        filters.query = SearchSyntax.collapseWhitespace(parsed.query)
        filters.sortColumn = .createdAt
        filters.sortDirection = .desc
        return filters
    }

    /// The works in a check's results that were posted since the baseline.
    /// Nothing before a baseline exists: the first check only records what's
    /// there, so turning alerts on never alerts for the back catalogue. With
    /// a baseline but no seen ids (the search had no results), every work is
    /// new. Otherwise an unseen work is new when it's newer than every seen
    /// one (AO3 work ids only grow). An unseen work with a lower id is
    /// usually an old work that now matches (its tags were edited) and never
    /// alerts, unless it has one chapter and a date since the last check: a
    /// long-held draft just posted, or a gift revealed from an anonymous
    /// collection. Blurbs carry the day only, so the date gets 36 hours'
    /// slack. Internal for tests.
    static func newMatches(
        in works: [AO3WorkSummary], known: Set<Int>, baselined: Bool, lastCheckedAt: Date?
    ) -> [AO3WorkSummary] {
        guard baselined else { return [] }
        let unseen = works.filter { !known.contains($0.id) }
        guard let newestKnown = known.max() else { return unseen }
        let cutoff = lastCheckedAt?.addingTimeInterval(-36 * 60 * 60)
        return unseen.filter { work in
            if work.id > newestKnown { return true }
            guard work.chapterCount == 1 else { return false }
            guard let cutoff, let date = work.updatedAt else { return true }
            return date >= cutoff
        }
    }

    /// The seen ids after a check: the union, newest first, capped at
    /// `knownWorkIdLimit`. Internal for tests.
    static func baseline(_ known: [Int], adding ids: [Int]) -> [Int] {
        Array(Set(known).union(ids).sorted(by: >).prefix(knownWorkIdLimit))
    }

    /// Whether another saved search may have alerts switched on.
    @MainActor
    static func canEnableMore(in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.alertsEnabled == true })
        return ((try? context.fetchCount(descriptor)) ?? 0) < maxAlertingSearches
    }

    /// Switches a search's alerts on or off. Switching on starts a fresh
    /// baseline, taken by the next check (the caller runs one right away), so
    /// works posted while alerts were off don't all alert at once.
    @MainActor
    static func setAlerts(_ on: Bool, for search: SavedSearch, context: ModelContext) {
        search.alertsEnabled = on
        search.alertsChangedAt = .now
        resetBaseline(of: search)
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
        if on { NotificationsAuthorization.requestAfterFollow() }
    }

    /// Forgets what a search has seen, for a new start or an edited search
    /// (the old results say nothing about the new one).
    @MainActor
    static func resetBaseline(of search: SavedSearch) {
        search.alertKnownWorkIds = []
        search.alertsBaselineAt = nil
        search.alertsLastCheckedAt = nil
        search.alertNewWorkIds = []
    }

    /// Clears a search's "New" count once its results have been opened.
    @MainActor
    static func markSeen(_ search: SavedSearch, context: ModelContext) {
        guard !search.alertNewWorkIds.isEmpty else { return }
        search.alertNewWorkIds = []
        try? context.save()
    }

    @MainActor
    static func markSeen(named name: String, context: ModelContext) {
        let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.name == name })
        if let search = (try? context.fetch(descriptor))?.first { markSeen(search, context: context) }
    }

    /// Takes one opened work off every search's "New" count.
    @MainActor
    static func markWorkSeen(_ workId: Int, context: ModelContext) {
        let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.alertsEnabled == true })
        var changed = false
        for search in (try? context.fetch(descriptor)) ?? [] where search.alertNewWorkIds.contains(workId) {
            search.alertNewWorkIds.removeAll { $0 == workId }
            changed = true
        }
        if changed { try? context.save() }
    }
}

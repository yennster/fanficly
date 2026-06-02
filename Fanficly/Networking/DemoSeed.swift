import Foundation
import SwiftData

/// Seeds the in-memory SwiftData store for `-demoMode` runs so the screens that
/// read local data (Library, Recently Viewed, saved searches & filters) have
/// realistic, all-ages content for App Store screenshots. Only ever called when
/// `FanficlyApp.isDemoMode` is true.
enum DemoSeed {
    @MainActor
    static func seed(into context: ModelContext) {
        // Idempotent: bail if we've already seeded this (in-memory) store.
        if let existing = try? context.fetch(FetchDescriptor<Work>()), !existing.isEmpty { return }

        // Library: a mix of followed and downloaded works.
        let followed = [90001, 90006, 90002]   // show with the bookmark badge
        let downloaded = [90001, 90004]         // show with the download badge

        for summary in DemoCatalog.works {
            let work = WorkPersistence.upsertMetadata(summary: summary, into: context, save: false)
            if followed.contains(summary.id) {
                work.isFollowed = true
                work.followedAt = summary.updatedAt
                work.lastSeenChapterCount = summary.chapterCount
            }
            if downloaded.contains(summary.id) {
                work.epubLocalPath = "library/\(summary.id).epub"
                writePlaceholderEPUB(workId: summary.id)
            }
        }

        // Recently Viewed: a handful, newest first.
        let recents: [(Int, Int)] = [(90003, 0), (90001, 1), (90007, 2), (90004, 3), (90006, 5)]
        for (id, daysAgo) in recents {
            let s = DemoCatalog.summary(for: id)
            let viewed = Calendar.current.date(byAdding: .hour, value: -daysAgo * 8, to: seedDate) ?? seedDate
            context.insert(RecentlyViewed(ao3Id: id, title: s.title, author: s.author,
                                          fandom: s.fandoms.first ?? "", viewedAt: viewed))
        }

        // Saved searches (Search toolbar menu).
        context.insert(SavedSearch(name: "Slow burn, complete", prompt: "slow burn complete general"))
        context.insert(SavedSearch(name: "Found family", prompt: "found family hurt/comfort"))
        context.insert(SavedSearch(name: "Coffee shop AUs", prompt: "coffee shop au fluff teen"))

        // Saved filters (Browse landing).
        var slowBurn = AO3SearchFilters()
        slowBurn.freeformNames = ["Slow Burn"]
        slowBurn.complete = .yes
        context.insert(SavedFilter(name: "Slow Burn · Complete", filtersJSON: slowBurn.savedJSON()))

        var cosy = AO3SearchFilters()
        cosy.freeformNames = ["Fluff"]
        cosy.ratings = [.general]
        context.insert(SavedFilter(name: "Fluff · General", filtersJSON: cosy.savedJSON()))

        try? context.save()
    }

    /// A fixed instant so the seed is deterministic between runs.
    private static let seedDate = Date(timeIntervalSince1970: 1_780_000_000)

    /// The Library "Downloaded" filter checks for a real file at
    /// documents/library/<id>.epub (see `WorkPersistence.epubURL`), so write a
    /// tiny placeholder there. Demo-only — never runs in a shipped build.
    private static func writePlaceholderEPUB(workId: Int) {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        let dir = docs.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(workId).epub")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("PK\u{03}\u{04}demo".utf8).write(to: url)
        }
    }
}

import Foundation
import SwiftData

/// Seeds the in-memory SwiftData store for `-demoMode` runs so the screens that
/// read local data (Library with reading progress, Recently Viewed, followed
/// authors, saved searches & filters) have realistic, all-ages content for App
/// Store screenshots. Only ever called when `FanficlyApp.isDemoMode` is true.
enum DemoSeed {
    @MainActor
    static func seed(into context: ModelContext) {
        // Idempotent: bail if we've already seeded this (in-memory) store.
        if let existing = try? context.fetch(FetchDescriptor<Work>()), !existing.isEmpty { return }

        // Library: a mix of followed and downloaded works.
        let followed = [90001, 90006, 90002]   // show with the bookmark badge
        let downloaded = [90001, 90004]         // show with the download badge

        // Reading progress for the Library progress-bar story: two works mid-read
        // and one finished (>= 99% → green "Finished"). (fraction, chapter, hoursAgo)
        let progress: [Int: (Double, Int, Int)] = [
            90001: (0.66, 8, 5),     // The Long Way Home — mid-read
            90002: (0.40, 4, 28),    // Letters Never Sent — earlier on
            90006: (1.00, 7, 72),    // Gardens in Winter — finished
        ]

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
            if let (fraction, chapter, hoursAgo) = progress[summary.id] {
                work.lastReadProgress = fraction
                work.lastReadChapter = chapter
                work.lastReadAt = Calendar.current.date(byAdding: .hour, value: -hoursAgo, to: seedDate) ?? seedDate
            }
        }

        // Followed authors (Authors tab + the "follow your favourite authors" story).
        let demoAuthors = ["wanderlight", "paperboats", "tealeaf", "frostfern", "orbital"]
        for (i, username) in demoAuthors.enumerated() {
            let followedAt = Calendar.current.date(byAdding: .day, value: -i, to: seedDate) ?? seedDate
            context.insert(FollowedAuthor(username: username, displayName: username, followedAt: followedAt))
        }

        // Recently Viewed: a handful, newest first.
        let recents: [(Int, Int)] = [(90003, 0), (90001, 1), (90007, 2), (90004, 3), (90006, 5)]
        for (id, daysAgo) in recents {
            let s = DemoCatalog.summary(for: id)
            let viewed = Calendar.current.date(byAdding: .hour, value: -daysAgo * 8, to: seedDate) ?? seedDate
            context.insert(RecentlyViewed(ao3Id: id, title: s.title, author: s.author,
                                          fandom: s.fandoms.first ?? "", viewedAt: viewed))
        }

        // Reading stats (Stats tab + yearly wrap). Spread active reading time
        // across the current year and the prior one, reusing each work's real
        // fandoms/categories/ships so the charts and "Year in Review" populate.
        for (i, summary) in DemoCatalog.works.enumerated() {
            let secs2026 = Double(1200 + (i % 4) * 1500)          // 20m … 95m
            let secs2025 = (i % 3 == 0) ? Double(600 + i * 360) : 0
            var yearSeconds: [String: Double] = ["2026": secs2026]
            if secs2025 > 0 { yearSeconds["2025"] = secs2025 }
            let lastRead = Calendar.current.date(byAdding: .day, value: -(i % 9), to: seedDate) ?? seedDate
            let firstRead = Calendar.current.date(byAdding: .day, value: -220, to: seedDate) ?? seedDate
            context.insert(ReadingStat(
                ao3Id: summary.id, title: summary.title, author: summary.author,
                fandoms: summary.fandoms, categories: summary.categories,
                relationships: summary.relationships, rating: summary.rating,
                wordCount: summary.wordCount, firstReadAt: firstRead, lastReadAt: lastRead,
                totalSeconds: secs2026 + secs2025, yearSeconds: yearSeconds
            ))
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

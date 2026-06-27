import Foundation
import SwiftData

enum ReadingProgressStore {
    @MainActor
    static func load(ao3Id: Int, in context: ModelContext) -> ReadingAnchor? {
        let descriptor = FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.ao3Id == ao3Id })
        guard let rec = (try? context.fetch(descriptor))?.first else { return nil }
        return ReadingAnchor(chapter: rec.chapterIndex, paragraph: rec.paragraphIndex)
    }

    @MainActor
    static func save(ao3Id: Int, anchor: ReadingAnchor, title: String, author: String,
                     progress: Double? = nil, syncWidgetImmediately: Bool = false, in context: ModelContext) {
        let now = Date.now
        let descriptor = FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.ao3Id == ao3Id })
        if let rec = (try? context.fetch(descriptor))?.first {
            rec.chapterIndex = anchor.chapter
            rec.paragraphIndex = anchor.paragraph
            rec.title = title
            rec.author = author
            rec.updatedAt = now
        } else {
            context.insert(ReadingProgress(
                ao3Id: ao3Id,
                chapterIndex: anchor.chapter,
                paragraphIndex: anchor.paragraph,
                title: title,
                author: author
            ))
        }

        let workDescriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == ao3Id })
        if let work = (try? context.fetch(workDescriptor))?.first {
            work.lastReadAt = now
            work.lastReadChapter = anchor.chapter
            if let progress {
                work.lastReadProgress = progress
            }
        }

        try? context.save()

        if let progress {
            WidgetProgressStore.save(
                id: ao3Id,
                title: title,
                author: author,
                progress: progress,
                chapter: anchor.chapter,
                paragraph: anchor.paragraph,
                updatedAt: now,
                syncImmediately: syncWidgetImmediately
            )
        }

        StreakStore.recordReadingEvent()
        WidgetDataStore.updateAll(context: context)
    }
}

// MARK: - Reading statistics

/// A pure, `Sendable` snapshot of a `ReadingStat`, so the aggregation that
/// drives the Stats screen can be unit-tested away from SwiftData.
struct ReadingStatSnapshot: Sendable, Equatable {
    var ao3Id: Int
    var title: String
    var author: String
    var fandoms: [String]
    var categories: [String]
    var relationships: [String]
    var rating: String
    var wordCount: Int
    var firstReadAt: Date
    var lastReadAt: Date
    var totalSeconds: Double
    var daySeconds: [String: Double]
    /// Furthest reading position reached, 0…1.
    var maxProgress: Double = 0
    /// Whether the underlying AO3 work is a completed work.
    var workIsComplete: Bool = false

    /// Clamped progress, defensive against out-of-range stored values.
    var progress: Double { min(max(maxProgress, 0), 1) }

    /// Whether the reader finished the work — the same rule the Library row uses
    /// for its "Finished" badge, so the two never disagree. Only finished works
    /// count toward "stories read".
    var isFinished: Bool {
        progress >= 0.99 || (workIsComplete && progress >= 0.95)
    }

    /// Words actually read: full length scaled by how far the reader got.
    /// Crediting the whole work for merely opening it is the bug this fixes.
    var wordsRead: Int { Int((Double(wordCount) * progress).rounded()) }
}

extension ReadingStat {
    /// A value-type copy for the pure aggregator and SwiftUI `@Query` callers.
    var snapshot: ReadingStatSnapshot {
        ReadingStatSnapshot(
            ao3Id: ao3Id, title: title, author: author,
            fandoms: fandoms, categories: categories, relationships: relationships,
            rating: rating, wordCount: wordCount,
            firstReadAt: firstReadAt, lastReadAt: lastReadAt,
            totalSeconds: totalSeconds, daySeconds: daySeconds,
            maxProgress: maxProgress, workIsComplete: workIsComplete
        )
    }
}

/// A name with an associated tally (work count) for the "top fandoms / ships /
/// authors" lists. `id` is the name so SwiftUI `ForEach` stays stable.
struct ReadingTagCount: Identifiable, Equatable, Sendable {
    var name: String
    var count: Int
    var id: String { name }
}

/// The aggregated numbers shown on the Stats screen for one scope — all-time or
/// a single week/month/year period.
struct ReadingStatsSummary: Equatable, Sendable {
    var storiesRead: Int
    var totalSeconds: Double
    var totalWords: Int
    var topFandoms: [ReadingTagCount]
    var topCategories: [ReadingTagCount]
    var topRelationships: [ReadingTagCount]
    var topAuthors: [ReadingTagCount]

    static let empty = ReadingStatsSummary(
        storiesRead: 0, totalSeconds: 0, totalWords: 0,
        topFandoms: [], topCategories: [], topRelationships: [], topAuthors: []
    )
}

/// Pure aggregation over `ReadingStatSnapshot`s. No SwiftData, no UI — fully
/// unit-testable (see `ReadingStatsTests`). Time is bucketed per calendar day,
/// so any `DateInterval` (a week, month, year, or nil for all-time) rolls up
/// from the same data.
enum ReadingStatsAggregator {
    /// "yyyy-MM-dd" in the given calendar's time zone — the `daySeconds` key.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Parse a "yyyy-MM-dd" key back to the start of that day.
    static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    /// The span from the earliest to the latest day with recorded reading time,
    /// used to bound the period navigator. nil when there's no data.
    static func dataDateRange(_ snapshots: [ReadingStatSnapshot], calendar: Calendar = .current) -> ClosedRange<Date>? {
        var dates: [Date] = []
        for snapshot in snapshots {
            for key in snapshot.daySeconds.keys {
                if let d = date(fromDayKey: key, calendar: calendar) { dates.append(d) }
            }
        }
        guard let lo = dates.min(), let hi = dates.max() else { return nil }
        return lo...hi
    }

    /// Aggregate snapshots for a scope. `interval == nil` means all-time;
    /// otherwise only days within `[interval.start, interval.end)` are counted —
    /// both for the time total and for which works/tags are included.
    static func summarize(_ snapshots: [ReadingStatSnapshot], interval: DateInterval?,
                          calendar: Calendar = .current, topCount: Int = 8) -> ReadingStatsSummary {
        // Per snapshot: seconds read inside the interval (all-time = total).
        func secondsInScope(_ s: ReadingStatSnapshot) -> Double {
            guard let interval else { return s.totalSeconds }
            var sum = 0.0
            for (key, secs) in s.daySeconds {
                guard let day = date(fromDayKey: key, calendar: calendar) else { continue }
                // Interval is [start, end); a day key is the start of its day.
                if day >= interval.start && day < interval.end { sum += secs }
            }
            return sum
        }

        // Whether the work was read on any day inside the interval. This, not
        // "time > 0", decides period membership so works backfilled from old
        // reading history — which have a read date but zero recorded time —
        // still show up in their week/month/year (and the yearly wrap). For
        // real reads the two are equivalent: every read day has positive time.
        func wasReadInScope(_ s: ReadingStatSnapshot) -> Bool {
            guard let interval else { return true }
            for key in s.daySeconds.keys {
                guard let day = date(fromDayKey: key, calendar: calendar) else { continue }
                if day >= interval.start && day < interval.end { return true }
            }
            return false
        }

        let scoped = snapshots.compactMap { s -> (ReadingStatSnapshot, Double)? in
            // All-time keeps every read work; a period keeps works read in it.
            if interval == nil || wasReadInScope(s) { return (s, secondsInScope(s)) }
            return nil
        }
        guard !scoped.isEmpty else { return .empty }

        let totalSeconds = scoped.reduce(0) { $0 + $1.1 }
        let works = scoped.map { $0.0 }
        // Words read reflects how far the reader actually got, not the full
        // length of every work they opened. Stories read counts only works the
        // reader finished (hit ~100%), not everything they dipped into.
        let totalWords = works.reduce(0) { $0 + $1.wordsRead }

        return ReadingStatsSummary(
            storiesRead: works.filter { $0.isFinished }.count,
            totalSeconds: totalSeconds,
            totalWords: totalWords,
            topFandoms: rank(works.flatMap { $0.fandoms }, topCount: topCount),
            topCategories: rank(works.flatMap { $0.categories }, topCount: topCount),
            topRelationships: rank(works.flatMap { $0.relationships }, topCount: topCount),
            topAuthors: rank(works.compactMap { $0.author.isEmpty ? nil : $0.author }, topCount: topCount)
        )
    }

    /// Tally occurrences of each name, most common first. Ties break
    /// alphabetically so the order is deterministic (and testable).
    static func rank(_ names: [String], topCount: Int) -> [ReadingTagCount] {
        var counts: [String: Int] = [:]
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts
            .map { ReadingTagCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(topCount)
            .map { $0 }
    }
}

@MainActor
enum ReadingStatsStore {
    /// Record `seconds` of active reading for a work, creating or updating its
    /// `ReadingStat` row and refreshing the metadata snapshot. Time is bucketed
    /// into the calendar day of `date` so any period can be aggregated later.
    /// Non-empty metadata overwrites the snapshot; empty fields are left
    /// untouched so a later read that happens to lack metadata can't wipe it.
    static func record(ao3Id: Int, title: String, author: String,
                       fandoms: [String], categories: [String], relationships: [String],
                       rating: String, wordCount: Int, seconds: Double,
                       progress: Double = 0, isComplete: Bool = false,
                       date: Date = .now, in context: ModelContext) {
        guard seconds.isFinite, seconds >= 0 else { return }
        // Progress only ever advances — the furthest the reader has reached.
        let clampedProgress = progress.isFinite ? min(max(progress, 0), 1) : 0
        let dayKey = ReadingStatsAggregator.dayKey(for: date)
        let descriptor = FetchDescriptor<ReadingStat>(predicate: #Predicate { $0.ao3Id == ao3Id })
        if let stat = (try? context.fetch(descriptor))?.first {
            if !title.isEmpty { stat.title = title }
            if !author.isEmpty { stat.author = author }
            if !fandoms.isEmpty { stat.fandoms = fandoms }
            if !categories.isEmpty { stat.categories = categories }
            if !relationships.isEmpty { stat.relationships = relationships }
            if !rating.isEmpty { stat.rating = rating }
            if wordCount > 0 { stat.wordCount = wordCount }
            stat.lastReadAt = date
            stat.totalSeconds += seconds
            stat.daySeconds[dayKey, default: 0] += seconds
            stat.maxProgress = max(stat.maxProgress, clampedProgress)
            if isComplete { stat.workIsComplete = true }
        } else {
            context.insert(ReadingStat(
                ao3Id: ao3Id, title: title, author: author,
                fandoms: fandoms, categories: categories, relationships: relationships,
                rating: rating, wordCount: wordCount,
                firstReadAt: date, lastReadAt: date,
                totalSeconds: seconds, daySeconds: [dayKey: seconds],
                maxProgress: clampedProgress, workIsComplete: isComplete
            ))
        }
        try? context.save()
    }

    /// Fetch every `ReadingStat` as a value-type snapshot for aggregation.
    static func snapshots(in context: ModelContext) -> [ReadingStatSnapshot] {
        let stats = (try? context.fetch(FetchDescriptor<ReadingStat>())) ?? []
        return stats.map(\.snapshot)
    }
}

// MARK: - One-time backfill from existing reading history

/// Seeds `ReadingStat` rows from the reading history that predates the Stats
/// feature, so people who'd already read fics don't open the Stats tab to a
/// blank "No Reading Stats Yet" screen.
///
/// The source is the user's existing on-device data: every `ReadingProgress`
/// row (the canonical "opened in the reader" set), enriched with the saved
/// `Work`'s metadata, plus any `Work` carrying a `lastReadAt` stamp. Words read
/// and "finished story" status come from each work's saved reading progress
/// (`Work.lastReadProgress`, or the chapter reached) — never the full length of
/// a work merely opened. Because the app never recorded historical reading
/// *time*, backfilled rows carry **zero seconds**: minutes stay honest at 0 and
/// accumulate for real from the next session on. A zero-valued day bucket on the
/// last-read date still dates each read so it lands in the right period.
///
/// It also enriches stat rows that already exist but predate progress tracking
/// (their `maxProgress` defaulted to 0 on migration), filling that in from saved
/// reading progress so their words-read / finished status are correct — without
/// touching their real recorded time.
///
/// This also covers the iCloud case: it runs after the launch restore, so works
/// and progress synced from another device are backfilled too. It's safe to run
/// every launch — a per-`ao3Id` lookup and a one-shot flag keep it from
/// duplicating rows or lowering progress the live recorder already set
/// (including stats an iCloud restore already brought over).
@MainActor
enum ReadingStatsBackfill {
    // v2: also enriches stat rows created before progress was tracked, so their
    // words-read / finished status come from saved reading progress rather than
    // the SwiftData default of zero.
    static let backfilledKey = "reading.stats.backfilled.v2"

    /// A value-type view of one previously-read work, assembled from
    /// `ReadingProgress` and (when saved) its `Work`. Kept SwiftData-free so the
    /// candidate gathering can be reasoned about and tested in isolation.
    struct Candidate: Equatable {
        var ao3Id: Int
        var title: String
        var author: String
        var fandoms: [String]
        var categories: [String]
        var relationships: [String]
        var rating: String
        var wordCount: Int
        /// Furthest progress the existing history shows, 0…1.
        var maxProgress: Double
        var isComplete: Bool
        var readDate: Date
    }

    /// Run the migration once. Inserts a `ReadingStat` for every previously-read
    /// work that doesn't already have one, then sets the flag. Gated so it's a
    /// no-op after the first successful pass.
    static func runIfNeeded(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: backfilledKey) else { return }
        backfill(in: context)
        defaults.set(true, forKey: backfilledKey)
    }

    /// The insertion + enrichment pass, without the flag gate — exposed for
    /// tests. Returns the number of new rows inserted (enrichment of existing
    /// rows isn't counted).
    @discardableResult
    static func backfill(in context: ModelContext) -> Int {
        var inserted = 0
        var changed = false
        for c in candidates(in: context) {
            let id = c.ao3Id
            if let stat = (try? context.fetch(
                FetchDescriptor<ReadingStat>(predicate: #Predicate { $0.ao3Id == id })))?.first {
                // Enrich a row that predates progress tracking: only fill in a
                // missing (zero) progress, never lower a value the live recorder
                // already set. Time and day buckets are left untouched.
                if stat.maxProgress == 0 && c.maxProgress > 0 {
                    stat.maxProgress = c.maxProgress
                    changed = true
                }
                if c.isComplete && !stat.workIsComplete {
                    stat.workIsComplete = true
                    changed = true
                }
                continue
            }
            let dayKey = ReadingStatsAggregator.dayKey(for: c.readDate)
            context.insert(ReadingStat(
                ao3Id: c.ao3Id, title: c.title, author: c.author,
                fandoms: c.fandoms, categories: c.categories, relationships: c.relationships,
                rating: c.rating, wordCount: c.wordCount,
                firstReadAt: c.readDate, lastReadAt: c.readDate,
                totalSeconds: 0, daySeconds: [dayKey: 0],
                maxProgress: c.maxProgress, workIsComplete: c.isComplete
            ))
            inserted += 1
        }
        if inserted > 0 || changed { try? context.save() }
        return inserted
    }

    /// Gather one candidate per previously-read work: `ReadingProgress` rows
    /// joined to their saved `Work` for metadata, unioned with any `Work` that
    /// has a `lastReadAt` but no progress row. Progress-only works (read but
    /// never saved) carry just title/author — there's no metadata to recover.
    static func candidates(in context: ModelContext) -> [Candidate] {
        let works = (try? context.fetch(FetchDescriptor<Work>())) ?? []
        let worksById = Dictionary(works.map { ($0.ao3Id, $0) }, uniquingKeysWith: { first, _ in first })
        let progress = (try? context.fetch(FetchDescriptor<ReadingProgress>())) ?? []

        // How far through a work the existing data shows. Prefer the saved
        // `lastReadProgress` fraction; otherwise approximate from the chapter the
        // reader reached over the work's chapter count. Unknown ⇒ 0.
        func fraction(for work: Work?, chapter: Int?) -> Double {
            if let p = work?.lastReadProgress, p.isFinite, p > 0 { return min(1, p) }
            if let work, let ch = chapter ?? work.lastReadChapter, ch >= 1 {
                let total = max(work.totalChapters ?? 0, work.chapterCount)
                if total > 1 { return min(1, Double(ch) / Double(total)) }
            }
            return 0
        }

        var byId: [Int: Candidate] = [:]
        for p in progress {
            let work = worksById[p.ao3Id]
            byId[p.ao3Id] = Candidate(
                ao3Id: p.ao3Id,
                title: work?.title ?? p.title,
                author: work?.authorName ?? p.author,
                fandoms: work?.fandoms ?? [],
                categories: work?.categories ?? [],
                relationships: work?.relationships ?? [],
                rating: work?.rating ?? "",
                wordCount: work?.wordCount ?? 0,
                maxProgress: fraction(for: work, chapter: p.chapterIndex),
                isComplete: work?.isComplete ?? false,
                readDate: p.updatedAt
            )
        }
        for work in works where work.lastReadAt != nil && byId[work.ao3Id] == nil {
            byId[work.ao3Id] = Candidate(
                ao3Id: work.ao3Id,
                title: work.title,
                author: work.authorName,
                fandoms: work.fandoms,
                categories: work.categories,
                relationships: work.relationships,
                rating: work.rating,
                wordCount: work.wordCount,
                maxProgress: fraction(for: work, chapter: nil),
                isComplete: work.isComplete,
                readDate: work.lastReadAt ?? .now
            )
        }
        return Array(byId.values)
    }
}

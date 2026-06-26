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
}

extension ReadingStat {
    /// A value-type copy for the pure aggregator and SwiftUI `@Query` callers.
    var snapshot: ReadingStatSnapshot {
        ReadingStatSnapshot(
            ao3Id: ao3Id, title: title, author: author,
            fandoms: fandoms, categories: categories, relationships: relationships,
            rating: rating, wordCount: wordCount,
            firstReadAt: firstReadAt, lastReadAt: lastReadAt,
            totalSeconds: totalSeconds, daySeconds: daySeconds
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

        let scoped = snapshots.compactMap { s -> (ReadingStatSnapshot, Double)? in
            let secs = secondsInScope(s)
            // All-time keeps every read work; a period keeps works read in it.
            if interval == nil || secs > 0 { return (s, secs) }
            return nil
        }
        guard !scoped.isEmpty else { return .empty }

        let totalSeconds = scoped.reduce(0) { $0 + $1.1 }
        let totalWords = scoped.reduce(0) { $0 + $1.0.wordCount }
        let works = scoped.map { $0.0 }

        return ReadingStatsSummary(
            storiesRead: works.count,
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
                       date: Date = .now, in context: ModelContext) {
        guard seconds.isFinite, seconds >= 0 else { return }
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
        } else {
            context.insert(ReadingStat(
                ao3Id: ao3Id, title: title, author: author,
                fandoms: fandoms, categories: categories, relationships: relationships,
                rating: rating, wordCount: wordCount,
                firstReadAt: date, lastReadAt: date,
                totalSeconds: seconds, daySeconds: [dayKey: seconds]
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

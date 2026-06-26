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
    var yearSeconds: [String: Double]
}

/// A name with an associated tally (work count) for the "top fandoms / ships /
/// authors" lists. `id` is the name so SwiftUI `ForEach` stays stable.
struct ReadingTagCount: Identifiable, Equatable, Sendable {
    var name: String
    var count: Int
    var id: String { name }
}

/// The aggregated numbers shown on the Stats screen for one scope — all-time or
/// a single calendar year.
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
/// unit-testable (see `ReadingStatsTests`).
enum ReadingStatsAggregator {
    static func yearKey(for date: Date, calendar: Calendar = .current) -> String {
        String(calendar.component(.year, from: date))
    }

    /// Every calendar year that has any recorded reading time, newest first.
    static func availableYears(_ snapshots: [ReadingStatSnapshot]) -> [Int] {
        var years = Set<Int>()
        for snapshot in snapshots {
            for key in snapshot.yearSeconds.keys {
                if let year = Int(key) { years.insert(year) }
            }
        }
        return years.sorted(by: >)
    }

    /// Aggregate snapshots for a scope. `year == nil` means all-time; otherwise
    /// only works read during that calendar year are counted, and time is the
    /// seconds recorded in that year.
    static func summarize(_ snapshots: [ReadingStatSnapshot], year: Int?, topCount: Int = 8) -> ReadingStatsSummary {
        let yearKey = year.map(String.init)
        let scoped: [ReadingStatSnapshot]
        if let yearKey {
            scoped = snapshots.filter { $0.yearSeconds[yearKey] != nil }
        } else {
            scoped = snapshots
        }
        guard !scoped.isEmpty else { return .empty }

        let totalSeconds: Double
        if let yearKey {
            totalSeconds = scoped.reduce(0) { $0 + ($1.yearSeconds[yearKey] ?? 0) }
        } else {
            totalSeconds = scoped.reduce(0) { $0 + $1.totalSeconds }
        }
        let totalWords = scoped.reduce(0) { $0 + $1.wordCount }

        return ReadingStatsSummary(
            storiesRead: scoped.count,
            totalSeconds: totalSeconds,
            totalWords: totalWords,
            topFandoms: rank(scoped.flatMap { $0.fandoms }, topCount: topCount),
            topCategories: rank(scoped.flatMap { $0.categories }, topCount: topCount),
            topRelationships: rank(scoped.flatMap { $0.relationships }, topCount: topCount),
            topAuthors: rank(scoped.compactMap { $0.author.isEmpty ? nil : $0.author }, topCount: topCount)
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
    /// into the calendar year of `date` for the yearly wrap. Non-empty metadata
    /// overwrites the snapshot; empty fields are left untouched so a later read
    /// that happens to lack metadata can't wipe it.
    static func record(ao3Id: Int, title: String, author: String,
                       fandoms: [String], categories: [String], relationships: [String],
                       rating: String, wordCount: Int, seconds: Double,
                       date: Date = .now, in context: ModelContext) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let yearKey = ReadingStatsAggregator.yearKey(for: date)
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
            stat.yearSeconds[yearKey, default: 0] += seconds
        } else {
            context.insert(ReadingStat(
                ao3Id: ao3Id, title: title, author: author,
                fandoms: fandoms, categories: categories, relationships: relationships,
                rating: rating, wordCount: wordCount,
                firstReadAt: date, lastReadAt: date,
                totalSeconds: seconds, yearSeconds: [yearKey: seconds]
            ))
        }
        try? context.save()
    }

    /// Fetch every `ReadingStat` as a value-type snapshot for aggregation.
    static func snapshots(in context: ModelContext) -> [ReadingStatSnapshot] {
        let stats = (try? context.fetch(FetchDescriptor<ReadingStat>())) ?? []
        return stats.map {
            ReadingStatSnapshot(
                ao3Id: $0.ao3Id, title: $0.title, author: $0.author,
                fandoms: $0.fandoms, categories: $0.categories, relationships: $0.relationships,
                rating: $0.rating, wordCount: $0.wordCount,
                firstReadAt: $0.firstReadAt, lastReadAt: $0.lastReadAt,
                totalSeconds: $0.totalSeconds, yearSeconds: $0.yearSeconds
            )
        }
    }
}

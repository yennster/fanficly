import XCTest
import SwiftData
@testable import Fanficly

@MainActor
final class PersistenceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, CustomFolder.self, FollowedAuthor.self,
            ReadingStat.self, BlockedTerm.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func payload(id: Int, chapters: Int) -> AO3WorkPayload {
        let summary = AO3WorkSummary(
            id: id, title: "Test Work \(id)", author: "tester",
            summary: "A summary", rating: "Mature", warnings: ["No Archive Warnings Apply"],
            categories: ["M/M"], fandoms: ["Harry Potter - J. K. Rowling"],
            characters: ["Harry Potter"], relationships: ["Harry/Draco"],
            freeforms: ["Fluff"], wordCount: 5000, chapterCount: chapters,
            totalChapters: chapters, language: "English", kudos: 100, hits: 2000,
            isComplete: true, updatedAt: nil
        )
        let chs = (1...chapters).map { AO3ChapterPayload(index: $0, title: "Ch \($0)", bodyHTML: "<p>Body \($0)</p>") }
        return AO3WorkPayload(summary: summary, chapters: chs)
    }

    private func readerProfile(name: String, theme: String, fontSize: Double) -> ReaderProfile {
        let base = ReaderProfile.defaultProfiles[0]
        return ReaderProfile(
            name: name,
            themeRaw: theme,
            fontFamilyRaw: base.fontFamilyRaw,
            widthRaw: base.widthRaw,
            widthPercent: base.widthPercent,
            modeRaw: base.modeRaw,
            fontSizePt: fontSize,
            lineSpacingPt: base.lineSpacingPt,
            paragraphSpacingPt: base.paragraphSpacingPt,
            pageTurnHaptics: base.pageTurnHaptics,
            pageTurnAnimations: base.pageTurnAnimations,
            kerningPt: base.kerningPt,
            boldText: base.boldText
        )
    }

    func test_upsertInsertsThenUpdates() throws {
        let ctx = try makeContext()
        let w1 = WorkPersistence.upsert(payload: payload(id: 1, chapters: 3), into: ctx)
        XCTAssertEqual(w1.chapters.count, 3)
        XCTAssertEqual(w1.fandoms, ["Harry Potter - J. K. Rowling"])

        // Re-upsert with fewer chapters replaces them, no duplicate Work.
        let w2 = WorkPersistence.upsert(payload: payload(id: 1, chapters: 2), into: ctx)
        XCTAssertEqual(w2.chapters.count, 2)
        let all = try ctx.fetch(FetchDescriptor<Work>())
        XCTAssertEqual(all.count, 1)
    }

    func test_toggleFollowAuthor() throws {
        let ctx = try makeContext()
        XCTAssertFalse(WorkPersistence.isAuthorFollowed(username: "tester", in: ctx))

        // Following seeds the already-published work ids so the poller won't
        // alert for the back catalogue on its first check.
        let nowFollowed = WorkPersistence.toggleFollowAuthor(
            username: "tester", displayName: "Tester", seedWorkIds: [1, 2, 3], into: ctx)
        XCTAssertTrue(nowFollowed)
        XCTAssertTrue(WorkPersistence.isAuthorFollowed(username: "tester", in: ctx))

        let followed = try ctx.fetch(FetchDescriptor<FollowedAuthor>())
        XCTAssertEqual(followed.count, 1)
        XCTAssertEqual(followed.first?.displayName, "Tester")
        XCTAssertEqual(followed.first?.knownWorkIds.sorted(), [1, 2, 3])

        let nowUnfollowed = WorkPersistence.toggleFollowAuthor(
            username: "tester", displayName: "Tester", into: ctx)
        XCTAssertFalse(nowUnfollowed)
        XCTAssertFalse(WorkPersistence.isAuthorFollowed(username: "tester", in: ctx))
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<FollowedAuthor>()).isEmpty)
    }

    /// An empty username (anonymous byline) can't be followed.
    func test_followAuthorIgnoresEmptyUsername() throws {
        let ctx = try makeContext()
        let followed = WorkPersistence.toggleFollowAuthor(
            username: "", displayName: "Anonymous", into: ctx)
        XCTAssertFalse(followed)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<FollowedAuthor>()).isEmpty)
    }

    func test_upsertMetadataDoesNotTouchChapters() throws {
        let ctx = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 7, chapters: 4), into: ctx)
        let summary = payload(id: 7, chapters: 4).summary
        let w = WorkPersistence.upsertMetadata(summary: summary, into: ctx)
        XCTAssertEqual(w.chapters.count, 4, "metadata upsert must keep existing chapters")
    }

    func test_toggleFollow() throws {
        let ctx = try makeContext()
        let summary = payload(id: 9, chapters: 1).summary
        XCTAssertFalse(WorkPersistence.isFollowed(workId: 9, in: ctx))

        let nowFollowed = WorkPersistence.toggleFollow(summary: summary, into: ctx)
        XCTAssertTrue(nowFollowed)
        XCTAssertTrue(WorkPersistence.isFollowed(workId: 9, in: ctx))

        let nowUnfollowed = WorkPersistence.toggleFollow(summary: summary, into: ctx)
        XCTAssertFalse(nowUnfollowed)
        XCTAssertFalse(WorkPersistence.isFollowed(workId: 9, in: ctx))
    }

    // MARK: Result-row badges (RM-002)

    func test_resultBadge_unknownWorkHasNone() {
        XCTAssertNil(WorkPersistence.resultBadge(inLibrary: false, started: false, progress: nil, isComplete: false))
        XCTAssertNil(WorkPersistence.resultBadge(inLibrary: false, started: false, progress: 0, isComplete: true))
    }

    func test_resultBadge_savedWorkReadsInLibrary() {
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: true, started: false, progress: nil, isComplete: false), .inLibrary)
    }

    func test_resultBadge_startedWorkShowsPercent() {
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: true, started: true, progress: 0.42, isComplete: false), .percent(42))
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: false, started: true, progress: 0.42, isComplete: true), .percent(42))
        // A sliver of progress still reads as begun, never 0%.
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: false, started: true, progress: 0.001, isComplete: false), .percent(1))
        // Opened but no fraction yet.
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: true, started: true, progress: nil, isComplete: false), .started)
    }

    func test_resultBadge_finishedFollowsTheLibraryRule() {
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: true, started: true, progress: 0.99, isComplete: false), .finished)
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: false, started: true, progress: 1.4, isComplete: false), .finished)
        // 95% finishes a complete work but not a work in progress.
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: false, started: true, progress: 0.96, isComplete: true), .finished)
        XCTAssertEqual(WorkPersistence.resultBadge(inLibrary: false, started: true, progress: 0.96, isComplete: false), .percent(96))
    }

    func test_resultBadges_lookUpAPageAtOnce() throws {
        let ctx = try makeContext()
        // 1: saved, never read. 2: saved and half read. 3: read without saving.
        // 4: opened without saving, no fraction. 5: unknown.
        _ = WorkPersistence.upsertMetadata(summary: payload(id: 1, chapters: 1).summary, into: ctx)
        let half = WorkPersistence.upsertMetadata(summary: payload(id: 2, chapters: 4).summary, into: ctx)
        half.lastReadProgress = 0.5
        half.lastReadAt = .now
        ctx.insert(ReadingProgress(ao3Id: 3, chapterIndex: 2))
        ctx.insert(ReadingStat(ao3Id: 3, maxProgress: 1, workIsComplete: true))
        ctx.insert(ReadingProgress(ao3Id: 4))
        try ctx.save()

        let page = (1...5).map { payload(id: $0, chapters: 1).summary }
        let badges = WorkPersistence.resultBadges(for: page, in: ctx)
        XCTAssertEqual(badges[1], .inLibrary)
        XCTAssertEqual(badges[2], .percent(50))
        XCTAssertEqual(badges[3], .finished)
        XCTAssertEqual(badges[4], .started)
        XCTAssertNil(badges[5])
        XCTAssertEqual(WorkPersistence.resultBadges(for: [], in: ctx), [:])
    }

    func test_recordViewInsertsBumpsAndTrims() throws {
        let ctx = try makeContext()
        // First view inserts.
        WorkPersistence.recordView(summary: payload(id: 1, chapters: 1).summary, into: ctx)
        WorkPersistence.recordView(summary: payload(id: 2, chapters: 1).summary, into: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<RecentlyViewed>()).count, 2)

        // Re-viewing id 1 bumps it to the front without duplicating.
        WorkPersistence.recordView(summary: payload(id: 1, chapters: 1).summary, into: ctx)
        let ordered = try ctx.fetch(FetchDescriptor<RecentlyViewed>(
            sortBy: [SortDescriptor(\.viewedAt, order: .reverse)]))
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered.first?.ao3Id, 1)

        // Trims to the newest `limit`.
        for id in 100..<110 {
            WorkPersistence.recordView(summary: payload(id: id, chapters: 1).summary, into: ctx, limit: 3)
        }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<RecentlyViewed>()).count, 3)
    }

    func test_readingProgressRoundTrips() throws {
        let ctx = try makeContext()
        XCTAssertNil(ReadingProgressStore.load(ao3Id: 42, in: ctx))

        ReadingProgressStore.save(ao3Id: 42, anchor: ReadingAnchor(chapter: 5, paragraph: 12),
                                  title: "T", author: "A", in: ctx)
        let a = ReadingProgressStore.load(ao3Id: 42, in: ctx)
        XCTAssertEqual(a?.chapter, 5)
        XCTAssertEqual(a?.paragraph, 12)

        // Saving again updates in place (no duplicate row).
        ReadingProgressStore.save(ao3Id: 42, anchor: ReadingAnchor(chapter: 6, paragraph: 0),
                                  title: "T", author: "A", in: ctx)
        XCTAssertEqual(ReadingProgressStore.load(ao3Id: 42, in: ctx)?.chapter, 6)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReadingProgress>()).count, 1)
    }

    // MARK: - Reading stats

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    func test_readingStatsStore_accumulatesAndBucketsByDay() throws {
        let ctx = try makeContext()
        let d1 = day(2026, 6, 15)
        let d2 = day(2026, 6, 16)

        ReadingStatsStore.record(ao3Id: 7, title: "T", author: "A",
                                 fandoms: ["Fandom X"], categories: ["M/M"], relationships: ["A/B"],
                                 rating: "Teen", wordCount: 5000, seconds: 600, progress: 0.3, date: d1, in: ctx)
        // Second read, same work, same day → accrues onto the one bucket.
        ReadingStatsStore.record(ao3Id: 7, title: "T", author: "A",
                                 fandoms: ["Fandom X"], categories: ["M/M"], relationships: ["A/B"],
                                 rating: "Teen", wordCount: 5000, seconds: 300, progress: 0.8, date: d1, in: ctx)
        // Same work read on a new day → new day bucket, same row. Progress went
        // backward this read (re-skim); the stored max must not regress.
        ReadingStatsStore.record(ao3Id: 7, title: "T", author: "A",
                                 fandoms: [], categories: [], relationships: [],
                                 rating: "", wordCount: 0, seconds: 120, progress: 0.5, date: d2, in: ctx)

        let rows = try ctx.fetch(FetchDescriptor<ReadingStat>())
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.totalSeconds, 1020, accuracy: 0.001)
        XCTAssertEqual(row.daySeconds[ReadingStatsAggregator.dayKey(for: d1)] ?? 0, 900, accuracy: 0.001)
        XCTAssertEqual(row.daySeconds[ReadingStatsAggregator.dayKey(for: d2)] ?? 0, 120, accuracy: 0.001)
        // Empty metadata on the later read must not wipe the snapshot.
        XCTAssertEqual(row.fandoms, ["Fandom X"])
        XCTAssertEqual(row.wordCount, 5000)
        // Progress is the furthest reached (0.8), never a later lower value.
        XCTAssertEqual(row.maxProgress, 0.8, accuracy: 0.001)
    }

    func test_readingStatsAggregator_wordsFollowProgressAndStoriesCountFinished() {
        let d = day(2026, 6, 10)
        let key = ReadingStatsAggregator.dayKey(for: d)
        func snap(_ id: Int, words: Int, progress: Double, complete: Bool = false) -> ReadingStatSnapshot {
            ReadingStatSnapshot(ao3Id: id, title: "", author: "A",
                                fandoms: [], categories: [], relationships: [],
                                rating: "", wordCount: words,
                                firstReadAt: d, lastReadAt: d,
                                totalSeconds: 60, daySeconds: [key: 60],
                                maxProgress: progress, workIsComplete: complete)
        }
        let snaps = [
            snap(1, words: 10_000, progress: 1.0),   // finished → 10k words
            snap(2, words: 10_000, progress: 0.25),  // a quarter read → 2.5k words, not finished
            snap(3, words: 4_000, progress: 0.96, complete: true), // complete work at 96% → finished
        ]
        let all = ReadingStatsAggregator.summarize(snaps, interval: nil)
        // Words read tracks progress, not full length: 10000 + 2500 + 3840.
        XCTAssertEqual(all.totalWords, 16_340)
        // Only the two finished works count as stories read.
        XCTAssertEqual(all.storiesRead, 2)
    }

    // MARK: Yearly reading goal (RM-011)

    private var utcGregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func utcDate(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 0) -> Date {
        utcGregorian.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
    }

    func test_goalProgress_atYearStartIsOnPace() throws {
        let p = try XCTUnwrap(ReadingStatsAggregator.goalProgress(
            finished: 0, goal: 52, now: utcDate(2026, 1, 1, hour: 1), calendar: utcGregorian))
        XCTAssertEqual(p.expected, 0)
        XCTAssertEqual(p.ahead, 0)
        XCTAssertEqual(p.fraction, 0, accuracy: 0.0001)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.paceLabel, "On pace")
    }

    func test_goalProgress_midYearReportsAheadAndBehind() throws {
        // July 2 2026 00:00 UTC is 182 of 365 days in: an even pace of 24 a
        // year expects 11 (11.97 rounded down).
        let mid = utcDate(2026, 7, 2)
        let onPace = try XCTUnwrap(ReadingStatsAggregator.goalProgress(
            finished: 11, goal: 24, now: mid, calendar: utcGregorian))
        XCTAssertEqual(onPace.expected, 11)
        XCTAssertEqual(onPace.paceLabel, "On pace")
        XCTAssertEqual(onPace.fraction, 11.0 / 24.0, accuracy: 0.0001)

        let ahead = try XCTUnwrap(ReadingStatsAggregator.goalProgress(
            finished: 14, goal: 24, now: mid, calendar: utcGregorian))
        XCTAssertEqual(ahead.ahead, 3)
        XCTAssertEqual(ahead.paceLabel, "3 ahead")

        let behind = try XCTUnwrap(ReadingStatsAggregator.goalProgress(
            finished: 9, goal: 24, now: mid, calendar: utcGregorian))
        XCTAssertEqual(behind.ahead, -2)
        XCTAssertEqual(behind.paceLabel, "2 behind")
    }

    func test_goalProgress_pastTheGoalIsCompleteWithAFullRing() throws {
        let p = try XCTUnwrap(ReadingStatsAggregator.goalProgress(
            finished: 30, goal: 20, now: utcDate(2026, 9, 1), calendar: utcGregorian))
        XCTAssertTrue(p.isComplete)
        XCTAssertEqual(p.fraction, 1, accuracy: 0.0001)
        XCTAssertEqual(p.paceLabel, "Goal reached")
    }

    func test_goalProgress_zeroGoalIsHidden() {
        XCTAssertNil(ReadingStatsAggregator.goalProgress(
            finished: 5, goal: 0, now: utcDate(2026, 6, 1), calendar: utcGregorian))
        XCTAssertNil(ReadingStatsAggregator.goalProgress(
            finished: 5, goal: -3, now: utcDate(2026, 6, 1), calendar: utcGregorian))
    }

    func test_backfill_seedsZeroTimeStatsFromHistory() throws {
        let ctx = try makeContext()
        let read = day(2026, 5, 10)

        // A saved work the user finished (metadata + saved progress available)…
        let work = Work(ao3Id: 11, title: "Saved Read", authorName: "Alice",
                        categories: ["M/M"], fandoms: ["Fandom X"],
                        relationships: ["A/B"], wordCount: 4000)
        work.lastReadAt = read
        work.lastReadProgress = 1.0
        ctx.insert(work)
        ctx.insert(ReadingProgress(ao3Id: 11, chapterIndex: 3, title: "Saved Read",
                                   author: "Alice", updatedAt: read))
        // …and a work read but never saved (progress only, no metadata/progress).
        ctx.insert(ReadingProgress(ao3Id: 22, chapterIndex: 1, title: "Unsaved Read",
                                   author: "Bob", updatedAt: read))

        XCTAssertEqual(ReadingStatsBackfill.backfill(in: ctx), 2)

        let stats = try ctx.fetch(FetchDescriptor<ReadingStat>()).sorted { $0.ao3Id < $1.ao3Id }
        XCTAssertEqual(stats.map(\.ao3Id), [11, 22])

        let saved = stats[0]
        XCTAssertEqual(saved.title, "Saved Read")
        XCTAssertEqual(saved.fandoms, ["Fandom X"])
        XCTAssertEqual(saved.wordCount, 4000)
        // Progress carried over from the saved reading position.
        XCTAssertEqual(saved.maxProgress, 1.0, accuracy: 0.001)
        // Time stays honest at zero, but a zero day bucket dates the read.
        XCTAssertEqual(saved.totalSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(saved.daySeconds[ReadingStatsAggregator.dayKey(for: read)], 0)

        let snaps = stats.map(\.snapshot)
        let all = ReadingStatsAggregator.summarize(snaps, interval: nil)
        // Only the finished work counts as a story read; words follow progress.
        XCTAssertEqual(all.storiesRead, 1)
        XCTAssertEqual(all.totalWords, 4000)
        XCTAssertEqual(all.totalSeconds, 0, accuracy: 0.001)

        // Backfilled works still appear in the period containing their read day
        // (the yearly-wrap path), even with zero recorded time.
        let may = Calendar.current.dateInterval(of: .month, for: read)!
        let month = ReadingStatsAggregator.summarize(snaps, interval: may)
        XCTAssertEqual(month.storiesRead, 1)
        XCTAssertEqual(month.topFandoms.first?.name, "Fandom X")
    }

    func test_backfill_skipsWorksThatAlreadyHaveStats() throws {
        let ctx = try makeContext()
        let d = day(2026, 4, 1)
        // A real, timed stat already exists for this work…
        ReadingStatsStore.record(ao3Id: 11, title: "T", author: "Alice",
                                 fandoms: ["Fandom X"], categories: [], relationships: [],
                                 rating: "Teen", wordCount: 4000, seconds: 600, date: d, in: ctx)
        // …and there's also reading history for it.
        ctx.insert(ReadingProgress(ao3Id: 11, chapterIndex: 2, title: "T", author: "Alice"))

        XCTAssertEqual(ReadingStatsBackfill.backfill(in: ctx), 0)
        let rows = try ctx.fetch(FetchDescriptor<ReadingStat>())
        XCTAssertEqual(rows.count, 1)
        // The real recorded time must be left untouched.
        XCTAssertEqual(rows[0].totalSeconds, 600, accuracy: 0.001)
    }

    func test_backfill_enrichesExistingRowMissingProgress() throws {
        let ctx = try makeContext()
        let read = day(2026, 3, 20)
        // A stat row created before progress was tracked: real time, but
        // maxProgress defaulted to 0 — so it'd wrongly show 0 words / 0 stories.
        ReadingStatsStore.record(ao3Id: 11, title: "T", author: "Alice",
                                 fandoms: ["Fandom X"], categories: [], relationships: [],
                                 rating: "Teen", wordCount: 8000, seconds: 1800, date: read, in: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReadingStat>()).first?.maxProgress, 0)

        // The reading progress the user already has: finished this work.
        let work = Work(ao3Id: 11, title: "T", authorName: "Alice", wordCount: 8000)
        work.lastReadAt = read
        work.lastReadProgress = 1.0
        ctx.insert(work)
        ctx.insert(ReadingProgress(ao3Id: 11, chapterIndex: 1, title: "T", author: "Alice", updatedAt: read))

        // Enrichment inserts no new row but fills in the missing progress…
        XCTAssertEqual(ReadingStatsBackfill.backfill(in: ctx), 0)
        let row = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ReadingStat>()).first)
        XCTAssertEqual(row.maxProgress, 1.0, accuracy: 0.001)
        XCTAssertEqual(row.totalSeconds, 1800, accuracy: 0.001)  // time untouched
        // …so it now counts as a finished story with its full words read.
        let all = ReadingStatsAggregator.summarize([row.snapshot], interval: nil)
        XCTAssertEqual(all.storiesRead, 1)
        XCTAssertEqual(all.totalWords, 8000)
    }

    func test_backfill_runIfNeededIsOneTime() throws {
        let ctx = try makeContext()
        let defaults = UserDefaults(suiteName: "test.backfill.\(UUID().uuidString)")!
        ctx.insert(ReadingProgress(ao3Id: 11, chapterIndex: 1, title: "One", author: "A"))

        ReadingStatsBackfill.runIfNeeded(in: ctx, defaults: defaults)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReadingStat>()).count, 1)

        // New history arrives after the one-shot pass; runIfNeeded is now a no-op.
        ctx.insert(ReadingProgress(ao3Id: 22, chapterIndex: 1, title: "Two", author: "B"))
        ReadingStatsBackfill.runIfNeeded(in: ctx, defaults: defaults)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReadingStat>()).count, 1)
    }

    func test_readingStatsAggregator_summarizeByPeriod() {
        let cal = Calendar.current
        let key = { (d: Date) in ReadingStatsAggregator.dayKey(for: d) }
        let snaps = [
            ReadingStatSnapshot(ao3Id: 1, title: "", author: "Alice",
                                fandoms: ["HP", "Naruto"], categories: ["M/M"], relationships: ["A/B"],
                                rating: "Teen", wordCount: 1000,
                                firstReadAt: day(2026, 6, 15), lastReadAt: day(2026, 6, 15),
                                totalSeconds: 600, daySeconds: [key(day(2026, 6, 15)): 600],
                                maxProgress: 1.0),
            ReadingStatSnapshot(ao3Id: 2, title: "", author: "Alice",
                                fandoms: ["HP"], categories: ["F/M"], relationships: ["C/D"],
                                rating: "Mature", wordCount: 2000,
                                firstReadAt: day(2025, 3, 2), lastReadAt: day(2025, 3, 2),
                                totalSeconds: 1200, daySeconds: [key(day(2025, 3, 2)): 1200],
                                maxProgress: 1.0),
        ]

        // All-time.
        let all = ReadingStatsAggregator.summarize(snaps, interval: nil)
        XCTAssertEqual(all.storiesRead, 2)
        XCTAssertEqual(all.totalSeconds, 1800, accuracy: 0.001)
        XCTAssertEqual(all.totalWords, 3000)
        XCTAssertEqual(all.topFandoms.first?.name, "HP")
        XCTAssertEqual(all.topFandoms.first?.count, 2)
        XCTAssertEqual(all.topAuthors.first?.name, "Alice")

        // June 2026 (month) → only the first work.
        let june = cal.dateInterval(of: .month, for: day(2026, 6, 15))!
        let month = ReadingStatsAggregator.summarize(snaps, interval: june)
        XCTAssertEqual(month.storiesRead, 1)
        XCTAssertEqual(month.totalSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(month.totalWords, 1000)

        // 2025 (year) → only the second work.
        let year2025 = cal.dateInterval(of: .year, for: day(2025, 3, 2))!
        let year = ReadingStatsAggregator.summarize(snaps, interval: year2025)
        XCTAssertEqual(year.storiesRead, 1)
        XCTAssertEqual(year.totalSeconds, 1200, accuracy: 0.001)

        // A period with no reads is empty.
        let june2024 = cal.dateInterval(of: .month, for: day(2024, 6, 15))!
        XCTAssertEqual(ReadingStatsAggregator.summarize(snaps, interval: june2024), .empty)

        // Data range spans the earliest to latest reading day.
        let range = ReadingStatsAggregator.dataDateRange(snaps)
        XCTAssertEqual(range?.lowerBound, day(2025, 3, 2))
        XCTAssertEqual(range?.upperBound, day(2026, 6, 15))

        XCTAssertEqual(ReadingStatsAggregator.summarize([], interval: nil), .empty)
    }

    func test_readingStatsAggregator_rankOrdersByCountThenName() {
        let ranked = ReadingStatsAggregator.rank(["B", "A", "A", "B", "C", "B", " "], topCount: 2)
        XCTAssertEqual(ranked.map(\.name), ["B", "A"])
        XCTAssertEqual(ranked.first?.count, 3)
        // Whitespace-only names are ignored.
        XCTAssertFalse(ranked.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func test_statsFormatting() {
        XCTAssertEqual(StatsView.formatDuration(0), "0m")
        XCTAssertEqual(StatsView.formatDuration(30), "<1m")
        XCTAssertEqual(StatsView.formatDuration(45 * 60), "45m")
        XCTAssertEqual(StatsView.formatDuration(3600), "1h")
        XCTAssertEqual(StatsView.formatDuration(3600 + 34 * 60), "1h 34m")
        // Compact branches are locale-independent (the <10K branch uses a
        // grouping separator that varies by locale, so it isn't asserted here).
        XCTAssertEqual(StatsView.formatWords(12_000), "12K")
        XCTAssertEqual(StatsView.formatWords(2_500_000), "2.5M")
    }

    func test_iCloudSyncRestoresSettings() async throws {
        let ctx = try makeContext()
        
        // Setup temporary override URL for testing
        let tempDir = FileManager.default.temporaryDirectory
        let testBackupURL = tempDir.appendingPathComponent("test_library_backup.json")
        iCloudSyncManager.overrideBackupURL = testBackupURL
        
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: testBackupURL)
        }
        
        // 1. Set some settings in UserDefaults
        let defaults = UserDefaults.standard
        defer {
            [
                "reader.theme",
                "reader.fontFamily",
                "reader.width",
                "reader.fontSizePt",
                "reader.profiles",
                "reader.theme.pad",
                "reader.activeProfile.pad",
                "reader.fontSizePt.pad",
                "content.filterMatureExplicit"
            ].forEach { defaults.removeObject(forKey: $0) }
        }
        defaults.set("sepia", forKey: "reader.theme")
        defaults.set("rounded", forKey: "reader.fontFamily")
        defaults.set("wide", forKey: "reader.width")
        defaults.set(22.0, forKey: "reader.fontSizePt")
        defaults.set(true, forKey: "content.filterMatureExplicit")
        
        // Device-specific settings
        defaults.set("dracula", forKey: "reader.theme.pad")
        defaults.set("compact", forKey: "reader.activeProfile.pad")
        defaults.set(18.0, forKey: "reader.fontSizePt.pad")

        let macProfile = readerProfile(name: "Mac", theme: "dracula", fontSize: 24.0)
        defaults.set(ReaderProfile.saveProfiles([ReaderProfile.defaultProfiles[0], macProfile]),
                     forKey: "reader.profiles")
        
        // 2. Perform backup
        let syncManager = iCloudSyncManager.shared
        syncManager.backupToiCloud(context: ctx)
        
        // 3. Reset settings in UserDefaults
        defaults.removeObject(forKey: "reader.theme")
        defaults.removeObject(forKey: "reader.fontFamily")
        defaults.removeObject(forKey: "reader.width")
        defaults.removeObject(forKey: "reader.fontSizePt")
        defaults.removeObject(forKey: "content.filterMatureExplicit")
        
        defaults.removeObject(forKey: "reader.theme.pad")
        defaults.removeObject(forKey: "reader.activeProfile.pad")
        defaults.removeObject(forKey: "reader.fontSizePt.pad")

        let phoneProfile = readerProfile(name: "iPhone", theme: "system", fontSize: 20.0)
        defaults.set(ReaderProfile.saveProfiles([ReaderProfile.defaultProfiles[0], phoneProfile]),
                     forKey: "reader.profiles")
        
        XCTAssertNil(defaults.string(forKey: "reader.theme"))
        XCTAssertNil(defaults.string(forKey: "reader.theme.pad"))
        
        // 4. Restore from backup
        let success = await syncManager.restoreFromiCloud(context: ctx)
        XCTAssertTrue(success)
        
        // 5. Verify they are restored
        XCTAssertEqual(defaults.string(forKey: "reader.theme"), "sepia")
        XCTAssertEqual(defaults.string(forKey: "reader.fontFamily"), "rounded")
        XCTAssertEqual(defaults.string(forKey: "reader.width"), "wide")
        XCTAssertEqual(defaults.double(forKey: "reader.fontSizePt"), 22.0)
        XCTAssertTrue(defaults.bool(forKey: "content.filterMatureExplicit"))
        
        XCTAssertEqual(defaults.string(forKey: "reader.theme.pad"), "dracula")
        XCTAssertEqual(defaults.string(forKey: "reader.activeProfile.pad"), "compact")
        XCTAssertEqual(defaults.double(forKey: "reader.fontSizePt.pad"), 18.0)

        let restoredProfiles = ReaderProfile.loadProfiles(from: defaults.string(forKey: "reader.profiles") ?? "")
        XCTAssertEqual(restoredProfiles.first(where: { $0.name == "Mac" })?.fontSizePt, 24.0)
        XCTAssertEqual(restoredProfiles.first(where: { $0.name == "iPhone" })?.fontSizePt, 20.0)
    }

    // MARK: - iCloud backup/restore merge rules

    private func makeTempBackupURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test_backup_\(UUID().uuidString).json")
    }

    private func decodeBackup(at url: URL) throws -> LibraryBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryBackup.self, from: Data(contentsOf: url))
    }

    /// A device holding only part of the library must union with the cloud
    /// backup, not overwrite it (the "iPad with 5 works clobbers the iPhone's
    /// 50" data-loss scenario).
    func test_backupUnionsWithExistingCloudBackup() throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        // The "iPhone": three works, backed up first.
        let phone = try makeContext()
        for id in 1...3 { _ = WorkPersistence.upsert(payload: payload(id: id, chapters: 2), into: phone) }
        iCloudSyncManager.shared.backupToiCloud(context: phone)
        XCTAssertEqual(try decodeBackup(at: url).works.count, 3)

        // The "iPad": holds only work 4. Its backup must keep the other three.
        let pad = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 4, chapters: 1), into: pad)
        iCloudSyncManager.shared.backupToiCloud(context: pad)

        XCTAssertEqual(try decodeBackup(at: url).works.map(\.ao3Id), [1, 2, 3, 4])
    }

    /// On a per-work conflict the backing-up device's record wins, but the
    /// cloud copy's chapters survive when the local copy is metadata-only.
    func test_backupMergeLocalWinsButKeepsCloudChapters() throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        // Device A saved the full download (3 chapters, with AO3 chapter ids)…
        let a = try makeContext()
        let downloaded = Work(ao3Id: 1, title: "Old Title", authorName: "A")
        a.insert(downloaded)
        for i in 0..<3 {
            a.insert(Chapter(work: downloaded, index: i + 1, title: "Ch \(i + 1)",
                             bodyHTML: "<p>body</p>", aoId: 900 + i))
        }
        try a.save()
        iCloudSyncManager.shared.backupToiCloud(context: a)

        // …device B holds a metadata-only copy with fresher metadata.
        let b = try makeContext()
        b.insert(Work(ao3Id: 1, title: "New Title", authorName: "A"))
        try b.save()
        iCloudSyncManager.shared.backupToiCloud(context: b)

        let merged = try decodeBackup(at: url)
        XCTAssertEqual(merged.works.count, 1)
        XCTAssertEqual(merged.works[0].title, "New Title")
        XCTAssertEqual(merged.works[0].chapters.map(\.aoId), [900, 901, 902],
                       "cloud chapters (and their AO3 ids) must survive a metadata-only backup")
    }

    /// Stats from two devices union in the backup file: per-day maxima, and a
    /// total lifted to Σ daySeconds rather than the max of the device totals.
    func test_backupMergesStatsAcrossDevices() throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        let a = try makeContext()
        a.insert(ReadingStat(ao3Id: 7, title: "T", author: "A",
                             totalSeconds: 1000, daySeconds: ["2026-06-01": 1000]))
        try a.save()
        iCloudSyncManager.shared.backupToiCloud(context: a)

        let b = try makeContext()
        b.insert(ReadingStat(ao3Id: 7, title: "T", author: "A",
                             totalSeconds: 2000, daySeconds: ["2026-06-02": 2000]))
        try b.save()
        iCloudSyncManager.shared.backupToiCloud(context: b)

        let stat = try XCTUnwrap(decodeBackup(at: url).stats?.first)
        XCTAssertEqual(stat.daySeconds["2026-06-01"] ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(stat.daySeconds["2026-06-02"] ?? 0, 2000, accuracy: 0.001)
        XCTAssertEqual(stat.totalSeconds, 3000, accuracy: 0.001)
    }

    /// The Windows app writes fields this one doesn't know (its reader
    /// settings, followed authors, whatever comes later). An Apple backup that
    /// merges with its file keeps them, while this device's values still win
    /// where it has them, and a note cleared here stays cleared (#126).
    func test_backupKeepsKeysOnlyTheOtherAppKnows() throws {
        let url = makeTempBackupURL()
        let defaults = UserDefaults.standard
        let originalThemeMac = defaults.object(forKey: "reader.theme.mac")
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: iCloudSyncManager.previousBackupURL(for: url))
            defaults.set(originalThemeMac, forKey: "reader.theme.mac")
        }
        let work = #"""
            "authorName":"A","authorUsername":"","summary":"","rating":"Not Rated","warnings":[],"categories":[],"fandoms":[],"characters":[],"relationships":[],"freeforms":[],"language":"en","wordCount":0,"chapterCount":1,"kudos":0,"hits":0,"bookmarksCount":0,"commentsCount":0,"isComplete":false,"savedAt":"2026-01-01T00:00:00Z","isFollowed":false
            """#
        let windowsFile = """
            {"works":[{"ao3Id":1,"title":"PC Title",\(work),"note":"Old note","notesUpdatedAt":"2026-01-01T00:00:00Z","futureWorkField":"kept","chapters":[{"index":1,"title":"Ch","bodyHTML":"<p>x</p>","futureChapterField":7}]},
                      {"ao3Id":2,"title":"PC Only",\(work),"futureWorkField":"pc only","chapters":[]}],
             "bookmarks":[],"subscriptions":[],"searches":[],"progress":[],"filters":[],"hidden":[{"ao3Id":9,"title":"Nope","hiddenAt":"2026-01-01T00:00:00Z","futureReason":"spoilers"}],
             "settings":{"themeMac":"sepia","themeWindows":"night","activeProfileWindows":"Desk","fontSizePtWindows":19},
             "followedAuthors":[{"username":"writer","displayName":"Writer","followedAt":"2026-01-01T00:00:00Z","knownWorkIds":[1]}],
             "timestamp":"2026-01-01T00:00:00Z"}
            """
        try Data(windowsFile.utf8).write(to: url)

        // This Mac holds work 1 with a newer title and the note cleared later.
        defaults.set("dracula", forKey: "reader.theme.mac")
        let mac = try makeContext()
        let local = Work(ao3Id: 1, title: "Mac Title", authorName: "A")
        local.notesUpdatedAt = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")
        mac.insert(local)
        mac.insert(Chapter(work: local, index: 1, title: "Ch", bodyHTML: "<p>x</p>"))
        mac.insert(HiddenWork(ao3Id: 9, title: "Nope", hiddenAt: .now))
        try mac.save()
        iCloudSyncManager.shared.backupToiCloud(context: mac)
        XCTAssertNil(iCloudSyncManager.shared.lastBackupFailure)

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let works = try XCTUnwrap(root["works"] as? [[String: Any]])
        let shared = try XCTUnwrap(works.first { ($0["ao3Id"] as? Int) == 1 })
        XCTAssertEqual(shared["title"] as? String, "Mac Title")
        XCTAssertNil(shared["note"], "a note cleared on this device must not come back")
        XCTAssertEqual(shared["futureWorkField"] as? String, "kept")
        let chapter = try XCTUnwrap((shared["chapters"] as? [[String: Any]])?.first)
        XCTAssertEqual(chapter["futureChapterField"] as? Int, 7)
        XCTAssertEqual(works.first { ($0["ao3Id"] as? Int) == 2 }?["futureWorkField"] as? String, "pc only")
        XCTAssertEqual((root["hidden"] as? [[String: Any]])?.first?["futureReason"] as? String, "spoilers")
        let settings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertEqual(settings["themeMac"] as? String, "dracula")
        XCTAssertEqual(settings["themeWindows"] as? String, "night")
        XCTAssertEqual(settings["activeProfileWindows"] as? String, "Desk")
        XCTAssertEqual(settings["fontSizePtWindows"] as? Int, 19)
        let authors = try XCTUnwrap(root["followedAuthors"] as? [[String: Any]])
        XCTAssertEqual(authors.first?["username"] as? String, "writer")
        // And the file still decodes for both apps.
        XCTAssertEqual(try decodeBackup(at: url).works.count, 2)
    }

    /// A backup file that's there but won't decode (truncated, or a newer
    /// app's format) is left alone: writing this device's library over it
    /// would drop every other device's records (#125).
    func test_backupSkipsAnUnreadableBackupAndLeavesItUntouched() throws {
        let url = makeTempBackupURL()
        let previousURL = iCloudSyncManager.previousBackupURL(for: url)
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: previousURL)
        }

        let device = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 1), into: device)
        for garbage in ["", "not json", #"{"works":[{"ao3Id":1}]"#] {
            let original = Data(garbage.utf8)
            try original.write(to: url)
            iCloudSyncManager.shared.backupToiCloud(context: device)
            XCTAssertEqual(try Data(contentsOf: url), original, "an unreadable backup must not be overwritten")
            XCTAssertNotNil(iCloudSyncManager.shared.lastBackupFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousURL.path))
    }

    /// Each write keeps the file it replaces as library_backup.prev.json, and
    /// clearing iCloud data removes both.
    func test_backupKeepsThePreviousFileAndClearRemovesIt() throws {
        let url = makeTempBackupURL()
        let previousURL = iCloudSyncManager.previousBackupURL(for: url)
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: previousURL)
        }
        XCTAssertEqual(iCloudSyncManager.previousBackupURL(for: URL(fileURLWithPath: "/a/library_backup.json")).lastPathComponent,
                       "library_backup.prev.json")

        let device = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 1), into: device)
        iCloudSyncManager.shared.backupToiCloud(context: device)
        XCTAssertNil(iCloudSyncManager.shared.lastBackupFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousURL.path))
        let first = try Data(contentsOf: url)

        _ = WorkPersistence.upsert(payload: payload(id: 2, chapters: 1), into: device)
        iCloudSyncManager.shared.backupToiCloud(context: device)
        XCTAssertEqual(try Data(contentsOf: previousURL), first)
        XCTAssertEqual(try decodeBackup(at: url).works.map(\.ao3Id), [1, 2])

        XCTAssertTrue(iCloudSyncManager.shared.clearFromiCloud())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousURL.path))
    }

    /// A backup that merges in another device's records puts them in the
    /// file, not in this library, so it must not stamp the file as applied
    /// here: the next launch sync still has to restore them (#124). Each
    /// "device" has its own stamp, simulated by swapping the stamp's value.
    /// The iPad's file can arrive dated after the phone's last write or, when
    /// it was written offline or by a device whose clock runs behind, before it.
    func test_backupAfterAnotherDeviceStillRestoresItsRecordsAtLaunch() async throws {
        try await assertBackupAfterAnotherDeviceStillRestores(padFileOffset: 5)
        try await assertBackupAfterAnotherDeviceStillRestores(padFileOffset: -60)
    }

    private func assertBackupAfterAnotherDeviceStillRestores(padFileOffset: TimeInterval) async throws {
        let url = makeTempBackupURL()
        let stampKey = iCloudSyncManager.lastRestoredStampKey
        let defaults = UserDefaults.standard
        let originalStamp = defaults.object(forKey: stampKey)
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            defaults.set(originalStamp, forKey: stampKey)
        }
        let sync = iCloudSyncManager.shared

        // The phone backs up first and stamps the file it wrote.
        defaults.removeObject(forKey: stampKey)
        let phone = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 1), into: phone)
        sync.backupToiCloud(context: phone)
        XCTAssertFalse(sync.cloudBackupHasUnappliedChanges, "a device's own backup is applied there")
        let phoneStamp = try XCTUnwrap(defaults.object(forKey: stampKey) as? Date)

        // The iPad (its own stamp) saves five works and backs up later.
        defaults.removeObject(forKey: stampKey)
        let pad = try makeContext()
        for id in 10...14 { _ = WorkPersistence.upsert(payload: payload(id: id, chapters: 1), into: pad) }
        sync.backupToiCloud(context: pad)
        try FileManager.default.setAttributes([.modificationDate: phoneStamp.addingTimeInterval(padFileOffset)],
                                              ofItemAtPath: url.path)

        // Back on the phone: starring something backs up again, merging the
        // iPad's works into the file but not into the phone's library.
        defaults.set(phoneStamp, forKey: stampKey)
        let starred = try XCTUnwrap(try phone.fetch(FetchDescriptor<Work>()).first)
        starred.isStarred = true
        try phone.save()
        sync.backupToiCloud(context: phone)
        XCTAssertEqual(try decodeBackup(at: url).works.count, 6)
        XCTAssertEqual(try phone.fetchCount(FetchDescriptor<Work>()), 1)

        // So the phone's next launch still restores, and gets the iPad's works.
        XCTAssertTrue(sync.cloudBackupHasUnappliedChanges)
        let restored = await sync.restoreFromiCloud(context: phone)
        XCTAssertTrue(restored)
        XCTAssertEqual(try phone.fetch(FetchDescriptor<Work>()).map(\.ao3Id).sorted(), [1, 10, 11, 12, 13, 14])
        XCTAssertFalse(sync.cloudBackupHasUnappliedChanges)

        // Once applied, the phone's own backups stamp the file again.
        sync.backupToiCloud(context: phone)
        XCTAssertFalse(sync.cloudBackupHasUnappliedChanges)
    }

    /// Sync Now brings in other devices' changes before it backs up, and
    /// stamps the file it writes.
    func test_syncNowBringsInAnotherDevicesChangesThenBacksUp() async throws {
        let url = makeTempBackupURL()
        let stampKey = iCloudSyncManager.lastRestoredStampKey
        let defaults = UserDefaults.standard
        let originalStamp = defaults.object(forKey: stampKey)
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            defaults.set(originalStamp, forKey: stampKey)
        }
        let sync = iCloudSyncManager.shared

        // Nothing in iCloud yet: Sync Now just backs up.
        defaults.removeObject(forKey: stampKey)
        let phone = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 1), into: phone)
        let first = await sync.syncNow(context: phone)
        XCTAssertFalse(first)
        let phoneStamp = try XCTUnwrap(defaults.object(forKey: stampKey) as? Date)

        // The iPad (its own stamp) backs up two works.
        defaults.removeObject(forKey: stampKey)
        let pad = try makeContext()
        for id in 10...11 { _ = WorkPersistence.upsert(payload: payload(id: id, chapters: 1), into: pad) }
        sync.backupToiCloud(context: pad)
        try FileManager.default.setAttributes([.modificationDate: phoneStamp.addingTimeInterval(5)],
                                              ofItemAtPath: url.path)

        // The phone's Sync Now pulls them in, then backs up and stamps.
        defaults.set(phoneStamp, forKey: stampKey)
        let second = await sync.syncNow(context: phone)
        XCTAssertTrue(second)
        XCTAssertEqual(try phone.fetch(FetchDescriptor<Work>()).map(\.ao3Id).sorted(), [1, 10, 11])
        XCTAssertEqual(try decodeBackup(at: url).works.count, 3)
        XCTAssertFalse(sync.cloudBackupHasUnappliedChanges)

        // With nothing new, it doesn't restore again.
        let third = await sync.syncNow(context: phone)
        XCTAssertFalse(third)
    }

    /// Blocked tags and authors from two devices union in the backup file
    /// (the same term in different case counts once), and restoring the
    /// merged file gives either device the whole list (RM-006).
    func test_backupUnionsBlockedTermsAcrossDevices() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        let phone = try makeContext()
        BlocklistStore.block(.tag, "Major Character Death", into: phone)
        BlocklistStore.block(.author, "writer", into: phone)
        iCloudSyncManager.shared.backupToiCloud(context: phone)

        let pad = try makeContext()
        BlocklistStore.block(.tag, "major character death", into: pad)
        BlocklistStore.block(.tag, "Angst", into: pad)
        iCloudSyncManager.shared.backupToiCloud(context: pad)

        let merged = try XCTUnwrap(try decodeBackup(at: url).blocked)
        XCTAssertEqual(merged.map(\.key), ["author:writer", "tag:angst", "tag:major character death"])

        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: pad)
        XCTAssertTrue(success)
        let restored = try pad.fetch(FetchDescriptor<BlockedTerm>()).map(\.key).sorted()
        XCTAssertEqual(restored, ["author:writer", "tag:angst", "tag:major character death"])
    }

    /// A backup written before the blocklist existed has no `blocked` key
    /// and must still decode.
    func test_backupWithoutBlockedTermsStillDecodes() throws {
        let json = """
        {"works":[],"bookmarks":[],"subscriptions":[],"searches":[],"progress":[],
         "filters":[],"hidden":[],"timestamp":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LibraryBackup.self, from: Data(json.utf8))
        XCTAssertNil(backup.blocked)
    }

    /// Restoring a metadata-only backup (chapters: []) must not delete a
    /// fuller offline download — the Downloaded badge keys off the epub file,
    /// so wiping chapters here would silently strand it.
    func test_restoreKeepsDownloadedChaptersWhenBackupHasFewer() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        // A metadata-only device (follow without download) wrote the backup…
        let metadataOnly = try makeContext()
        metadataOnly.insert(Work(ao3Id: 1, title: "T", authorName: "A"))
        try metadataOnly.save()
        iCloudSyncManager.shared.backupToiCloud(context: metadataOnly)

        // …restoring on the device holding the 4-chapter download keeps it.
        let device = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 4), into: device)
        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: device)
        XCTAssertTrue(success)
        let work = try XCTUnwrap(try device.fetch(FetchDescriptor<Work>()).first)
        XCTAssertEqual(work.chapters.count, 4)
    }

    /// When the backup does carry more chapters than the local copy, they
    /// replace it — and each chapter's AO3 id survives the round-trip.
    func test_restoreReplacesChaptersWhenBackupHasMoreAndKeepsAoId() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        let full = try makeContext()
        let downloaded = Work(ao3Id: 1, title: "T", authorName: "A")
        full.insert(downloaded)
        for i in 0..<3 {
            full.insert(Chapter(work: downloaded, index: i + 1, title: "Ch \(i + 1)",
                                bodyHTML: "<p>body</p>", aoId: 900 + i))
        }
        try full.save()
        iCloudSyncManager.shared.backupToiCloud(context: full)

        let device = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 1), into: device)
        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: device)
        XCTAssertTrue(success)
        let work = try XCTUnwrap(try device.fetch(FetchDescriptor<Work>()).first)
        let chapters = work.chapters.sorted { $0.index < $1.index }
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters.map(\.aoId), [900, 901, 902])
    }

    /// Restore also runs as a background launch sync now, so it must be a
    /// strictly forward merge: a cloud backup older than this device's state
    /// can never rewind a reading position — but a newer one still advances it.
    func test_restoreNeverRewindsNewerLocalProgress() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        // The cloud device read work 1 an hour ago (ch 2) but work 2 just now (ch 9).
        let cloudDevice = try makeContext()
        cloudDevice.insert(ReadingProgress(ao3Id: 1, chapterIndex: 2, paragraphIndex: 5,
                                           title: "T", author: "A",
                                           updatedAt: Date(timeIntervalSinceNow: -3600)))
        cloudDevice.insert(ReadingProgress(ao3Id: 2, chapterIndex: 9, paragraphIndex: 0,
                                           title: "U", author: "A", updatedAt: .now))
        try cloudDevice.save()
        iCloudSyncManager.shared.backupToiCloud(context: cloudDevice)

        // This device is ahead on work 1 (ch 7) and behind on work 2 (ch 1).
        let device = try makeContext()
        device.insert(ReadingProgress(ao3Id: 1, chapterIndex: 7, paragraphIndex: 0,
                                      title: "T", author: "A", updatedAt: .now))
        device.insert(ReadingProgress(ao3Id: 2, chapterIndex: 1, paragraphIndex: 0,
                                      title: "U", author: "A",
                                      updatedAt: Date(timeIntervalSinceNow: -7200)))
        try device.save()

        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: device)
        XCTAssertTrue(success)
        let all = try device.fetch(FetchDescriptor<ReadingProgress>())
        XCTAssertEqual(all.first(where: { $0.ao3Id == 1 })?.chapterIndex, 7)  // kept local
        XCTAssertEqual(all.first(where: { $0.ao3Id == 2 })?.chapterIndex, 9)  // took cloud
    }

    /// Star/follow flags and folder assignments made locally since the last
    /// backup survive a restore (OR/union semantics), and the subscription
    /// notification baseline never regresses to re-fire old alerts.
    func test_restoreKeepsLocalFlagsFoldersAndSeenBaseline() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        // The cloud copy predates this device's star, folder, and seen-count.
        let cloudDevice = try makeContext()
        let cloudWork = Work(ao3Id: 1, title: "T", authorName: "A")
        cloudWork.lastSeenChapterCount = 3
        cloudDevice.insert(cloudWork)
        try cloudDevice.save()
        iCloudSyncManager.shared.backupToiCloud(context: cloudDevice)

        let device = try makeContext()
        let folder = CustomFolder(name: "Faves")
        device.insert(folder)
        let local = Work(ao3Id: 1, title: "T", authorName: "A")
        local.isStarred = true
        local.isFollowed = true
        local.lastSeenChapterCount = 8
        device.insert(local)
        local.folders.append(folder)
        try device.save()

        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: device)
        XCTAssertTrue(success)
        let work = try XCTUnwrap(try device.fetch(FetchDescriptor<Work>()).first)
        XCTAssertTrue(work.isStarred)
        XCTAssertTrue(work.isFollowed)
        XCTAssertEqual(work.lastSeenChapterCount, 8)
        XCTAssertEqual(work.folders.map(\.name), ["Faves"])
    }

    /// Only works with restored chapter text (i.e. downloaded on the device
    /// that made the backup) and no local EPUB file are offered for
    /// re-download after a restore.
    func test_redownloadCandidatesRequireChapters() throws {
        let ctx = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 987654321, chapters: 2), into: ctx)  // downloaded
        ctx.insert(Work(ao3Id: 987654322, title: "Metadata only", authorName: "A"))          // follow
        try ctx.save()
        XCTAssertEqual(RestoreDownloadCenter.redownloadCandidates(in: ctx), [987654321])
    }

    /// A folder's "Download All" queues the stories without an EPUB, in the
    /// folder's on-screen order, each once.
    func test_folderDownloadCandidatesSkipDownloadedKeepOrder() {
        let works = [3, 1, 2, 1].map { Work(ao3Id: $0, title: "W\($0)", authorName: "A") }
        let ids = RestoreDownloadCenter.folderDownloadCandidates(works, isDownloaded: { $0 == 2 })
        XCTAssertEqual(ids, [3, 1])
        XCTAssertEqual(RestoreDownloadCenter.folderDownloadCandidates(works, isDownloaded: { _ in true }), [])
    }

    func test_downloadProgressBookkeeping() {
        let start = RestoreDownloadCenter.Progress(done: 0, failed: 0, total: 3, finished: false)
        let tally = start.recording(succeeded: true).recording(succeeded: false).recording(succeeded: true)
        XCTAssertEqual(tally, .init(done: 2, failed: 1, total: 3, finished: false))
        XCTAssertEqual(tally.finishing(), .init(done: 2, failed: 1, total: 3, finished: true))
    }

    @MainActor
    private final class QueueRecorder {
        var attempted: [Int] = []
        var downloaded: [Int] = []
        var reports: [RestoreDownloadCenter.Progress] = []
    }

    /// A failed story is counted and skipped; the rest still download.
    func test_downloadQueueSkipsFailures() async {
        let rec = QueueRecorder()
        let result = await RestoreDownloadCenter.runQueue(ids: [1, 2, 3], download: { id in
            rec.attempted.append(id)
            if id == 2 { throw URLError(.badServerResponse) }
            rec.downloaded.append(id)
        }, report: { rec.reports.append($0) })
        XCTAssertEqual(rec.attempted, [1, 2, 3])
        XCTAssertEqual(rec.downloaded, [1, 3])
        XCTAssertEqual(rec.reports.count, 3)
        XCTAssertEqual(result, .init(done: 2, failed: 1, total: 3, finished: true))
    }

    /// Cancelling mid-run stops before the next story and undoes nothing:
    /// the stories that finished stay downloaded.
    func test_downloadQueueCancelKeepsFinished() async {
        let rec = QueueRecorder()
        let task = Task { @MainActor in
            await RestoreDownloadCenter.runQueue(ids: [1, 2, 3], download: { id in
                rec.attempted.append(id)
                rec.downloaded.append(id)
                if id == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }, report: { rec.reports.append($0) })
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(rec.attempted, [1, 2])
        XCTAssertEqual(rec.downloaded, [1, 2])
        XCTAssertEqual(rec.reports, [.init(done: 1, failed: 0, total: 3, finished: false)])
    }

    /// Restore's stat merge must keep totalSeconds == Σ daySeconds: per-day
    /// maxima from two devices (iPhone read Monday, iPad Tuesday) sum past
    /// either device's own total, and taking only max(totals) left All Time
    /// showing less than a single Year period.
    func test_restoreStatMergeKeepsTotalAtLeastSumOfDays() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        // The iPhone backed up 1000s read on Monday…
        let phone = try makeContext()
        phone.insert(ReadingStat(ao3Id: 7, title: "T", author: "A",
                                 totalSeconds: 1000, daySeconds: ["2026-06-01": 1000]))
        try phone.save()
        iCloudSyncManager.shared.backupToiCloud(context: phone)

        // …the iPad read 2000s on Tuesday, then restores.
        let pad = try makeContext()
        pad.insert(ReadingStat(ao3Id: 7, title: "T", author: "A",
                               totalSeconds: 2000, daySeconds: ["2026-06-02": 2000]))
        try pad.save()
        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: pad)
        XCTAssertTrue(success)

        let row = try XCTUnwrap(try pad.fetch(FetchDescriptor<ReadingStat>()).first)
        XCTAssertEqual(row.daySeconds["2026-06-01"] ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(row.daySeconds["2026-06-02"] ?? 0, 2000, accuracy: 0.001)
        XCTAssertEqual(row.totalSeconds, 3000, accuracy: 0.001,
                       "total must be Σ daySeconds (3000), not max of device totals (2000)")
    }

    func test_profileDeletionTombstonesAndSurvivesMerge() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let base = ReaderProfile.defaultProfiles[0]
        let night = readerProfile(name: "Night", theme: "dracula", fontSize: 20)

        let original = ReaderProfile.saveProfiles([base, night], previousJSON: "", now: t0)
        // A stale copy that predates the sync stamps entirely.
        let legacyCloud = ReaderProfile.saveProfiles([base, night])

        // Deleting keeps the profile in the stored JSON as a hidden tombstone.
        let afterDelete = ReaderProfile.saveProfiles([base], previousJSON: original, now: t1)
        XCTAssertEqual(ReaderProfile.loadProfiles(from: afterDelete).map(\.name), [base.name])
        let tombstone = ReaderProfile.decodeProfiles(from: afterDelete)?.first { $0.name == "Night" }
        XCTAssertEqual(tombstone?.deletedAt, t1.timeIntervalSince1970)

        // The deletion beats stale live copies in both merge directions
        // (publishLocalProfiles merges local into cloud, syncCloudToLocal the
        // reverse), including copies stamped before the delete.
        for merged in [
            ReaderProfile.mergedProfiles(localJSON: legacyCloud, incomingJSON: afterDelete, now: t1),
            ReaderProfile.mergedProfiles(localJSON: afterDelete, incomingJSON: legacyCloud, now: t1),
            ReaderProfile.mergedProfiles(localJSON: original, incomingJSON: afterDelete, now: t1),
        ] {
            XCTAssertFalse(ReaderProfile.loadProfiles(from: merged).contains { $0.name == "Night" })
            XCTAssertTrue(ReaderProfile.decodeProfiles(from: merged)?.contains { $0.name == "Night" && $0.isDeleted } ?? false)
        }
    }

    func test_profileRecreateAfterDeleteBeatsTombstone() {
        let base = ReaderProfile.defaultProfiles[0]
        let night = readerProfile(name: "Night", theme: "dracula", fontSize: 20)

        let original = ReaderProfile.saveProfiles([base, night], previousJSON: "", now: Date(timeIntervalSince1970: 1_000))
        let deleted = ReaderProfile.saveProfiles([base], previousJSON: original, now: Date(timeIntervalSince1970: 2_000))
        let recreated = ReaderProfile.saveProfiles([base, night], previousJSON: deleted, now: Date(timeIntervalSince1970: 3_000))

        for merged in [
            ReaderProfile.mergedProfiles(localJSON: deleted, incomingJSON: recreated),
            ReaderProfile.mergedProfiles(localJSON: recreated, incomingJSON: deleted),
        ] {
            XCTAssertTrue(ReaderProfile.loadProfiles(from: merged).contains { $0.name == "Night" })
        }

        // Re-saving an unchanged profile must not bump its stamp, or a routine
        // save on one device would override edits and deletes made elsewhere.
        let baseEntry = ReaderProfile.decodeProfiles(from: recreated)?.first { $0.name == base.name }
        XCTAssertEqual(baseEntry?.updatedAt, 1_000)
    }

    func test_profileTombstoneExpires() {
        let base = ReaderProfile.defaultProfiles[0]
        let night = readerProfile(name: "Night", theme: "dracula", fontSize: 20)

        let original = ReaderProfile.saveProfiles([base, night], previousJSON: "", now: Date(timeIntervalSince1970: 1_000))
        let deleted = ReaderProfile.saveProfiles([base], previousJSON: original, now: Date(timeIntervalSince1970: 2_000))

        let beyond = Date(timeIntervalSince1970: 2_000 + ReaderProfile.tombstoneLifetime + 1)
        let merged = ReaderProfile.mergedProfiles(localJSON: deleted, incomingJSON: deleted, now: beyond)
        XCTAssertFalse(ReaderProfile.decodeProfiles(from: merged)?.contains { $0.name == "Night" } ?? true)

        // The save path prunes expired tombstones too.
        let resaved = ReaderProfile.saveProfiles([base], previousJSON: deleted, now: beyond)
        XCTAssertFalse(ReaderProfile.decodeProfiles(from: resaved)?.contains { $0.name == "Night" } ?? true)

        // Just inside the window the tombstone is still carried.
        let inside = Date(timeIntervalSince1970: 2_000 + ReaderProfile.tombstoneLifetime - 1)
        let carried = ReaderProfile.mergedProfiles(localJSON: deleted, incomingJSON: deleted, now: inside)
        XCTAssertTrue(ReaderProfile.decodeProfiles(from: carried)?.contains { $0.name == "Night" && $0.isDeleted } ?? false)
    }

    func test_profileMergeKeepsNewestEditAndLegacyUnion() {
        let base = ReaderProfile.defaultProfiles[0]
        let night = readerProfile(name: "Night", theme: "dracula", fontSize: 20)
        let original = ReaderProfile.saveProfiles([base, night], previousJSON: "", now: Date(timeIntervalSince1970: 1_000))

        var editedNight = night
        editedNight.fontSizePt = 24
        let edited = ReaderProfile.saveProfiles([base, editedNight], previousJSON: original, now: Date(timeIntervalSince1970: 2_000))

        for merged in [
            ReaderProfile.mergedProfiles(localJSON: original, incomingJSON: edited),
            ReaderProfile.mergedProfiles(localJSON: edited, incomingJSON: original),
        ] {
            XCTAssertEqual(ReaderProfile.loadProfiles(from: merged).first { $0.name == "Night" }?.fontSizePt, 24)
        }

        // Two pre-tombstone copies with no stamps keep the original union
        // behavior: names union and the incoming copy wins a name collision.
        let legacyA = ReaderProfile.saveProfiles([base, night])
        var legacyNight = night
        legacyNight.fontSizePt = 30
        let legacyB = ReaderProfile.saveProfiles([legacyNight, readerProfile(name: "Sepia", theme: "sepia", fontSize: 18)])
        let merged = ReaderProfile.mergedProfiles(localJSON: legacyA, incomingJSON: legacyB)
        let profiles = ReaderProfile.loadProfiles(from: merged)
        XCTAssertEqual(profiles.first { $0.name == "Night" }?.fontSizePt, 30)
        XCTAssertEqual(Set(profiles.map(\.name)), [base.name, "Night", "Sepia"])
    }

    func test_workMatchesSearchQuery() {
        let work = Work(
            ao3Id: 101,
            title: "The Golden Snitch",
            authorName: "GryffindorWriter",
            summary: "A story about quidditch",
            rating: "Teen",
            warnings: ["Graphic Depictions Of Violence"],
            categories: ["F/M"],
            fandoms: ["Harry Potter - J. K. Rowling"],
            characters: ["Harry Potter", "Hermione Granger"],
            relationships: ["Harry Potter/Hermione Granger"],
            freeforms: ["Quidditch", "Enemies to Lovers"]
        )

        // Matching titles
        XCTAssertTrue(work.matches(query: "Golden"))
        XCTAssertTrue(work.matches(query: "snitch")) // Case-insensitive
        XCTAssertTrue(work.matches(query: "  Snitch  ")) // Trimmed whitespaces
        
        // Matching authors
        XCTAssertTrue(work.matches(query: "Gryffindor"))
        
        // Matching fandoms
        XCTAssertTrue(work.matches(query: "Rowling"))
        
        // Matching characters
        XCTAssertTrue(work.matches(query: "Hermione"))
        
        // Matching relationships
        XCTAssertTrue(work.matches(query: "Harry Potter/Hermione Granger"))
        
        // Matching tags/freeforms
        XCTAssertTrue(work.matches(query: "Enemies"))
        
        // Matching warnings & rating
        XCTAssertTrue(work.matches(query: "Teen"))
        XCTAssertTrue(work.matches(query: "Violence"))
        
        // No match
        XCTAssertFalse(work.matches(query: "Snape"))
    }

    // MARK: - Notes and personal tags (RM-009)

    func test_personalTagsParseTrimAndDedupe() {
        XCTAssertEqual(Work.personalTags(from: " for a bad day, reread at Christmas ,,For a Bad Day, "),
                       ["for a bad day", "reread at Christmas"])
        XCTAssertEqual(Work.personalTags(from: "   "), [])
    }

    func test_notesAndPersonalTagsPersist() throws {
        let ctx = try makeContext()
        let work = Work(ao3Id: 1, title: "T", authorName: "A")
        ctx.insert(work)
        XCTAssertNil(work.note)
        XCTAssertEqual(work.personalTags, [])

        work.setNotes(note: "  Comfort read  ", tagsText: "for a bad day, reread at Christmas")
        try ctx.save()
        let saved = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Work>()).first)
        XCTAssertEqual(saved.note, "Comfort read")
        XCTAssertEqual(saved.personalTags, ["for a bad day", "reread at Christmas"])

        // A blank note is stored as nil, not "".
        saved.setNotes(note: "   ", tagsText: "")
        try ctx.save()
        XCTAssertNil(saved.note)
        XCTAssertEqual(saved.personalTags, [])
    }

    func test_librarySearchMatchesNoteAndPersonalTags() {
        let work = Work(ao3Id: 1, title: "Golden Snitch", authorName: "A")
        work.setNotes(note: "Recommended by Sam", tagsText: "reread at Christmas")
        XCTAssertTrue(work.matches(query: "sam"))
        XCTAssertTrue(work.matches(query: "Christmas"))
        XCTAssertFalse(work.matches(query: "birthday"))
        XCTAssertFalse(Work(ao3Id: 2, title: "Other", authorName: "B").matches(query: "christmas"))
    }

    func test_noteAndTagMerge() {
        XCTAssertEqual(iCloudSyncManager.mergedNote(local: nil, other: "cloud"), "cloud")
        XCTAssertEqual(iCloudSyncManager.mergedNote(local: "  ", other: "cloud"), "cloud")
        XCTAssertEqual(iCloudSyncManager.mergedNote(local: "local", other: nil), "local")
        XCTAssertEqual(iCloudSyncManager.mergedNote(local: "local", other: "cloud"), "local")
        XCTAssertNil(iCloudSyncManager.mergedNote(local: " ", other: nil))
        XCTAssertEqual(iCloudSyncManager.mergedPersonalTags(local: [], other: ["x"]), ["x"])
        XCTAssertEqual(iCloudSyncManager.mergedPersonalTags(local: [], other: nil), [])
        XCTAssertEqual(iCloudSyncManager.mergedPersonalTags(local: ["y"], other: ["x"]), ["y"])

        // With edit stamps, the newest side wins outright, a clear included.
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let filled = WorkNotes(note: "old", personalTags: ["t"], updatedAt: older)
        let cleared = WorkNotes(note: nil, personalTags: [], updatedAt: newer)
        XCTAssertEqual(iCloudSyncManager.mergedNotes(local: filled, other: cleared), cleared)
        XCTAssertEqual(iCloudSyncManager.mergedNotes(local: cleared, other: filled), cleared)
        // A stamped side beats an unstamped (never edited) one.
        let never = WorkNotes(note: nil, personalTags: [], updatedAt: nil)
        XCTAssertEqual(iCloudSyncManager.mergedNotes(local: never, other: filled), filled)
        // Ties go to local.
        let same = WorkNotes(note: "other", personalTags: [], updatedAt: older)
        XCTAssertEqual(iCloudSyncManager.mergedNotes(local: filled, other: same), filled)
        // Neither stamped: the forward-only fallback.
        XCTAssertEqual(
            iCloudSyncManager.mergedNotes(local: never, other: WorkNotes(note: "x", personalTags: ["y"], updatedAt: nil)),
            WorkNotes(note: "x", personalTags: ["y"], updatedAt: nil))
    }

    func test_setNotesStampsOnlyRealChanges() {
        let work = Work(ao3Id: 1, title: "T", authorName: "A")
        let t1 = Date(timeIntervalSince1970: 1_000)
        work.setNotes(note: "a", tagsText: "x", now: t1)
        XCTAssertEqual(work.notesUpdatedAt, t1)
        work.setNotes(note: " a ", tagsText: "x,", now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(work.notesUpdatedAt, t1, "saving unchanged text must not look like a newer edit")
    }

    /// Clearing a note on one device reaches the others: the newer, empty
    /// value replaces the note in the backup and then on restore.
    func test_clearedNoteSyncsInsteadOfComingBack() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        // The pad wrote a note an hour ago and backed it up.
        let pad = try makeContext()
        let padWork = Work(ao3Id: 1, title: "T", authorName: "A")
        padWork.setNotes(note: "old note", tagsText: "old", now: Date(timeIntervalSinceNow: -3600))
        pad.insert(padWork)
        try pad.save()
        iCloudSyncManager.shared.backupToiCloud(context: pad)

        // The phone restored it, cleared it just now, and backed up.
        let phone = try makeContext()
        let phoneRestored = await iCloudSyncManager.shared.restoreFromiCloud(context: phone)
        XCTAssertTrue(phoneRestored)
        let phoneWork = try XCTUnwrap(try phone.fetch(FetchDescriptor<Work>()).first)
        XCTAssertEqual(phoneWork.note, "old note")
        phoneWork.setNotes(note: "", tagsText: "")
        try phone.save()
        iCloudSyncManager.shared.backupToiCloud(context: phone)

        let backedUp = try XCTUnwrap(decodeBackup(at: url).works.first)
        XCTAssertNil(backedUp.note)
        XCTAssertEqual(backedUp.personalTags, [])

        // The pad's next restore clears its copy too.
        let padRestored = await iCloudSyncManager.shared.restoreFromiCloud(context: pad)
        XCTAssertTrue(padRestored)
        XCTAssertNil(padWork.note)
        XCTAssertEqual(padWork.personalTags, [])
    }

    /// A device that never edited the note doesn't erase another device's
    /// note in the backup file, and a later edit replaces it.
    func test_backupMergeKeepsNotesUntilANewerEdit() throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        let phone = try makeContext()
        let noted = Work(ao3Id: 1, title: "T", authorName: "A")
        noted.setNotes(note: "phone note", tagsText: "comfort")
        phone.insert(noted)
        try phone.save()
        iCloudSyncManager.shared.backupToiCloud(context: phone)

        let pad = try makeContext()
        pad.insert(Work(ao3Id: 1, title: "T", authorName: "A"))
        try pad.save()
        iCloudSyncManager.shared.backupToiCloud(context: pad)

        var work = try XCTUnwrap(decodeBackup(at: url).works.first)
        XCTAssertEqual(work.note, "phone note")
        XCTAssertEqual(work.personalTags, ["comfort"])

        let mac = try makeContext()
        let macWork = Work(ao3Id: 1, title: "T", authorName: "A")
        macWork.setNotes(note: "mac note", tagsText: "angst")
        mac.insert(macWork)
        try mac.save()
        iCloudSyncManager.shared.backupToiCloud(context: mac)

        work = try XCTUnwrap(decodeBackup(at: url).works.first)
        XCTAssertEqual(work.note, "mac note")
        XCTAssertEqual(work.personalTags, ["angst"])
    }

    /// Restore fills a never-edited note and tags from the backup, and keeps
    /// this device's own when they were edited after the backup's.
    func test_restoreKeepsNewerLocalNotesAndFillsEmptyOnes() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        let cloudDevice = try makeContext()
        for id in 1...2 {
            let w = Work(ao3Id: id, title: "T\(id)", authorName: "A")
            w.setNotes(note: "cloud note", tagsText: "cloud tag")
            cloudDevice.insert(w)
        }
        try cloudDevice.save()
        iCloudSyncManager.shared.backupToiCloud(context: cloudDevice)

        let device = try makeContext()
        let own = Work(ao3Id: 1, title: "T1", authorName: "A")
        own.setNotes(note: "my note", tagsText: "my tag")
        device.insert(own)
        device.insert(Work(ao3Id: 2, title: "T2", authorName: "A"))
        try device.save()

        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: device)
        XCTAssertTrue(success)
        let all = try device.fetch(FetchDescriptor<Work>())
        let first = try XCTUnwrap(all.first(where: { $0.ao3Id == 1 }))
        let second = try XCTUnwrap(all.first(where: { $0.ao3Id == 2 }))
        XCTAssertEqual(first.note, "my note")
        XCTAssertEqual(first.personalTags, ["my tag"])
        XCTAssertEqual(second.note, "cloud note")
        XCTAssertEqual(second.personalTags, ["cloud tag"])
    }

    /// Backups written before notes and personal tags existed have neither
    /// key; they must still decode and restore without touching local notes.
    func test_oldBackupWithoutNoteFieldsDecodesAndRestores() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }

        let old = try makeContext()
        old.insert(Work(ao3Id: 1, title: "T", authorName: "A"))
        try old.save()
        iCloudSyncManager.shared.backupToiCloud(context: old)

        // Strip the new keys, as an older app version would have written it.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var works = try XCTUnwrap(json["works"] as? [[String: Any]])
        works = works.map { var w = $0; w.removeValue(forKey: "note"); w.removeValue(forKey: "personalTags"); return w }
        json["works"] = works
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let decoded = try XCTUnwrap(decodeBackup(at: url).works.first)
        XCTAssertNil(decoded.note)
        XCTAssertNil(decoded.personalTags)

        let device = try makeContext()
        let local = Work(ao3Id: 1, title: "T", authorName: "A")
        local.setNotes(note: "keep me", tagsText: "keep")
        device.insert(local)
        try device.save()
        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: device)
        XCTAssertTrue(success)
        let work = try XCTUnwrap(try device.fetch(FetchDescriptor<Work>()).first)
        XCTAssertEqual(work.note, "keep me")
        XCTAssertEqual(work.personalTags, ["keep"])
    }

    func test_workMultiFolderPersistence() throws {
        let ctx = try makeContext()
        let work = Work(ao3Id: 999, title: "Multi Folder Story", authorName: "author")
        ctx.insert(work)

        let folder1 = CustomFolder(name: "Folder A")
        let folder2 = CustomFolder(name: "Folder B")
        ctx.insert(folder1)
        ctx.insert(folder2)

        work.folders.append(folder1)
        work.folders.append(folder2)

        try ctx.save()

        // Fetch back and assert
        let fetched = try ctx.fetch(FetchDescriptor<Work>()).first
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.folders.count, 2)
        XCTAssertTrue(fetched?.folders.contains(where: { $0.name == "Folder A" }) ?? false)
        XCTAssertTrue(fetched?.folders.contains(where: { $0.name == "Folder B" }) ?? false)

        // Test inverse relationship
        let fetchedFolder = try ctx.fetch(FetchDescriptor<CustomFolder>(predicate: #Predicate { $0.name == "Folder A" })).first
        XCTAssertNotNil(fetchedFolder)
        XCTAssertEqual(fetchedFolder?.works.count, 1)
        XCTAssertEqual(fetchedFolder?.works.first?.ao3Id, 999)
    }

    // MARK: - Subscription list sync (fail closed)

    private func seedSubscriptionRecords(into ctx: ModelContext) {
        let rec1 = SubscriptionRecord(key: "work:1", kind: "work", displayName: "Fic One")
        rec1.lastSeenChapterCount = 5
        ctx.insert(rec1)
        ctx.insert(SubscriptionRecord(key: "series:9", kind: "series", displayName: "Saga"))
        try? ctx.save()
    }

    // An empty fetch (stale session, markup drift) must never prune the
    // stored records — a wrong delete also destroys the lastSeenChapterCount
    // baselines that new-chapter notifications compare against.
    func test_syncSubscriptionList_emptyFetchKeepsRecords() async throws {
        let ctx = try makeContext()
        seedSubscriptionRecords(into: ctx)
        let client = StubAO3Client()
        client.subscriptionsResponse = []

        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader")
        _ = try await poller.syncSubscriptionList()

        let remaining = try ctx.fetch(FetchDescriptor<SubscriptionRecord>())
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(remaining.first(where: { $0.key == "work:1" })?.lastSeenChapterCount, 5)
    }

    // A non-empty fetch is trusted: records missing from it are pruned and
    // new ones inserted.
    func test_syncSubscriptionList_nonEmptyFetchPrunesStaleRecords() async throws {
        let ctx = try makeContext()
        seedSubscriptionRecords(into: ctx)
        let client = StubAO3Client()
        client.subscriptionsResponse = [
            AO3Subscription(kind: .work, resourceId: "1", title: "Fic One", author: "alice"),
            AO3Subscription(kind: .user, resourceId: "carol", title: "carol", author: nil),
        ]

        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader")
        _ = try await poller.syncSubscriptionList()

        let remaining = try ctx.fetch(FetchDescriptor<SubscriptionRecord>())
        XCTAssertEqual(Set(remaining.map(\.key)), ["work:1", "user:carol"])
    }
}

/// RM-003: the reading-time estimate's pace (fallback and clamping) and its
/// formatting at no words, under a minute, minutes and hours.
@MainActor
final class ReadingSpeedTests: XCTestCase {
    private func snap(_ id: Int, words: Int, seconds: Double, progress: Double = 1.0) -> ReadingStatSnapshot {
        ReadingStatSnapshot(ao3Id: id, title: "", author: "A",
                            fandoms: [], categories: [], relationships: [],
                            rating: "", wordCount: words,
                            firstReadAt: .now, lastReadAt: .now,
                            totalSeconds: seconds, daySeconds: [:],
                            maxProgress: progress, workIsComplete: false)
    }

    func test_wordsPerMinute_fallsBackUntilThreeFinishedTimedWorks() {
        XCTAssertEqual(ReadingSpeed.wordsPerMinute([]), 250)
        // Two finished works at 300 wpm aren't enough yet.
        let two = [snap(1, words: 3_000, seconds: 600), snap(2, words: 3_000, seconds: 600)]
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(two), 250)
        // Unfinished and zero-time (backfilled) works don't count toward the three.
        let padded = two + [snap(3, words: 3_000, seconds: 600, progress: 0.5),
                            snap(4, words: 3_000, seconds: 0)]
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(padded), 250)
        // A third finished, timed work switches to the personal pace.
        let three = two + [snap(5, words: 3_000, seconds: 600)]
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(three), 300, accuracy: 0.001)
    }

    func test_wordsPerMinute_isTheMedianWorksPace() {
        // 400, 500 and 200 wpm → 400; an unfinished work's time doesn't count.
        let snaps = [snap(1, words: 2_000, seconds: 300), snap(2, words: 4_000, seconds: 480),
                     snap(3, words: 6_000, seconds: 1_800), snap(4, words: 50_000, seconds: 36_000, progress: 0.1)]
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(snaps), 400, accuracy: 0.001)
        // An even count averages the middle two: 200, 400, 500, 600 → 450.
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(snaps + [snap(5, words: 6_000, seconds: 600)]), 450, accuracy: 0.001)
    }

    func test_wordsPerMinute_ignoresASkimAndARereadSwing() {
        let honest = (1...3).map { snap($0, words: 5_000, seconds: 1_200) }   // 250 wpm each
        // A 150k-word work jumped to the end in 5 minutes, and a re-read
        // that doubled a work's time, leave the pace where it was.
        let skimmed = snap(4, words: 150_000, seconds: 300)
        let reread = snap(5, words: 5_000, seconds: 4_800)
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(honest + [skimmed]), 250, accuracy: 0.001)
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(honest + [skimmed, reread]), 250, accuracy: 0.001)
    }

    func test_wordsPerMinute_isClamped() {
        let fast = (1...3).map { snap($0, words: 10_000, seconds: 60) }      // 10,000 wpm
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(fast), 600)
        let slow = (1...3).map { snap($0, words: 1_000, seconds: 3_600) }    // ~17 wpm
        XCTAssertEqual(ReadingSpeed.wordsPerMinute(slow), 120)
    }

    func test_estimate_formatting() {
        XCTAssertNil(ReadingSpeed.estimate(words: 0))
        XCTAssertNil(ReadingSpeed.estimate(words: -5))
        XCTAssertEqual(ReadingSpeed.estimate(words: 100), "<1 min")          // 0.4 min
        XCTAssertEqual(ReadingSpeed.estimate(words: 250), "~1 min")
        XCTAssertEqual(ReadingSpeed.estimate(words: 11_250), "~45 min")
        XCTAssertEqual(ReadingSpeed.estimate(words: 14_900), "~1 hr")        // 59.6 rounds up
        XCTAssertEqual(ReadingSpeed.estimate(words: 15_000), "~1 hr")
        XCTAssertEqual(ReadingSpeed.estimate(words: 31_250), "~2 hr 5 min")
        XCTAssertEqual(ReadingSpeed.estimate(words: 200_000), "~13 hr")      // 13 hr 20 min, minutes dropped
        // The pace changes the estimate.
        XCTAssertEqual(ReadingSpeed.estimate(words: 12_000, wordsPerMinute: 400), "~30 min")
    }

    func test_spokenEstimate() {
        XCTAssertNil(ReadingSpeed.spokenEstimate(words: 0))
        XCTAssertEqual(ReadingSpeed.spokenEstimate(words: 100), "Under a minute to read")
        XCTAssertEqual(ReadingSpeed.spokenEstimate(words: 250), "About 1 minute to read")
        XCTAssertEqual(ReadingSpeed.spokenEstimate(words: 15_000), "About 1 hour to read")
        XCTAssertEqual(ReadingSpeed.spokenEstimate(words: 31_250), "About 2 hours 5 minutes to read")
    }
}

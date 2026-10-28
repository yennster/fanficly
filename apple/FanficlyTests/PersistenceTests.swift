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
            ReadingStat.self, BlockedTerm.self, HiddenWork.self, SavedFilter.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

    func test_recordViewKeepsStoryDetailsForTheRow() throws {
        let ctx = try makeContext()
        let summary = payload(id: 7, chapters: 3).summary
        WorkPersistence.recordView(summary: summary, into: ctx)
        let entry = try XCTUnwrap(try ctx.fetch(FetchDescriptor<RecentlyViewed>()).first)
        XCTAssertTrue(entry.hasDetails)
        XCTAssertEqual(entry.workSummary, summary)

        // An entry recorded before details were kept shows what it has.
        let legacy = RecentlyViewed(ao3Id: 8, title: "Old", author: "A", fandom: "F")
        XCTAssertFalse(legacy.hasDetails)
        XCTAssertEqual(legacy.workSummary.fandoms, ["F"])
        XCTAssertEqual(legacy.workSummary.wordCount, 0)
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
        
        // This device's own keys: the tests run on an iPhone, an iPad and a Mac.
        let themeKey = ReaderProfile.deviceKey("reader.theme")
        let fontSizeKey = ReaderProfile.deviceKey("reader.fontSizePt")
        let profileKey = ReaderProfile.deviceActiveProfileKey

        // 1. Set some settings in UserDefaults
        let defaults = UserDefaults.standard
        defer {
            [
                "reader.theme",
                "reader.fontFamily",
                "reader.width",
                "reader.fontSizePt",
                "reader.profiles",
                themeKey,
                profileKey,
                fontSizeKey,
                "content.filterMatureExplicit"
            ].forEach { defaults.removeObject(forKey: $0) }
        }
        defaults.set("sepia", forKey: "reader.theme")
        defaults.set("rounded", forKey: "reader.fontFamily")
        defaults.set("wide", forKey: "reader.width")
        defaults.set(22.0, forKey: "reader.fontSizePt")
        defaults.set(true, forKey: "content.filterMatureExplicit")
        
        // Device-specific settings
        defaults.set("dracula", forKey: themeKey)
        defaults.set("compact", forKey: profileKey)
        defaults.set(18.0, forKey: fontSizeKey)

        let macProfile = readerProfile(name: "Mac", theme: "dracula", fontSize: 24.0)
        defaults.set(ReaderProfile.saveProfiles([ReaderProfile.defaultProfiles[0], macProfile]),
                     forKey: "reader.profiles")
        
        // 2. Perform backup
        let syncManager = iCloudSyncManager.shared
        syncManager.backupToiCloud(context: ctx)
        
        // 3. Reset settings in UserDefaults, all but one: a setting this
        // device has is its own, so restore leaves it alone (#133).
        defaults.removeObject(forKey: "reader.theme")
        defaults.removeObject(forKey: "reader.fontFamily")
        defaults.removeObject(forKey: "reader.width")
        defaults.removeObject(forKey: "reader.fontSizePt")
        defaults.removeObject(forKey: "content.filterMatureExplicit")
        
        defaults.removeObject(forKey: themeKey)
        defaults.removeObject(forKey: profileKey)
        defaults.set(15.0, forKey: fontSizeKey)

        let phoneProfile = readerProfile(name: "iPhone", theme: "system", fontSize: 20.0)
        defaults.set(ReaderProfile.saveProfiles([ReaderProfile.defaultProfiles[0], phoneProfile]),
                     forKey: "reader.profiles")
        
        XCTAssertNil(defaults.string(forKey: "reader.theme"))
        XCTAssertNil(defaults.string(forKey: themeKey))
        
        // 4. Restore from backup
        let success = await syncManager.restoreFromiCloud(context: ctx)
        XCTAssertTrue(success)
        
        // 5. Verify the missing ones are restored and the set one is kept
        XCTAssertEqual(defaults.string(forKey: "reader.theme"), "sepia")
        XCTAssertEqual(defaults.string(forKey: "reader.fontFamily"), "rounded")
        XCTAssertEqual(defaults.string(forKey: "reader.width"), "wide")
        XCTAssertEqual(defaults.double(forKey: "reader.fontSizePt"), 22.0)
        XCTAssertTrue(defaults.bool(forKey: "content.filterMatureExplicit"))
        
        XCTAssertEqual(defaults.string(forKey: themeKey), "dracula")
        XCTAssertEqual(defaults.string(forKey: profileKey), "compact")
        XCTAssertEqual(defaults.double(forKey: fontSizeKey), 15.0)

        let restoredProfiles = ReaderProfile.loadProfiles(from: defaults.string(forKey: "reader.profiles") ?? "")
        XCTAssertEqual(restoredProfiles.first(where: { $0.name == "Mac" })?.fontSizePt, 24.0)
        XCTAssertEqual(restoredProfiles.first(where: { $0.name == "iPhone" })?.fontSizePt, 20.0)
    }

    // MARK: - Per-device settings across devices (#133)

    private func settingsBackup(_ json: String) throws -> SettingsBackup {
        try JSONDecoder().decode(SettingsBackup.self, from: Data(json.utf8))
    }

    private func seededKeys(_ settings: SettingsBackup, device: String, has local: Set<String> = []) -> [String: String] {
        var seeded: [String: String] = [:]
        for seed in iCloudSyncManager.settingsToSeed(from: settings, deviceSuffix: device, isSet: local.contains) {
            seeded[seed.key] = "\(seed.value)"
        }
        return seeded
    }

    func test_restoreSeedsOnlyThisDevicesMissingSettings() throws {
        let backup = try settingsBackup("""
            {"theme":"sepia","ttsRate":0.5,"filterMatureExplicit":true,"ageConfirmed":true,
             "activeProfilePad":"Couch","activeProfilePhone":"Train",
             "fontSizePtPad":16,"fontSizePtPhone":14,"fontSizePtMac":18,"boldTextPad":true,
             "profiles":"[]"}
            """)

        // A fresh iPad takes the shared keys and its own, never the iPhone's or the Mac's.
        XCTAssertEqual(seededKeys(backup, device: "Pad"), [
            "reader.theme": "sepia",
            "reader.ttsRate": "0.5",
            "content.filterMatureExplicit": "true",
            "content.ageConfirmed": "true",
            "reader.activeProfile.pad": "Couch",
            "reader.fontSizePt.pad": "16.0",
            "reader.boldText.pad": "true",
        ])
        XCTAssertEqual(seededKeys(backup, device: "Phone")["reader.fontSizePt.phone"], "14.0")
        XCTAssertEqual(seededKeys(backup, device: "Mac")["reader.fontSizePt.mac"], "18.0")

        // An iPad that already set them keeps its own.
        let seeded = seededKeys(backup, device: "Pad",
                                has: ["reader.fontSizePt.pad", "content.filterMatureExplicit", "reader.activeProfile.pad"])
        XCTAssertNil(seeded["reader.fontSizePt.pad"])
        XCTAssertNil(seeded["content.filterMatureExplicit"])
        XCTAssertNil(seeded["reader.activeProfile.pad"])
        XCTAssertEqual(seeded["reader.boldText.pad"], "true")
    }

    func test_settingsMergeKeepsTheFilesValuesForOtherDevices() throws {
        let cloud = try settingsBackup(#"{"fontSizePtPad":16,"themePad":"night","themeMac":"sepia","ttsRate":0.4}"#)
        // This iPhone holds stale copies of the iPad's keys from an earlier restore.
        let local = try settingsBackup(#"{"fontSizePtPad":14,"themePad":"day","boldTextPad":true,"fontSizePtPhone":20,"ttsRate":0.6}"#)

        let merged = try XCTUnwrap(iCloudSyncManager.mergedSettings(local: local, cloud: cloud, deviceSuffix: "Phone"))
        XCTAssertEqual(merged.fontSizePtPad, 16, "the iPad's own value stays")
        XCTAssertEqual(merged.themePad, "night")
        XCTAssertEqual(merged.themeMac, "sepia")
        XCTAssertNil(merged.boldTextPad, "another device's keys only ever come from the file")
        XCTAssertEqual(merged.fontSizePtPhone, 20, "this device's own key wins")
        XCTAssertEqual(merged.ttsRate, 0.6, "a shared key takes this device's value")
        XCTAssertNil(iCloudSyncManager.mergedSettings(local: nil, cloud: nil, deviceSuffix: "Phone"))
        XCTAssertEqual(iCloudSyncManager.mergedSettings(local: nil, cloud: cloud, deviceSuffix: "Phone")?.themePad, "night")
        // With no file yet, only this device's own and shared keys are written.
        let first = try XCTUnwrap(iCloudSyncManager.mergedSettings(local: local, cloud: nil, deviceSuffix: "Phone"))
        XCTAssertNil(first.fontSizePtPad)
        XCTAssertEqual(first.fontSizePtPhone, 20)
    }

    /// The issue's example: the iPad sets 16 pt and backs up, the iPhone
    /// (holding 14 from an earlier restore) backs up, and the iPad's next
    /// restore keeps 16.
    func test_aNewerSettingOnOneDeviceSurvivesAnotherDevicesBackupAndRestore() throws {
        let pad = try settingsBackup(#"{"fontSizePtPad":16,"filterMatureExplicit":true,"activeProfilePad":"Couch"}"#)
        let phone = try settingsBackup(#"{"fontSizePtPad":14,"fontSizePtPhone":20,"filterMatureExplicit":false,"activeProfilePad":"Default"}"#)

        let file = try XCTUnwrap(iCloudSyncManager.mergedSettings(local: phone, cloud: pad, deviceSuffix: "Phone"))
        XCTAssertEqual(file.fontSizePtPad, 16)
        XCTAssertEqual(file.activeProfilePad, "Couch")

        let padRestore = seededKeys(file, device: "Pad",
                                    has: ["reader.fontSizePt.pad", "content.filterMatureExplicit", "reader.activeProfile.pad"])
        XCTAssertTrue(padRestore.isEmpty, "the iPad keeps every setting it has: \(padRestore)")
        XCTAssertNil(padRestore["reader.fontSizePt.phone"], "and never takes the iPhone's")
    }

    /// The same through the real backup and restore: this device sets its
    /// text size and backs up, another device's backup holding a stale copy
    /// of it lands in the file, and this device's next restore keeps its own.
    func test_aNewerSettingSurvivesAnotherDevicesBackupThroughTheFile() async throws {
        let url = makeTempBackupURL()
        let defaults = UserDefaults.standard
        let fontSizeKey = ReaderProfile.deviceKey("reader.fontSizePt")
        let fontSizeJSONKey = "fontSizePt" + iCloudSyncManager.backupDeviceSuffix
        let other = iCloudSyncManager.backupDeviceSuffix == "Pad" ? "Phone" : "Pad"
        let originalSize = defaults.object(forKey: fontSizeKey)
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: iCloudSyncManager.previousBackupURL(for: url))
            defaults.set(originalSize, forKey: fontSizeKey)
        }
        let ctx = try makeContext()
        defaults.set(16.0, forKey: fontSizeKey)
        iCloudSyncManager.shared.backupToiCloud(context: ctx)
        XCTAssertNil(iCloudSyncManager.shared.lastBackupFailure)

        // The other device merges its backup, with a stale 14 for this device's key.
        let file = try decodeBackup(at: url)
        let stale = try settingsBackup(#"{"\#(fontSizeJSONKey)":14,"fontSizePt\#(other)":21}"#)
        let otherBackup = LibraryBackup(
            works: file.works, bookmarks: file.bookmarks, subscriptions: file.subscriptions,
            searches: file.searches, progress: file.progress, filters: file.filters, hidden: file.hidden,
            settings: stale, folders: file.folders, stats: file.stats, blocked: file.blocked, timestamp: .now)
        let written = iCloudSyncManager.mergedBackup(local: otherBackup, cloud: file, deviceSuffix: other)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(written).write(to: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fileSettings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertEqual(fileSettings[fontSizeJSONKey] as? Double, 16, "the file keeps this device's value")
        XCTAssertEqual(fileSettings["fontSizePt" + other] as? Double, 21)

        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: ctx)
        XCTAssertTrue(success)
        XCTAssertEqual(defaults.double(forKey: fontSizeKey), 16)
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

    /// On a per-work conflict the fresher metadata wins, and the cloud copy's
    /// chapters survive when the local copy is metadata-only.
    func test_backupMergeFresherMetadataWinsAndKeepsCloudChapters() throws {
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
        let fresher = Work(ao3Id: 1, title: "New Title", authorName: "A")
        fresher.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        b.insert(fresher)
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
        // This device's own theme key (the tests run on an iPhone, an iPad and a Mac).
        let themeKey = ReaderProfile.deviceKey("reader.theme")
        let themeJSONKey = "theme" + iCloudSyncManager.backupDeviceSuffix
        let originalTheme = defaults.object(forKey: themeKey)
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: iCloudSyncManager.previousBackupURL(for: url))
            defaults.set(originalTheme, forKey: themeKey)
        }
        let work = #"""
            "authorName":"A","authorUsername":"","summary":"","rating":"Not Rated","warnings":[],"categories":[],"fandoms":[],"characters":[],"relationships":[],"freeforms":[],"language":"en","wordCount":0,"chapterCount":1,"kudos":0,"hits":0,"bookmarksCount":0,"commentsCount":0,"isComplete":false,"savedAt":"2026-01-01T00:00:00Z","isFollowed":false
            """#
        let windowsFile = """
            {"works":[{"ao3Id":1,"title":"PC Title",\(work),"note":"Old note","notesUpdatedAt":"2026-01-01T00:00:00Z","futureWorkField":"kept","chapters":[{"index":1,"title":"Ch","bodyHTML":"<p>x</p>","futureChapterField":7}]},
                      {"ao3Id":2,"title":"PC Only",\(work),"futureWorkField":"pc only","chapters":[]}],
             "bookmarks":[],"subscriptions":[],"searches":[],"progress":[],"filters":[],"hidden":[{"ao3Id":9,"title":"Nope","hiddenAt":"2026-01-01T00:00:00Z","futureReason":"spoilers"}],
             "settings":{"\(themeJSONKey)":"sepia","themeWindows":"night","activeProfileWindows":"Desk","fontSizePtWindows":19},
             "followedAuthors":[{"username":"writer","displayName":"Writer","followedAt":"2026-01-01T00:00:00Z","knownWorkIds":[1]}],
             "timestamp":"2026-01-01T00:00:00Z"}
            """
        try Data(windowsFile.utf8).write(to: url)

        // This Mac holds work 1 with a newer title and the note cleared later.
        defaults.set("dracula", forKey: themeKey)
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
        XCTAssertEqual(settings[themeJSONKey] as? String, "dracula")
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

        XCTAssertEqual(iCloudSyncManager.shared.clearFromiCloud(), .cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousURL.path))
    }

    /// A backup says what it did, so Sync Now and Settings can tell the user
    /// instead of only printing to the log (#136).
    func test_backupSaysWhatHappened() throws {
        let url = makeTempBackupURL()
        let placeholderURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: placeholderURL)
            try? FileManager.default.removeItem(at: iCloudSyncManager.previousBackupURL(for: url))
        }
        let sync = iCloudSyncManager.shared
        let device = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 1), into: device)

        // Signed out of iCloud: there's nowhere to write.
        XCTAssertEqual(sync.backup(to: nil, context: device), .iCloudUnavailable)
        XCTAssertEqual(sync.lastBackupFailure, BackupOutcome.iCloudUnavailable.failureMessage)
        XCTAssertNotNil(sync.lastBackupFailure)

        // Only a placeholder: nothing is written over it.
        try Data().write(to: placeholderURL)
        XCTAssertEqual(sync.backup(to: url, context: device), .waitingForDownload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(sync.lastBackupFailure)
        try FileManager.default.removeItem(at: placeholderURL)

        // Damaged: left as it is.
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(sync.backup(to: url, context: device), .unreadable)
        XCTAssertNotNil(sync.lastBackupFailure)
        try FileManager.default.removeItem(at: url)

        // The write itself fails (here, its folder doesn't exist).
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing_\(UUID().uuidString)/library_backup.json")
        guard case .failed(let reason) = sync.backup(to: missingFolder, context: device) else {
            return XCTFail("a write that can't happen must report .failed")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(sync.lastBackupFailure, reason)

        // Written: the failure clears.
        XCTAssertEqual(sync.backup(to: url, context: device), .written)
        XCTAssertNil(sync.lastBackupFailure)
        XCTAssertEqual(try decodeBackup(at: url).works.map(\.ao3Id), [1])
    }

    /// Settings shows "iCloud isn't available" only while it isn't: once a
    /// backup location is back, a stale signed-out failure no longer shows.
    func test_backupProblemClearsWhenICloudIsBack() throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }
        let sync = iCloudSyncManager.shared
        let device = try makeContext()
        sync.backup(to: nil, context: device)
        XCTAssertNotNil(sync.lastBackupFailure)
        XCTAssertNil(sync.backupProblem)

        try Data("not json".utf8).write(to: url)
        sync.backupToiCloud(context: device)
        XCTAssertEqual(sync.backupProblem, BackupOutcome.unreadable.failureMessage)
    }

    /// Clear iCloud Data says what really happened (#136).
    func test_clearSaysWhatHappened() throws {
        let url = makeTempBackupURL()
        let placeholderURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: placeholderURL)
        }
        let sync = iCloudSyncManager.shared
        let device = try makeContext()

        XCTAssertEqual(sync.clear(at: nil), .iCloudUnavailable)
        XCTAssertEqual(sync.clear(at: url), .nothingToClear)

        // Only a placeholder: nothing on this device to delete yet.
        try Data().write(to: placeholderURL)
        XCTAssertEqual(sync.clear(at: url), .waitingForDownload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholderURL.path))
        try FileManager.default.removeItem(at: placeholderURL)

        // A real file is deleted, and the failure it caused goes with it.
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(sync.backup(to: url, context: device), .unreadable)
        XCTAssertEqual(sync.clear(at: url), .cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(sync.lastBackupFailure)
    }

    /// What Settings says after Sync Now and Clear iCloud Data.
    func test_syncAndClearResultMessages() {
        XCTAssertNotNil(SettingsView.syncResultMessage(SyncNowResult(restored: false, restoreFailed: false, backup: .written)))
        XCTAssertNotEqual(SettingsView.syncResultMessage(SyncNowResult(restored: true, restoreFailed: false, backup: .written)),
                          SettingsView.syncResultMessage(SyncNowResult(restored: false, restoreFailed: false, backup: .written)))
        XCTAssertNotEqual(SettingsView.syncResultMessage(SyncNowResult(restored: false, restoreFailed: true, backup: .written)),
                          SettingsView.syncResultMessage(SyncNowResult(restored: false, restoreFailed: false, backup: .written)))
        // A backup that didn't write leaves the message to the failure line.
        for outcome in [BackupOutcome.waitingForDownload, .iCloudUnavailable, .unreadable, .failed("disk full")] {
            XCTAssertNil(SettingsView.syncResultMessage(SyncNowResult(restored: false, restoreFailed: false, backup: outcome)))
            // A restore that brought changes in is still mentioned.
            XCTAssertNotNil(SettingsView.syncResultMessage(SyncNowResult(restored: true, restoreFailed: false, backup: outcome)))
            XCTAssertNotNil(outcome.failureMessage)
        }
        XCTAssertNil(BackupOutcome.written.failureMessage)

        let cleared = ClearResultAlert(.cleared, syncTurnedOff: true)
        XCTAssertTrue(cleared.message.contains("Sync is now off"))
        XCTAssertTrue(ClearResultAlert(.cleared, syncTurnedOff: false).message.contains("Sync is still on"))
        XCTAssertEqual(ClearResultAlert(.failed("disk full"), syncTurnedOff: false).message, "disk full")
        XCTAssertNotEqual(ClearResultAlert(.waitingForDownload, syncTurnedOff: false).title, cleared.title)
    }

    /// Backing up a library that hasn't changed since the last backup leaves
    /// the file as it is: no new timestamp, no .prev copy, nothing for iCloud
    /// to upload again. A change still writes, from the background write
    /// the app uses too (#137).
    func test_backupLeavesTheFileAloneWhenNothingChanged() async throws {
        let url = makeTempBackupURL()
        let previousURL = iCloudSyncManager.previousBackupURL(for: url)
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: previousURL)
        }
        let sync = iCloudSyncManager.shared

        let device = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 2), into: device)
        ReadingProgressStore.save(ao3Id: 1, anchor: ReadingAnchor(chapter: 2, paragraph: 3),
                                  title: "Work 1", author: "Author", progress: 0.5, in: device)
        sync.backupToiCloud(context: device)
        let first = try Data(contentsOf: url)
        let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)

        sync.backupToiCloud(context: device)
        await sync.backupInBackground(context: device)
        XCTAssertEqual(try Data(contentsOf: url), first, "an unchanged library must not rewrite the backup")
        XCTAssertEqual(iCloudSyncManager.modificationDate(of: url), longAgo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousURL.path))
        XCTAssertNil(sync.lastBackupFailure)

        ReadingProgressStore.save(ao3Id: 1, anchor: ReadingAnchor(chapter: 2, paragraph: 9),
                                  title: "Work 1", author: "Author", progress: 0.8, in: device)
        await sync.backupInBackground(context: device)
        XCTAssertNotEqual(iCloudSyncManager.modificationDate(of: url), longAgo)
        XCTAssertEqual(try decodeBackup(at: url).progress.first?.paragraphIndex, 9)
        XCTAssertEqual(try Data(contentsOf: previousURL), first)
    }

    /// Only `timestamp` differing doesn't count as a change; anything else does.
    func test_sameBackupContentIgnoresOnlyTheTimestamp() {
        let a = Data(#"{"works":[{"ao3Id":1,"title":"A"}],"timestamp":"2026-01-01T00:00:00Z"}"#.utf8)
        let b = Data(#"{"timestamp":"2026-02-02T00:00:00Z","works":[{"title":"A","ao3Id":1}]}"#.utf8)
        let c = Data(#"{"works":[{"ao3Id":1,"title":"B"}],"timestamp":"2026-01-01T00:00:00Z"}"#.utf8)
        XCTAssertTrue(iCloudSyncManager.sameBackupContent(a, b))
        XCTAssertFalse(iCloudSyncManager.sameBackupContent(a, c))
        XCTAssertFalse(iCloudSyncManager.sameBackupContent(a, Data("not json".utf8)))
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
        XCTAssertEqual(first, SyncNowResult(restored: false, restoreFailed: false, backup: .written))
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
        XCTAssertTrue(second.restored)
        XCTAssertFalse(second.restoreFailed)
        XCTAssertTrue(second.backup.succeeded, "the file already holds the phone's work, so it may be left alone (#137)")
        XCTAssertEqual(try phone.fetch(FetchDescriptor<Work>()).map(\.ao3Id).sorted(), [1, 10, 11])
        XCTAssertEqual(try decodeBackup(at: url).works.count, 3)
        XCTAssertFalse(sync.cloudBackupHasUnappliedChanges)

        // With nothing new, it doesn't restore again, and leaves the file as it is.
        let third = await sync.syncNow(context: phone)
        XCTAssertEqual(third, SyncNowResult(restored: false, restoreFailed: false, backup: .unchanged))
    }

    /// Sync Now reports a restore that couldn't run, as well as the backup
    /// after it (#136).
    func test_syncNowReportsARestoreThatFailed() async throws {
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
        defaults.removeObject(forKey: stampKey)
        let phone = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 1), into: phone)
        try Data("not json".utf8).write(to: url)

        let result = await iCloudSyncManager.shared.syncNow(context: phone)
        XCTAssertEqual(result, SyncNowResult(restored: false, restoreFailed: true, backup: .unreadable))
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
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

    // MARK: - Deletions (#135)

    /// Two simulated devices on one backup file. The sync manager is shared,
    /// so each device's own deletion markers (the per-device state these
    /// tests need) are swapped in and out of their defaults key around its
    /// turn. The phone saves works 1 and 2, a hidden work, a folder, a saved
    /// search and a saved filter an hour ago and backs up; the iPad restores
    /// them.
    @MainActor
    private final class TwoDevices {
        let phone: ModelContext
        let pad: ModelContext
        private var markers: [ObjectIdentifier: Any] = [:]
        private var current: ObjectIdentifier?

        init(phone: ModelContext, pad: ModelContext) {
            self.phone = phone
            self.pad = pad
        }

        /// Makes `context`'s device the one whose markers are in defaults.
        func use(_ context: ModelContext) {
            let defaults = UserDefaults.standard
            let key = iCloudSyncManager.deletionsKey
            if let current { markers[current] = defaults.object(forKey: key) }
            defaults.set(markers[ObjectIdentifier(context)], forKey: key)
            current = ObjectIdentifier(context)
        }
    }

    private static let anHourAgo = Date.now.addingTimeInterval(-3600)

    private func twoSyncedDevices() async throws -> TwoDevices {
        let phone = try makeContext()
        for id in [1, 2] {
            WorkPersistence.upsert(payload: payload(id: id, chapters: 2), into: phone).savedAt = Self.anHourAgo
        }
        phone.insert(HiddenWork(ao3Id: 5, title: "Hidden", hiddenAt: Self.anHourAgo))
        phone.insert(CustomFolder(name: "Faves", createdAt: Self.anHourAgo))
        phone.insert(SavedSearch(name: "Angst", prompt: "angst", savedAt: Self.anHourAgo))
        phone.insert(SavedFilter(name: "Long", filtersJSON: "{}", savedAt: Self.anHourAgo))
        try phone.save()
        let devices = TwoDevices(phone: phone, pad: try makeContext())
        devices.use(phone)
        iCloudSyncManager.shared.backupToiCloud(context: phone)

        devices.use(devices.pad)
        let restored = await iCloudSyncManager.shared.restoreFromiCloud(context: devices.pad)
        XCTAssertTrue(restored)
        XCTAssertEqual(try devices.pad.fetchCount(FetchDescriptor<Work>()), 2)
        return devices
    }

    /// Runs `body` with a temporary backup file and this test's own deletion
    /// markers, putting back whatever was there before.
    private func withDeletionTest(_ body: (URL) async throws -> Void) async throws {
        let url = makeTempBackupURL()
        let defaults = UserDefaults.standard
        let key = iCloudSyncManager.deletionsKey
        let originalMarkers = defaults.object(forKey: key)
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            defaults.set(originalMarkers, forKey: key)
        }
        defaults.removeObject(forKey: key)
        try await body(url)
    }

    private func work(_ id: Int, in context: ModelContext) throws -> Work? {
        try context.fetch(FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == id })).first
    }

    /// The bug: a delete on one device came back on that device as soon as
    /// another device backed up its copy. Now the deletion marker keeps it
    /// out of the file, the deleting device's next restore leaves it deleted,
    /// and the other device's restore deletes its copy too.
    func test_deletedWorkStaysDeletedAfterAnotherDevicesBackup() async throws {
        try await withDeletionTest { url in
            let devices = try await twoSyncedDevices()
            let sync = iCloudSyncManager.shared

            // The phone deletes work 1 and backs up.
            devices.use(devices.phone)
            iCloudSyncManager.recordDeletion(.work, key: "1")
            WorkPersistence.delete(try XCTUnwrap(work(1, in: devices.phone)), in: devices.phone)
            try devices.phone.save()
            sync.backupToiCloud(context: devices.phone)
            XCTAssertEqual(try decodeBackup(at: url).works.map(\.ao3Id), [2])

            // The iPad, which hasn't restored since, backs up its copy of
            // work 1: the marker keeps it out of the file.
            devices.use(devices.pad)
            sync.backupToiCloud(context: devices.pad)
            let file = try decodeBackup(at: url)
            XCTAssertEqual(file.works.map(\.ao3Id), [2])
            XCTAssertEqual(file.deleted?.map { [$0.kind, $0.key] }, [["work", "1"]])

            // The phone's next launch sync doesn't bring it back…
            devices.use(devices.phone)
            let phoneRestored = await sync.restoreFromiCloud(context: devices.phone)
            XCTAssertTrue(phoneRestored)
            XCTAssertNil(try work(1, in: devices.phone))

            // …and the iPad's deletes its copy.
            devices.use(devices.pad)
            let padRestored = await sync.restoreFromiCloud(context: devices.pad)
            XCTAssertTrue(padRestored)
            XCTAssertNil(try work(1, in: devices.pad))
            XCTAssertNotNil(try work(2, in: devices.pad))
        }
    }

    /// Un-hiding, and deleting a folder, a saved search or a saved filter,
    /// sticks the same way.
    func test_unhiddenWorkAndDeletedFolderSearchAndFilterStayDeleted() async throws {
        try await withDeletionTest { url in
            let devices = try await twoSyncedDevices()
            let sync = iCloudSyncManager.shared

            devices.use(devices.phone)
            HiddenWorkStore.unhide(ao3Id: 5, in: devices.phone)
            iCloudSyncManager.recordDeletion(.folder, key: "Faves")
            iCloudSyncManager.recordDeletion(.search, key: "Angst")
            iCloudSyncManager.recordDeletion(.filter, key: "Long")
            for folder in try devices.phone.fetch(FetchDescriptor<CustomFolder>()) { devices.phone.delete(folder) }
            for search in try devices.phone.fetch(FetchDescriptor<SavedSearch>()) { devices.phone.delete(search) }
            for filter in try devices.phone.fetch(FetchDescriptor<SavedFilter>()) { devices.phone.delete(filter) }
            try devices.phone.save()
            sync.backupToiCloud(context: devices.phone)

            devices.use(devices.pad)
            sync.backupToiCloud(context: devices.pad)
            let file = try decodeBackup(at: url)
            XCTAssertTrue(file.hidden.isEmpty)
            XCTAssertEqual(file.folders?.isEmpty, true)
            XCTAssertTrue(file.searches.isEmpty)
            XCTAssertTrue(file.filters.isEmpty)

            for device in [devices.phone, devices.pad] {
                devices.use(device)
                let restored = await sync.restoreFromiCloud(context: device)
                XCTAssertTrue(restored)
                XCTAssertEqual(try device.fetchCount(FetchDescriptor<HiddenWork>()), 0)
                XCTAssertEqual(try device.fetchCount(FetchDescriptor<CustomFolder>()), 0)
                XCTAssertEqual(try device.fetchCount(FetchDescriptor<SavedSearch>()), 0)
                XCTAssertEqual(try device.fetchCount(FetchDescriptor<SavedFilter>()), 0)
            }
        }
    }

    /// A record saved again after the delete is newer than the marker, so
    /// it comes back everywhere, and a restore doesn't delete it.
    func test_workSavedAgainAfterADeleteComesBack() async throws {
        try await withDeletionTest { url in
            let devices = try await twoSyncedDevices()
            let sync = iCloudSyncManager.shared

            devices.use(devices.phone)
            iCloudSyncManager.recordDeletion(.work, key: "1", at: Self.anHourAgo.addingTimeInterval(600))
            WorkPersistence.delete(try XCTUnwrap(work(1, in: devices.phone)), in: devices.phone)
            try devices.phone.save()
            sync.backupToiCloud(context: devices.phone)

            // The iPad saves work 1 again (a fresh download, stamped now).
            devices.use(devices.pad)
            WorkPersistence.delete(try XCTUnwrap(work(1, in: devices.pad)), in: devices.pad)
            try devices.pad.save()
            _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 3), into: devices.pad)
            sync.backupToiCloud(context: devices.pad)
            XCTAssertTrue(try decodeBackup(at: url).works.contains { $0.ao3Id == 1 })

            devices.use(devices.phone)
            let phoneRestored = await sync.restoreFromiCloud(context: devices.phone)
            XCTAssertTrue(phoneRestored)
            XCTAssertEqual(try work(1, in: devices.phone)?.chapters.count, 3)
            devices.use(devices.pad)
            let padRestored = await sync.restoreFromiCloud(context: devices.pad)
            XCTAssertTrue(padRestored)
            XCTAssertNotNil(try work(1, in: devices.pad))
        }
    }

    /// An app version without deletion markers writes the deleted work back
    /// into the file (keeping the markers as a key it doesn't know); the
    /// deleting device still doesn't restore it.
    func test_olderAppWritingADeletedWorkBackDoesNotRestoreIt() async throws {
        try await withDeletionTest { url in
            let devices = try await twoSyncedDevices()
            let sync = iCloudSyncManager.shared

            devices.use(devices.phone)
            iCloudSyncManager.recordDeletion(.work, key: "1")
            WorkPersistence.delete(try XCTUnwrap(work(1, in: devices.phone)), in: devices.phone)
            try devices.phone.save()
            sync.backupToiCloud(context: devices.phone)

            // The older app: the file with work 1 added back, markers kept.
            var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var works = try XCTUnwrap(json["works"] as? [[String: Any]])
            var stale = try XCTUnwrap(works.first)
            stale["ao3Id"] = 1
            stale["savedAt"] = ISO8601DateFormatter().string(from: Self.anHourAgo)
            works.append(stale)
            json["works"] = works
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            XCTAssertEqual(try decodeBackup(at: url).works.map(\.ao3Id).sorted(), [1, 2])

            let restored = await sync.restoreFromiCloud(context: devices.phone)
            XCTAssertTrue(restored)
            XCTAssertNil(try work(1, in: devices.phone))

            // And the phone's next backup takes it out of the file again.
            sync.backupToiCloud(context: devices.phone)
            XCTAssertEqual(try decodeBackup(at: url).works.map(\.ao3Id), [2])
        }
    }

    /// Markers live 90 days; the newest one per record is kept.
    func test_deletionMarkersArePrunedAfterNinetyDays() {
        let now = Date.now
        let day: TimeInterval = 24 * 60 * 60
        let pruned = iCloudSyncManager.prunedDeletions([
            DeletionBackup(kind: "work", key: "1", deletedAt: now.addingTimeInterval(-91 * day)),
            DeletionBackup(kind: "work", key: "2", deletedAt: now.addingTimeInterval(-89 * day)),
            DeletionBackup(kind: "work", key: "2", deletedAt: now.addingTimeInterval(-100 * day)),
        ], now: now)
        XCTAssertEqual(pruned, [DeletionBackup(kind: "work", key: "2", deletedAt: now.addingTimeInterval(-89 * day))])
    }

    /// A backup written before deletion markers has no `deleted` key and
    /// must still decode; one with markers decodes them in the shared format.
    func test_backupDeletionMarkersDecodeAndAreOptional() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = """
        {"works":[],"bookmarks":[],"subscriptions":[],"searches":[],"progress":[],
         "filters":[],"hidden":[],"timestamp":"2026-01-01T00:00:00Z"}
        """
        XCTAssertNil(try decoder.decode(LibraryBackup.self, from: Data(old.utf8)).deleted)
        let new = """
        {"works":[],"bookmarks":[],"subscriptions":[],"searches":[],"progress":[],
         "filters":[],"hidden":[],"timestamp":"2026-01-01T00:00:00Z",
         "deleted":[{"kind":"folder","key":"Faves","deletedAt":"2026-01-01T00:00:00Z"}]}
        """
        let deleted = try XCTUnwrap(try decoder.decode(LibraryBackup.self, from: Data(new.utf8)).deleted)
        XCTAssertEqual(deleted.map(\.kind), ["folder"])
        XCTAssertEqual(deleted.map(\.key), ["Faves"])
    }

    /// Two devices backing up in either order end with the same file: the
    /// newest reading position, the fresher AO3 metadata, both folders, and the highest notification baselines and latest check, so
    /// the device that backs up second can't move anything backwards.
    func test_backupMergeEitherOrderKeepsNewestPositionAndHighestBaseline() throws {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_090_000)

        // Device A: fresher metadata, starred and followed, baseline 10.
        func deviceA() throws -> ModelContext {
            let ctx = try makeContext()
            let folder = CustomFolder(name: "A shelf")
            ctx.insert(folder)
            let work = Work(ao3Id: 1, title: "New Title", authorName: "A")
            work.updatedAt = newer
            work.chapterCount = 10
            work.kudos = 50
            work.savedAt = older
            work.lastReadAt = older
            work.lastReadChapter = 2
            work.lastReadProgress = 0.2
            work.isFollowed = true
            work.isStarred = true
            work.lastSeenChapterCount = 10
            ctx.insert(work)
            work.folders.append(folder)
            let sub = SubscriptionRecord(key: "work:1", kind: "work", displayName: "Fic")
            sub.lastSeenChapterCount = 10
            sub.lastCheckedAt = newer
            ctx.insert(sub)
            try ctx.save()
            return ctx
        }
        // Device B: read more recently, but older metadata, no flags, a lower
        // work baseline and a nil subscription baseline.
        func deviceB() throws -> ModelContext {
            let ctx = try makeContext()
            let folder = CustomFolder(name: "B shelf")
            ctx.insert(folder)
            let work = Work(ao3Id: 1, title: "Old Title", authorName: "A")
            work.updatedAt = older
            work.chapterCount = 8
            work.kudos = 5
            work.savedAt = newer
            work.lastReadAt = newer
            work.lastReadChapter = 7
            work.lastReadProgress = 0.7
            work.lastSeenChapterCount = 4
            ctx.insert(work)
            work.folders.append(folder)
            let sub = SubscriptionRecord(key: "work:1", kind: "work", displayName: "Fic")
            sub.lastCheckedAt = older
            ctx.insert(sub)
            try ctx.save()
            return ctx
        }

        for aFirst in [true, false] {
            let url = makeTempBackupURL()
            iCloudSyncManager.overrideBackupURL = url
            defer {
                iCloudSyncManager.overrideBackupURL = nil
                try? FileManager.default.removeItem(at: url)
            }
            let a = try deviceA()
            let b = try deviceB()
            let (first, second) = aFirst ? (a, b) : (b, a)
            iCloudSyncManager.shared.backupToiCloud(context: first)
            iCloudSyncManager.shared.backupToiCloud(context: second)

            let merged = try decodeBackup(at: url)
            let work = try XCTUnwrap(merged.works.first)
            XCTAssertEqual(work.title, "New Title", "aFirst: \(aFirst)")
            XCTAssertEqual(work.chapterCount, 10)
            XCTAssertEqual(work.kudos, 50)
            XCTAssertEqual(work.updatedAt, newer)
            XCTAssertEqual(work.savedAt, newer)
            XCTAssertEqual(work.lastReadAt, newer)
            XCTAssertEqual(work.lastReadChapter, 7)
            XCTAssertEqual(work.lastReadProgress, 0.7)
            // Flags are the one exception: the device backing up second keeps
            // its own, so an un-follow can reach the file (restore ORs them).
            XCTAssertEqual(work.isFollowed, !aFirst)
            XCTAssertEqual(work.isStarred, !aFirst)
            XCTAssertEqual(work.lastSeenChapterCount, 10)
            XCTAssertEqual(Set(work.folderNames ?? []), ["A shelf", "B shelf"])
            let sub = try XCTUnwrap(merged.subscriptions.first)
            XCTAssertEqual(sub.lastSeenChapterCount, 10, "aFirst: \(aFirst)")
            XCTAssertEqual(sub.lastCheckedAt, newer)
        }
    }

    /// An un-follow, un-star or un-pin reaches the file through this device's
    /// own backup, so restoring that file (a reinstall) doesn't bring them back.
    func test_unfollowSurvivesTheBackupMergeAndARestore() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }
        let device = try makeContext()
        let work = Work(ao3Id: 1, title: "T", authorName: "A")
        work.isFollowed = true
        work.isStarred = true
        work.isPinned = true
        device.insert(work)
        try device.save()
        iCloudSyncManager.shared.backupToiCloud(context: device)

        work.isFollowed = false
        work.isStarred = false
        work.isPinned = false
        try device.save()
        iCloudSyncManager.shared.backupToiCloud(context: device)

        let reinstalled = try makeContext()
        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: reinstalled)
        XCTAssertTrue(success)
        let restored = try XCTUnwrap(try reinstalled.fetch(FetchDescriptor<Work>()).first)
        XCTAssertFalse(restored.isFollowed)
        XCTAssertFalse(restored.isStarred)
        XCTAssertFalse(restored.isPinned)
    }

    /// Restoring an older backup never lowers a baseline, clears one with nil,
    /// or puts back older AO3 metadata; a newer backup still advances them.
    func test_restoreOlderBackupNeverLowersBaselinesOrMetadata() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
        }
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_090_000)

        // The backup is behind on work 1 and subscriptions a and b, ahead on work 2.
        let cloudDevice = try makeContext()
        let stale = Work(ao3Id: 1, title: "Old Title", authorName: "A")
        stale.updatedAt = older
        stale.chapterCount = 3
        stale.kudos = 5
        stale.savedAt = older
        stale.lastSeenChapterCount = 3
        cloudDevice.insert(stale)
        let fresh = Work(ao3Id: 2, title: "Newer Title", authorName: "A")
        fresh.updatedAt = newer
        fresh.chapterCount = 6
        fresh.lastSeenChapterCount = 6
        cloudDevice.insert(fresh)
        let subA = SubscriptionRecord(key: "work:1", kind: "work", displayName: "Fic")
        subA.lastSeenChapterCount = 2
        subA.lastCheckedAt = older
        cloudDevice.insert(subA)
        cloudDevice.insert(SubscriptionRecord(key: "work:2", kind: "work", displayName: "Other"))
        try cloudDevice.save()
        iCloudSyncManager.shared.backupToiCloud(context: cloudDevice)

        let device = try makeContext()
        let local1 = Work(ao3Id: 1, title: "New Title", authorName: "A")
        local1.updatedAt = newer
        local1.chapterCount = 8
        local1.kudos = 50
        local1.savedAt = newer
        local1.lastSeenChapterCount = 8
        device.insert(local1)
        let local2 = Work(ao3Id: 2, title: "Older Title", authorName: "A")
        local2.updatedAt = older
        local2.chapterCount = 4
        local2.lastSeenChapterCount = 4
        device.insert(local2)
        let localA = SubscriptionRecord(key: "work:1", kind: "work", displayName: "Fic")
        localA.lastSeenChapterCount = 9
        localA.lastCheckedAt = newer
        device.insert(localA)
        let localB = SubscriptionRecord(key: "work:2", kind: "work", displayName: "Other")
        localB.lastSeenChapterCount = 5
        device.insert(localB)
        try device.save()

        let success = await iCloudSyncManager.shared.restoreFromiCloud(context: device)
        XCTAssertTrue(success)
        let works = try device.fetch(FetchDescriptor<Work>())
        let w1 = try XCTUnwrap(works.first(where: { $0.ao3Id == 1 }))
        XCTAssertEqual(w1.title, "New Title")
        XCTAssertEqual(w1.chapterCount, 8)
        XCTAssertEqual(w1.kudos, 50)
        XCTAssertEqual(w1.updatedAt, newer)
        XCTAssertEqual(w1.savedAt, newer)
        XCTAssertEqual(w1.lastSeenChapterCount, 8)
        let w2 = try XCTUnwrap(works.first(where: { $0.ao3Id == 2 }))
        XCTAssertEqual(w2.title, "Newer Title")
        XCTAssertEqual(w2.chapterCount, 6)
        XCTAssertEqual(w2.lastSeenChapterCount, 6)
        let subs = try device.fetch(FetchDescriptor<SubscriptionRecord>())
        let a = try XCTUnwrap(subs.first(where: { $0.key == "work:1" }))
        XCTAssertEqual(a.lastSeenChapterCount, 9)
        XCTAssertEqual(a.lastCheckedAt, newer)
        let b = try XCTUnwrap(subs.first(where: { $0.key == "work:2" }))
        XCTAssertEqual(b.lastSeenChapterCount, 5, "a nil baseline in the backup must not switch alerts off")
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

    /// The prompt's candidates narrow to the works a restore gave text, and
    /// leave out the ones the reader turned down (#152).
    func test_redownloadCandidatesKeepRestoredDropDeclined() throws {
        let ctx = try makeContext()
        for id in [987654331, 987654332, 987654333] {
            _ = WorkPersistence.upsert(payload: payload(id: id, chapters: 1), into: ctx)
        }
        try ctx.save()
        XCTAssertEqual(RestoreDownloadCenter.redownloadCandidates(
            in: ctx, restored: [987654331, 987654332], declined: [987654332]), [987654331])
        XCTAssertEqual(RestoreDownloadCenter.redownloadCandidates(in: ctx, restored: []), [])
    }

    /// Not Now is remembered: noting the same works again (the next launch
    /// sync) offers nothing, while a newly restored work is still offered.
    func test_redownloadPromptRemembersNotNow() throws {
        let suite = "test.redownload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ctx = try makeContext()
        for id in [987654341, 987654342] {
            _ = WorkPersistence.upsert(payload: payload(id: id, chapters: 2), into: ctx)
        }
        try ctx.save()

        let center = RestoreDownloadCenter(defaults: defaults)
        center.noteRestoredText(workIds: [987654341])
        center.proposeRedownload(context: ctx)
        XCTAssertEqual(center.proposedIds, [987654341])
        center.declineProposal()
        XCTAssertNil(center.proposedIds)

        center.noteRestoredText(workIds: [987654341])
        center.proposeRedownload(context: ctx)
        XCTAssertNil(center.proposedIds, "a declined work isn't offered again")

        center.proposeRedownload(context: ctx)
        XCTAssertNil(center.proposedIds, "nothing restored, nothing offered")

        center.noteRestoredText(workIds: [987654341, 987654342])
        center.proposeRedownload(context: ctx)
        XCTAssertEqual(center.proposedIds, [987654342])
    }

    /// A restore run AO3 stops (429) keeps the stories it didn't reach
    /// pending on this device, so the next restore offers them again, even
    /// after a relaunch (a new center on the same defaults).
    func test_stoppedRestoreRunKeepsTheRestPending() async throws {
        let suite = "test.redownload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ctx = try makeContext()
        for id in [987654361, 987654362, 987654363] {
            _ = WorkPersistence.upsert(payload: payload(id: id, chapters: 1), into: ctx)
        }
        try ctx.save()

        let center = RestoreDownloadCenter(defaults: defaults)
        center.noteRestoredText(workIds: [987654361, 987654362, 987654363])
        center.proposeRedownload(context: ctx)
        XCTAssertEqual(center.proposedIds, [987654361, 987654362, 987654363])
        let client = StubAO3Client()
        client.downloadEPUBErrors[987654362] = AO3Error.rateLimited
        center.startDownloads(client: client, signedIn: true)
        for _ in 0..<100 where center.progress?.finished != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(center.progress?.stopped, .rateLimited)

        let relaunched = RestoreDownloadCenter(defaults: defaults)
        relaunched.proposeRedownload(context: ctx)
        XCTAssertEqual(relaunched.proposedIds, [987654362, 987654363])
        center.cancel()
    }

    /// A launch sync that brings no new chapter text doesn't bring the
    /// prompt back: only the first restore, which added the text, offers it.
    func test_restoreOffersRedownloadOnlyWhenTextIsAdded() async throws {
        let url = makeTempBackupURL()
        iCloudSyncManager.overrideBackupURL = url
        let center = RestoreDownloadCenter.shared
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: url)
            center.dismissProposal()
            UserDefaults.standard.removeObject(forKey: RestoreDownloadCenter.pendingKey)
        }
        center.dismissProposal()
        UserDefaults.standard.removeObject(forKey: RestoreDownloadCenter.pendingKey)

        let phone = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 987654351, chapters: 2), into: phone)
        phone.insert(Work(ao3Id: 987654352, title: "Metadata only", authorName: "A"))
        try phone.save()
        iCloudSyncManager.shared.backupToiCloud(context: phone)

        let pad = try makeContext()
        let restored = await iCloudSyncManager.shared.restoreFromiCloud(context: pad)
        XCTAssertTrue(restored)
        center.proposeRedownload(context: pad)
        XCTAssertEqual(center.proposedIds, [987654351])
        center.dismissProposal()

        let again = await iCloudSyncManager.shared.restoreFromiCloud(context: pad)
        XCTAssertTrue(again)
        center.proposeRedownload(context: pad)
        XCTAssertNil(center.proposedIds, "the second restore added no text")
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
        let result = await RestoreDownloadCenter.runQueue(ids: [1, 2, 3], signedIn: true, download: { id in
            rec.attempted.append(id)
            if id == 2 { throw URLError(.badServerResponse) }
            rec.downloaded.append(id)
        }, report: { rec.reports.append($0) })
        XCTAssertEqual(rec.attempted, [1, 2, 3])
        XCTAssertEqual(rec.downloaded, [1, 3])
        XCTAssertEqual(rec.reports.count, 3)
        XCTAssertEqual(result, .init(done: 2, failed: 1, total: 3, finished: true))
    }

    /// A rate limit or a sign-in wall ends the run: the stories after it
    /// aren't tried, and the tally says why it stopped (#152).
    func test_downloadQueueStopsWhenAO3Refuses() async {
        let cases: [(AO3Error, RestoreDownloadCenter.StopReason)] = [
            (.rateLimited, .rateLimited), (.unauthorized, .signInNeeded),
        ]
        for (error, reason) in cases {
            let rec = QueueRecorder()
            let result = await RestoreDownloadCenter.runQueue(ids: [1, 2, 3, 4], signedIn: true, download: { id in
                rec.attempted.append(id)
                if id == 2 { throw error }
                rec.downloaded.append(id)
            }, report: { rec.reports.append($0) })
            XCTAssertEqual(rec.attempted, [1, 2])
            XCTAssertEqual(rec.downloaded, [1])
            XCTAssertEqual(result, .init(done: 1, failed: 1, total: 4, finished: true, stopped: reason))
            XCTAssertEqual(result?.untried, 3)
            XCTAssertNotNil(result?.stoppedDetail)
        }
    }

    /// Signed out, `.unauthorized` is a restricted work: it fails alone and
    /// the public stories after it still download.
    func test_downloadQueueSkipsRestrictedWorkWhenSignedOut() async {
        let rec = QueueRecorder()
        let result = await RestoreDownloadCenter.runQueue(ids: [1, 2, 3], signedIn: false, download: { id in
            rec.attempted.append(id)
            if id == 2 { throw AO3Error.unauthorized }
            rec.downloaded.append(id)
        }, report: { rec.reports.append($0) })
        XCTAssertEqual(rec.downloaded, [1, 3])
        XCTAssertEqual(result, .init(done: 2, failed: 1, total: 3, finished: true))
        XCTAssertEqual(result?.untried, 0)
    }

    /// Cancelling mid-run stops before the next story and undoes nothing:
    /// the stories that finished stay downloaded.
    func test_downloadQueueCancelKeepsFinished() async {
        let rec = QueueRecorder()
        let task = Task { @MainActor in
            await RestoreDownloadCenter.runQueue(ids: [1, 2, 3], signedIn: true, download: { id in
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

    // MARK: - Library file export and import (RM-012)

    /// Exporting a library file and importing it into an empty library brings
    /// back every work (with its chapters and folders), reading position,
    /// stat, bookmark, subscription and saved search.
    func test_libraryFileRoundTripsIntoEmptyContainer() throws {
        let read = Date(timeIntervalSince1970: 1_790_000_000)
        let source = try makeContext()
        let folder = CustomFolder(name: "Faves", createdAt: read)
        source.insert(folder)
        _ = WorkPersistence.upsert(payload: payload(id: 1, chapters: 3), into: source)
        let work = try XCTUnwrap(try source.fetch(FetchDescriptor<Work>()).first)
        work.isStarred = true
        work.isFollowed = true
        work.lastSeenChapterCount = 3
        work.lastReadAt = read
        work.lastReadChapter = 2
        work.lastReadProgress = 0.5
        work.folders.append(folder)
        source.insert(Work(ao3Id: 2, title: "Metadata only", authorName: "B"))
        source.insert(ReadingProgress(ao3Id: 1, chapterIndex: 2, paragraphIndex: 14,
                                      title: "Test Work 1", author: "tester", updatedAt: read))
        source.insert(ReadingStat(ao3Id: 1, title: "Test Work 1", author: "tester",
                                  fandoms: ["Harry Potter - J. K. Rowling"], wordCount: 5000,
                                  firstReadAt: read, lastReadAt: read,
                                  totalSeconds: 600, daySeconds: ["2026-09-21": 600],
                                  maxProgress: 0.5, workIsComplete: true))
        source.insert(BookmarkRecord(ao3Id: 77, workAo3Id: 1, notes: "reread", tags: ["comfort"], savedAt: read))
        let sub = SubscriptionRecord(key: "work:1", kind: "work", displayName: "Test Work 1", authorName: "tester")
        sub.lastSeenChapterCount = 3
        source.insert(sub)
        source.insert(SavedSearch(name: "Slow burn", prompt: "tag:\"Slow Burn\"", savedAt: read))
        try source.save()

        let url = try iCloudSyncManager.shared.exportLibraryFile(context: source)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Fanficly Library "))

        let target = try makeContext()
        try iCloudSyncManager.shared.importLibraryFile(at: url, context: target)

        let works = try target.fetch(FetchDescriptor<Work>()).sorted { $0.ao3Id < $1.ao3Id }
        XCTAssertEqual(works.map(\.ao3Id), [1, 2])
        let restored = works[0]
        XCTAssertEqual(restored.title, "Test Work 1")
        XCTAssertEqual(restored.chapters.sorted { $0.index < $1.index }.map(\.bodyHTML),
                       ["<p>Body 1</p>", "<p>Body 2</p>", "<p>Body 3</p>"])
        XCTAssertTrue(restored.isStarred)
        XCTAssertTrue(restored.isFollowed)
        XCTAssertEqual(restored.lastSeenChapterCount, 3)
        XCTAssertEqual(restored.lastReadAt, read)
        XCTAssertEqual(restored.lastReadChapter, 2)
        XCTAssertEqual(restored.folders.map(\.name), ["Faves"])
        XCTAssertTrue(works[1].chapters.isEmpty)

        let progress = try XCTUnwrap(try target.fetch(FetchDescriptor<ReadingProgress>()).first)
        XCTAssertEqual(progress.chapterIndex, 2)
        XCTAssertEqual(progress.paragraphIndex, 14)
        XCTAssertEqual(progress.updatedAt, read)

        let stat = try XCTUnwrap(try target.fetch(FetchDescriptor<ReadingStat>()).first)
        XCTAssertEqual(stat.totalSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(stat.maxProgress, 0.5, accuracy: 0.001)
        XCTAssertTrue(stat.workIsComplete)

        let bookmark = try XCTUnwrap(try target.fetch(FetchDescriptor<BookmarkRecord>()).first)
        XCTAssertEqual(bookmark.notes, "reread")
        XCTAssertEqual(bookmark.tags, ["comfort"])
        let restoredSub = try XCTUnwrap(try target.fetch(FetchDescriptor<SubscriptionRecord>()).first)
        XCTAssertEqual(restoredSub.key, "work:1")
        XCTAssertEqual(restoredSub.lastSeenChapterCount, 3)
        XCTAssertEqual(try target.fetch(FetchDescriptor<SavedSearch>()).map(\.name), ["Slow burn"])
    }

    /// Importing a file exported earlier, after reading further, never moves
    /// progress backwards: the reading position, the work's last-read
    /// chapter, the stat's furthest progress and a subscription's
    /// notification baseline all keep the newer values.
    func test_importingOlderLibraryFileNeverMovesProgressBackwards() throws {
        let earlier = Date(timeIntervalSince1970: 1_790_000_000)
        let later = earlier.addingTimeInterval(86_400)

        // The file was exported when the reader was on chapter 2.
        let old = try makeContext()
        let oldWork = Work(ao3Id: 1, title: "T", authorName: "A")
        oldWork.lastReadAt = earlier
        oldWork.lastReadChapter = 2
        oldWork.lastReadProgress = 0.2
        old.insert(oldWork)
        old.insert(ReadingProgress(ao3Id: 1, chapterIndex: 2, paragraphIndex: 3,
                                   title: "T", author: "A", updatedAt: earlier))
        old.insert(ReadingStat(ao3Id: 1, title: "T", author: "A",
                               firstReadAt: earlier, lastReadAt: earlier,
                               totalSeconds: 100, daySeconds: ["2026-09-21": 100], maxProgress: 0.2))
        let oldSub = SubscriptionRecord(key: "work:1", kind: "work", displayName: "T", authorName: "A")
        oldSub.lastSeenChapterCount = 2
        oldSub.lastCheckedAt = earlier
        old.insert(oldSub)
        try old.save()
        let url = try iCloudSyncManager.shared.exportLibraryFile(context: old)
        defer { try? FileManager.default.removeItem(at: url) }

        // Since then this library read on to chapter 7.
        let device = try makeContext()
        let work = Work(ao3Id: 1, title: "T", authorName: "A")
        work.lastReadAt = later
        work.lastReadChapter = 7
        work.lastReadProgress = 0.7
        device.insert(work)
        device.insert(ReadingProgress(ao3Id: 1, chapterIndex: 7, paragraphIndex: 0,
                                      title: "T", author: "A", updatedAt: later))
        device.insert(ReadingStat(ao3Id: 1, title: "T", author: "A",
                                  firstReadAt: earlier, lastReadAt: later,
                                  totalSeconds: 900, daySeconds: ["2026-09-21": 100, "2026-09-22": 800],
                                  maxProgress: 0.7))
        let sub = SubscriptionRecord(key: "work:1", kind: "work", displayName: "T", authorName: "A")
        sub.lastSeenChapterCount = 7
        sub.lastCheckedAt = later
        device.insert(sub)
        try device.save()

        try iCloudSyncManager.shared.importLibraryFile(at: url, context: device)

        let progress = try XCTUnwrap(try device.fetch(FetchDescriptor<ReadingProgress>()).first)
        XCTAssertEqual(progress.chapterIndex, 7)
        XCTAssertEqual(progress.updatedAt, later)
        let restored = try XCTUnwrap(try device.fetch(FetchDescriptor<Work>()).first)
        XCTAssertEqual(restored.lastReadChapter, 7)
        XCTAssertEqual(restored.lastReadProgress ?? 0, 0.7, accuracy: 0.001)
        let stat = try XCTUnwrap(try device.fetch(FetchDescriptor<ReadingStat>()).first)
        XCTAssertEqual(stat.maxProgress, 0.7, accuracy: 0.001)
        XCTAssertEqual(stat.totalSeconds, 900, accuracy: 0.001)
        XCTAssertEqual(stat.lastReadAt, later)
        let restoredSub = try XCTUnwrap(try device.fetch(FetchDescriptor<SubscriptionRecord>()).first)
        XCTAssertEqual(restoredSub.lastSeenChapterCount, 7, "an old file must not re-fire chapter alerts")
        XCTAssertEqual(restoredSub.lastCheckedAt, later)
    }

    /// A file that isn't a library backup is refused and changes nothing.
    func test_importingNonLibraryFileThrowsAndChangesNothing() throws {
        let url = makeTempBackupURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"hello": "world"}"#.utf8).write(to: url)

        let device = try makeContext()
        device.insert(Work(ao3Id: 1, title: "T", authorName: "A"))
        try device.save()

        XCTAssertThrowsError(try iCloudSyncManager.shared.importLibraryFile(at: url, context: device))
        XCTAssertEqual(try device.fetch(FetchDescriptor<Work>()).map(\.ao3Id), [1])
    }

    /// The Windows app writes the same file, with an extra `followedAuthors`
    /// list the Apple backup doesn't carry yet; it must still import.
    func test_importsWindowsLibraryFile() throws {
        let url = makeTempBackupURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"works":[{"ao3Id":5,"title":"From Windows","authorName":"W","authorUsername":"w",
        "summary":"","rating":"General Audiences","warnings":[],"categories":[],"fandoms":[],
        "characters":[],"relationships":[],"freeforms":[],"language":"English","wordCount":10,
        "chapterCount":1,"kudos":0,"hits":0,"bookmarksCount":0,"commentsCount":0,
        "isComplete":true,"savedAt":"2026-10-16T09:41:00Z","isFollowed":false,
        "chapters":[{"index":1,"title":"One","bodyHTML":"<p>Hi</p>","aoId":42}],
        "folderNames":[]}],
        "bookmarks":[],"subscriptions":[],"searches":[],
        "progress":[{"ao3Id":5,"chapterIndex":1,"paragraphIndex":2,"title":"From Windows",
        "author":"W","updatedAt":"2026-10-16T09:41:00Z"}],
        "filters":[],"hidden":[],"timestamp":"2026-10-16T09:41:00Z",
        "followedAuthors":[{"username":"w","displayName":"W","followedAt":"2026-10-16T09:41:00Z","knownWorkIds":[5]}]}
        """
        try Data(json.utf8).write(to: url)

        let device = try makeContext()
        try iCloudSyncManager.shared.importLibraryFile(at: url, context: device)

        let work = try XCTUnwrap(try device.fetch(FetchDescriptor<Work>()).first)
        XCTAssertEqual(work.title, "From Windows")
        XCTAssertEqual(work.chapters.first?.aoId, 42)
        XCTAssertEqual(try device.fetch(FetchDescriptor<ReadingProgress>()).first?.paragraphIndex, 2)
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

        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader", defaults: scratchDefaults())
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

        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader", defaults: scratchDefaults())
        _ = try await poller.syncSubscriptionList()

        let remaining = try ctx.fetch(FetchDescriptor<SubscriptionRecord>())
        XCTAssertEqual(Set(remaining.map(\.key)), ["work:1", "user:carol"])
    }

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.subscriptionPoller.\(UUID().uuidString)")!
    }

    // A list that ran past the 50-page ceiling is missing real subscriptions
    // (#150): it adds and updates what it read, but deletes nothing.
    func test_syncSubscriptionList_incompleteListPrunesNothing() async throws {
        let ctx = try makeContext()
        seedSubscriptionRecords(into: ctx)
        let client = StubAO3Client()
        client.subscriptionsResponse = [
            AO3Subscription(kind: .work, resourceId: "1", title: "Fic One (renamed)", author: "alice"),
            AO3Subscription(kind: .user, resourceId: "carol", title: "carol", author: nil),
        ]
        client.subscriptionsComplete = false

        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader", defaults: scratchDefaults())
        _ = try await poller.syncSubscriptionList()

        let remaining = try ctx.fetch(FetchDescriptor<SubscriptionRecord>())
        XCTAssertEqual(Set(remaining.map(\.key)), ["work:1", "series:9", "user:carol"])
        let work = remaining.first(where: { $0.key == "work:1" })
        XCTAssertEqual(work?.displayName, "Fic One (renamed)")
        XCTAssertEqual(work?.lastSeenChapterCount, 5)
    }

    // A background run with a list synced in the last day goes straight to
    // the chapter checks (#150).
    func test_runFullPoll_freshListSyncSkipsTheListWalk() async throws {
        let ctx = try makeContext()
        seedSubscriptionRecords(into: ctx)
        let client = StubAO3Client()
        let defaults = scratchDefaults()
        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader", defaults: defaults)
        _ = try await poller.syncSubscriptionList()
        XCTAssertEqual(client.subscriptionsFetchCount, 1)
        XCTAssertFalse(poller.listSyncIsDue())

        _ = await poller.runFullPoll()

        XCTAssertEqual(client.subscriptionsFetchCount, 1)
        let work = try ctx.fetch(FetchDescriptor<SubscriptionRecord>()).first(where: { $0.key == "work:1" })
        XCTAssertNotNil(work?.lastCheckedAt, "the work subscription is still checked")
    }

    // With no sync yet, or the last one a day old, the run syncs the list
    // once and stamps it, so the next run skips it.
    func test_runFullPoll_syncsTheListOnceADay() async throws {
        let ctx = try makeContext()
        let client = StubAO3Client()
        client.subscriptionsResponse = [AO3Subscription(kind: .work, resourceId: "7", title: "New Sub", author: "dana")]
        let defaults = scratchDefaults()
        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader", defaults: defaults)
        XCTAssertTrue(poller.listSyncIsDue())

        _ = await poller.runFullPoll()
        XCTAssertEqual(client.subscriptionsFetchCount, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SubscriptionRecord>()).map(\.key), ["work:7"])

        _ = await poller.runFullPoll()
        XCTAssertEqual(client.subscriptionsFetchCount, 1)

        let dayLater = Date.now.addingTimeInterval(SubscriptionPoller.listSyncInterval + 60)
        XCTAssertTrue(poller.listSyncIsDue(now: dayLater))
    }

    // Signed out there's no list to sync.
    func test_listSyncIsDue_falseWhenSignedOut() throws {
        let poller = SubscriptionPoller(client: StubAO3Client(), context: try makeContext(), username: nil,
                                        defaults: scratchDefaults())
        XCTAssertFalse(poller.listSyncIsDue())
    }

    // Signed in, a guest page means the session expired (#131): its public
    // works still join the baseline, so restricted ones alert once a
    // signed-in poll sees them. (No baseline yet, so no alert is posted.)
    func test_followedAuthor_guestPageWhileSignedIn_keepsThePublicWorks() async throws {
        let ctx = try makeContext()
        let author = FollowedAuthor(username: "locked", displayName: "Locked")
        ctx.insert(author)
        try ctx.save()
        let client = StubAO3Client()
        client.authorWorksResponse = AO3SearchResults(works: [.stub(id: 1, title: ""), .stub(id: 2, title: "")],
                                                      totalPages: 1, currentPage: 1, servedAsGuest: true)

        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader", defaults: scratchDefaults())
        let notified = await poller.checkFollowedAuthors()
        XCTAssertEqual(notified, 0)
        XCTAssertEqual(Set(author.knownWorkIds), [1, 2])
    }

    // AO3 lists an author's works by last update, so an old work that was
    // never in the baseline (past page 1 at follow time) rises to the top when
    // it gets a chapter. It isn't a new work: alerting for it opened that old
    // story, or the author's page when a real new work came in with it.
    func test_followedAuthor_updatedOlderWorkIsNotANewWork() async throws {
        let ctx = try makeContext()
        let author = FollowedAuthor(username: "prolific", displayName: "Prolific", knownWorkIds: [50, 60])
        ctx.insert(author)
        try ctx.save()
        let client = StubAO3Client()
        client.authorWorksResponse = AO3SearchResults(
            works: [authorWork(70, "Brand New"), authorWork(10, "Old, Just Updated", chapters: 4),
                    authorWork(60), authorWork(50)],
            totalPages: 1, currentPage: 1)

        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        let notified = await poller.checkFollowedAuthors()
        XCTAssertEqual(notified, 1)
        // The old work joins the baseline quietly.
        XCTAssertEqual(Set(author.knownWorkIds), [10, 50, 60, 70])

        // Only an updated old work: no alert at all.
        client.authorWorksResponse = AO3SearchResults(
            works: [authorWork(5, "Older Still", chapters: 2), authorWork(70), authorWork(10, chapters: 4)],
            totalPages: 1, currentPage: 1)
        let again = await poller.checkFollowedAuthors()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(Set(author.knownWorkIds), [5, 10, 50, 60, 70])
    }

    func test_newlyPostedWorks_newerThanTheBaselineOrOneChapter() {
        let works = [authorWork(70, "New", chapters: 3), authorWork(10, "Updated", chapters: 4),
                     authorWork(65, "Revealed Gift"), authorWork(60)]
        let fresh = SubscriptionPoller.newlyPostedWorks(in: works, known: [50, 60])
        // 65 is older than the newest known work but has one chapter: a gift
        // revealed from an anonymous collection, or a long-held draft.
        XCTAssertEqual(fresh.map(\.id), [70, 65])
        // No baseline yet: never alert for the back catalogue.
        XCTAssertTrue(SubscriptionPoller.newlyPostedWorks(in: works, known: []).isEmpty)
    }

    // Follow tapped before the author's list loaded: no baseline. The first
    // poll must neither alert for the back catalogue nor swallow a work
    // posted after the follow. Works last updated since the day before the
    // follow (AO3's UTC days) are dated from their work page; an old one that
    // got a chapter stays quiet.
    func test_followedAuthor_followedBeforeListLoaded_alertsOnlyForWorksPostedSince() async throws {
        let ctx = try makeContext()
        let followedAt = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: .now))
        let followDay = Calendar.current.startOfDay(for: followedAt)
        func day(_ offset: Int) -> Date { Calendar.current.date(byAdding: .day, value: offset, to: followDay)! }
        let author = FollowedAuthor(username: "prolific", displayName: "Prolific", followedAt: followedAt)
        ctx.insert(author)
        try ctx.save()
        let client = StubAO3Client()
        client.authorWorksResponse = AO3SearchResults(
            works: [authorWork(90, "Brand New", chapters: 3, updated: day(2)),
                    authorWork(10, "Old, Just Updated", chapters: 7, updated: day(1)),
                    authorWork(85, "Posted After A Follow East Of UTC", chapters: 2, updated: day(-1)),
                    authorWork(80, "Back Catalogue", chapters: 2, updated: day(-5)),
                    authorWork(70, updated: day(-40))],
            totalPages: 1, currentPage: 1)
        client.workPublishedAt = [90: day(2), 10: day(-400), 85: day(-1)]

        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        let notified = await poller.checkFollowedAuthors()
        XCTAssertEqual(notified, 2)
        // Only the works updated since the day before the follow were looked up.
        XCTAssertEqual(client.workMetadataCalls, [90, 10, 85])
        XCTAssertEqual(Set(author.knownWorkIds), [10, 70, 80, 85, 90])

        // With a baseline the usual rule applies, with no extra requests.
        client.authorWorksResponse = AO3SearchResults(
            works: [authorWork(95, "Next"), authorWork(10, chapters: 8, updated: .now)],
            totalPages: 1, currentPage: 1)
        let again = await poller.checkFollowedAuthors()
        XCTAssertEqual(again, 1)
        XCTAssertEqual(client.workMetadataCalls, [90, 10, 85])
    }

    // A new work whose page won't load isn't guessed at, and isn't lost: it
    // stays out of the baseline, so the next poll dates it again.
    func test_followedAuthor_noBaseline_undatableWorkIsDatedAgainNextPoll() async throws {
        let ctx = try makeContext()
        let author = FollowedAuthor(username: "quiet", displayName: "Quiet", followedAt: .now)
        ctx.insert(author)
        try ctx.save()
        let client = StubAO3Client()
        client.workMetadataHTML = "<html><body>Retry later</body></html>"
        client.authorWorksResponse = AO3SearchResults(
            works: [authorWork(5, updated: .now)], totalPages: 1, currentPage: 1)

        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        let notified = await poller.checkFollowedAuthors()
        XCTAssertEqual(notified, 0)
        XCTAssertEqual(author.knownWorkIds, [])

        client.workPublishedAt = [5: .now]
        let again = await poller.checkFollowedAuthors()
        XCTAssertEqual(again, 1)
        XCTAssertEqual(author.knownWorkIds, [5])
    }

    private func authorWork(_ id: Int, _ title: String = "", chapters: Int = 1, updated: Date? = nil) -> AO3WorkSummary {
        AO3WorkSummary(
            id: id, title: title, author: "", summary: "", rating: "",
            warnings: [], categories: [], fandoms: [], characters: [],
            relationships: [], freeforms: [], wordCount: 0, chapterCount: chapters,
            totalChapters: nil, language: "", kudos: 0, hits: 0,
            isComplete: false, updatedAt: updated
        )
    }

    // A check that gets an error or Cloudflare page instead of the work must
    // leave the new-chapter baselines alone; overwriting them with 1 would
    // send "N new chapters" on the next real check.
    func test_pollOfErrorPage_keepsChapterBaselines() async throws {
        let ctx = try makeContext()
        seedSubscriptionRecords(into: ctx)
        let followed = Work(ao3Id: 2, title: "Followed", authorName: "A")
        followed.isFollowed = true
        followed.lastSeenChapterCount = 11
        ctx.insert(followed)
        try ctx.save()
        let client = StubAO3Client()
        client.workMetadataHTML = "<html><body><h1>Retry later</h1></body></html>"

        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader", defaults: scratchDefaults())
        let subAlerts = await poller.checkForNewChapters()
        let workAlerts = await poller.checkFollowedWorks()

        XCTAssertEqual(subAlerts + workAlerts, 0)
        let rec = try ctx.fetch(FetchDescriptor<SubscriptionRecord>()).first(where: { $0.key == "work:1" })
        XCTAssertEqual(rec?.lastSeenChapterCount, 5)
        XCTAssertNotNil(rec?.lastCheckedAt)
        XCTAssertEqual(followed.lastSeenChapterCount, 11)
    }

    // A real work page still moves the baseline forward.
    func test_pollOfWorkPage_updatesChapterBaseline() async throws {
        let ctx = try makeContext()
        let followed = Work(ao3Id: 2, title: "Followed", authorName: "A")
        followed.isFollowed = true
        ctx.insert(followed)
        try ctx.save()
        let client = StubAO3Client()
        client.workMetadataHTML = #"<html><body><dl class="stats"><dt class="chapters">Chapters:</dt><dd class="chapters">7/?</dd></dl></body></html>"#

        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        _ = await poller.checkFollowedWorks()

        XCTAssertEqual(followed.lastSeenChapterCount, 7)
    }

    // A work that's both AO3-subscribed and followed is fetched once a poll,
    // alerts once, and both records take the new baseline (#148).
    func test_fullPoll_fetchesEachWorkOnce() async throws {
        let ctx = try makeContext()
        seedSubscriptionRecords(into: ctx)
        let both = Work(ao3Id: 1, title: "Fic One", authorName: "A")
        both.isFollowed = true
        both.lastSeenChapterCount = 4
        ctx.insert(both)
        let followed = Work(ao3Id: 2, title: "Followed", authorName: "A")
        followed.isFollowed = true
        ctx.insert(followed)
        try ctx.save()
        let client = StubAO3Client()
        client.subscriptionsResponse = [
            AO3Subscription(kind: .work, resourceId: "1", title: "Fic One", author: "A"),
            AO3Subscription(kind: .series, resourceId: "9", title: "Saga", author: "A"),
        ]
        client.workMetadataHTML = #"<html><body><dl class="stats"><dt class="chapters">Chapters:</dt><dd class="chapters">6/?</dd></dl></body></html>"#

        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader", defaults: scratchDefaults())
        let alerts = await poller.runFullPoll()

        // Work 1 alerts once (baselines 5 and 4); work 2 has no baseline yet.
        XCTAssertEqual(alerts, 1)
        XCTAssertEqual(client.workMetadataCalls.sorted(), [1, 2])
        let rec = try ctx.fetch(FetchDescriptor<SubscriptionRecord>()).first(where: { $0.key == "work:1" })
        XCTAssertEqual(rec?.lastSeenChapterCount, 6)
        XCTAssertNotNil(rec?.lastCheckedAt)
        XCTAssertEqual(both.lastSeenChapterCount, 6)
        XCTAssertNotNil(both.lastCheckedAt)
        XCTAssertEqual(followed.lastSeenChapterCount, 6)
    }

    // MARK: - Saved search alerts (#309)

    private func searchWork(_ id: Int, chapters: Int = 1, updated: Date? = nil, rating: String = "") -> AO3WorkSummary {
        AO3WorkSummary(
            id: id, title: "Fic \(id)", author: "", summary: "", rating: rating,
            warnings: [], categories: [], fandoms: [], characters: [],
            relationships: [], freeforms: [], wordCount: 0, chapterCount: chapters,
            totalChapters: nil, language: "", kudos: 0, hits: 0,
            isComplete: false, updatedAt: updated
        )
    }

    private func alertingSearch(in ctx: ModelContext, prompt: String = #"tag:"Slow Burn""#) throws -> SavedSearch {
        let search = SavedSearch(name: "Slow burn", prompt: prompt)
        ctx.insert(search)
        SavedSearchAlerts.setAlerts(true, for: search, context: ctx)
        try ctx.save()
        return search
    }

    // A check runs exactly the saved search, newest posted first.
    func test_savedSearchAlertFilters_runTheSearchByDatePosted() {
        let filters = SavedSearchAlerts.filters(prompt: #"teen wolf tag:"Slow Burn" complete:yes"#)
        XCTAssertEqual(filters.query, "teen wolf")
        XCTAssertEqual(filters.otherTagNames, ["Slow Burn"])
        XCTAssertEqual(filters.complete, .yes)
        // "teen" stays a keyword: search never guesses.
        XCTAssertTrue(filters.ratings.isEmpty)
        XCTAssertEqual(filters.sortColumn, .createdAt)
        XCTAssertEqual(filters.sortDirection, .desc)
    }

    // Turning alerts on never alerts for what the search already finds.
    func test_savedSearch_firstCheckOnlyTakesTheBaseline() async throws {
        let ctx = try makeContext()
        let search = try alertingSearch(in: ctx)
        let client = StubAO3Client()
        client.searchResponse = AO3SearchResults(works: [searchWork(30), searchWork(20)], totalPages: 1, currentPage: 1)

        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        let notified = await poller.checkSavedSearchAlerts()

        XCTAssertEqual(notified, 0)
        XCTAssertEqual(Set(search.alertKnownWorkIds), [20, 30])
        XCTAssertNotNil(search.alertsBaselineAt)
        XCTAssertNotNil(search.alertsLastCheckedAt)
        XCTAssertTrue(search.alertNewWorkIds.isEmpty)
        XCTAssertEqual(client.searchCalls.first?.sortColumn, .createdAt)
    }

    func test_savedSearch_alertsForNewlyPostedWorks() async throws {
        let ctx = try makeContext()
        let search = try alertingSearch(in: ctx)
        let client = StubAO3Client()
        client.searchResponse = AO3SearchResults(works: [searchWork(30), searchWork(20)], totalPages: 1, currentPage: 1)
        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        _ = await poller.checkSavedSearchAlerts()

        // 40 is new; 10 has four chapters and a lower id: an old work that
        // now matches the search, not a new one.
        client.searchResponse = AO3SearchResults(
            works: [searchWork(40), searchWork(30), searchWork(10, chapters: 4), searchWork(20)],
            totalPages: 1, currentPage: 1)
        let notified = await poller.checkSavedSearchAlerts()

        XCTAssertEqual(notified, 1)
        XCTAssertEqual(search.alertNewWorkIds, [40])
        XCTAssertEqual(Set(search.alertKnownWorkIds), [10, 20, 30, 40])

        // Nothing new: no alert, and the "New" count stays until it's seen.
        let again = await poller.checkSavedSearchAlerts()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(search.alertNewWorkIds, [40])
        SavedSearchAlerts.markSeen(search, context: ctx)
        XCTAssertTrue(search.alertNewWorkIds.isEmpty)
    }

    // Hidden works and (with that setting on) Mature and Explicit works
    // never alert, as they never show in the results list.
    func test_savedSearch_hiddenAndMatureWorksDontAlert() async throws {
        let ctx = try makeContext()
        let search = try alertingSearch(in: ctx)
        ctx.insert(HiddenWork(ao3Id: 41, title: "Hidden"))
        try ctx.save()
        let client = StubAO3Client()
        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        client.searchResponse = AO3SearchResults(works: [searchWork(30)], totalPages: 1, currentPage: 1)
        _ = await poller.checkSavedSearchAlerts()

        let key = ContentControl.filterMatureKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        client.searchResponse = AO3SearchResults(
            works: [searchWork(42, rating: "Explicit"), searchWork(41), searchWork(30)],
            totalPages: 1, currentPage: 1)
        let notified = await poller.checkSavedSearchAlerts()

        XCTAssertEqual(notified, 0)
        XCTAssertTrue(search.alertNewWorkIds.isEmpty)
        // Both still join the baseline, so they never alert later either.
        XCTAssertEqual(Set(search.alertKnownWorkIds), [30, 41, 42])
    }

    // Searches without alerts aren't checked at all.
    func test_savedSearch_withoutAlertsIsNeverChecked() async throws {
        let ctx = try makeContext()
        ctx.insert(SavedSearch(name: "Quiet", prompt: "fluff"))
        try ctx.save()
        let client = StubAO3Client()
        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        _ = await poller.runFullPoll()
        XCTAssertTrue(client.searchCalls.isEmpty)
    }

    // The Search tab only checks what the background hasn't for a while.
    func test_checkStaleSavedSearches_skipsRecentChecks() async throws {
        let ctx = try makeContext()
        let search = try alertingSearch(in: ctx)
        let client = StubAO3Client()
        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        _ = await poller.checkStaleSavedSearches()
        XCTAssertEqual(client.searchCalls.count, 1)
        _ = await poller.checkStaleSavedSearches()
        XCTAssertEqual(client.searchCalls.count, 1)
        _ = await poller.checkStaleSavedSearches(now: .now.addingTimeInterval(SavedSearchAlerts.foregroundCheckInterval + 1))
        XCTAssertEqual(client.searchCalls.count, 2)
        XCTAssertNotNil(search.alertsBaselineAt)
    }

    // Deleted while the search runs: the results belong to nothing, and the
    // deleted model isn't touched.
    func test_savedSearch_deletedMidCheck_isLeftAlone() async throws {
        let ctx = try makeContext()
        let search = try alertingSearch(in: ctx)
        let client = StubAO3Client()
        client.searchResponse = AO3SearchResults(works: [searchWork(30)], totalPages: 1, currentPage: 1)
        client.onSearch = {
            ctx.delete(search)
            try? ctx.save()
        }
        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        let notified = await poller.checkSavedSearch(search)
        XCTAssertEqual(notified, 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<SavedSearch>()), 0)
    }

    // Edited on the Search tab while a background check (its own context)
    // runs: the old search's results don't become the new one's baseline.
    func test_savedSearch_editedInAnotherContextMidCheck_keepsItsFreshBaseline() async throws {
        let ctx = try makeContext()
        let search = try alertingSearch(in: ctx)
        let client = StubAO3Client()
        client.searchResponse = AO3SearchResults(works: [searchWork(30)], totalPages: 1, currentPage: 1)
        client.onSearch = {
            let ui = ModelContext(ctx.container)
            guard let edited = try? ui.fetch(FetchDescriptor<SavedSearch>()).first else { return XCTFail("no search") }
            edited.prompt = "angst"
            SavedSearchAlerts.resetBaseline(of: edited)
            try? ui.save()
        }
        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        _ = await poller.checkSavedSearch(search)
        XCTAssertTrue(search.alertKnownWorkIds.isEmpty)
        XCTAssertNil(search.alertsBaselineAt)
    }

    // Only a check that read the results counts: a failed one or a guest page
    // (signed in, session expired: restricted works left out) leaves the
    // baseline and the last check alone, and only moves the poll rotation on.
    func test_savedSearch_failedAndGuestChecksDontCount() async throws {
        let ctx = try makeContext()
        let search = try alertingSearch(in: ctx)
        let client = StubAO3Client()
        client.searchResponse = AO3SearchResults(works: [searchWork(30)], totalPages: 1, currentPage: 1)
        let poller = SubscriptionPoller(client: client, context: ctx, username: "reader")
        _ = await poller.checkSavedSearch(search)
        let checkedAt = search.alertsLastCheckedAt
        XCTAssertNotNil(checkedAt)

        client.searchResponse = AO3SearchResults(works: [searchWork(50), searchWork(30)],
                                                 totalPages: 1, currentPage: 1, servedAsGuest: true)
        let guest = await poller.checkSavedSearch(search)
        XCTAssertEqual(guest, 0)
        XCTAssertEqual(search.alertKnownWorkIds, [30])
        XCTAssertEqual(search.alertsLastCheckedAt, checkedAt)

        client.searchError = URLError(.timedOut)
        let failed = await poller.checkSavedSearch(search)
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(search.alertsLastCheckedAt, checkedAt)
        XCTAssertNotNil(search.alertsAttemptedAt)
        XCTAssertTrue(search.alertNewWorkIds.isEmpty)
    }

    // A backup merge can bring in more alerting searches than one device
    // lets the reader switch on; the poll still runs at most the limit.
    func test_fullPoll_runsAtMostTheAlertLimit() async throws {
        let ctx = try makeContext()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(SavedSearchAlerts.maxAlertingSearches + 2) {
            let search = SavedSearch(name: "Search \(i)", prompt: "tag\(i)")
            search.alertsEnabled = true
            search.alertsChangedAt = t0.addingTimeInterval(Double(i) * 60)
            ctx.insert(search)
        }
        try ctx.save()
        let client = StubAO3Client()
        let poller = SubscriptionPoller(client: client, context: ctx, username: nil)
        _ = await poller.runFullPoll()
        XCTAssertEqual(client.searchCalls.count, SavedSearchAlerts.maxAlertingSearches)
        // The two switched on first are the ones left out.
        XCTAssertFalse(client.searchCalls.contains { $0.query == "tag0" || $0.query == "tag1" })
    }

    func test_savedSearchNewMatches_rules() {
        let lastCheck = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = lastCheck.addingTimeInterval(-3600)
        let old = lastCheck.addingTimeInterval(-30 * 24 * 3600)
        let works = [searchWork(70, chapters: 3), searchWork(58, updated: recent), searchWork(57, updated: old),
                     searchWork(56, chapters: 2, updated: recent), searchWork(60)]
        // 70 is newer than every seen work; 58 is a one-shot posted since the
        // last check (a draft or a revealed gift); 57 is an old one-shot and
        // 56 an old multi-chapter work that now match the search.
        XCTAssertEqual(SavedSearchAlerts.newMatches(in: works, known: [50, 60], baselined: true, lastCheckedAt: lastCheck).map(\.id),
                       [70, 58])
        // No baseline yet: never alert for what's already there.
        XCTAssertTrue(SavedSearchAlerts.newMatches(in: works, known: [], baselined: false, lastCheckedAt: nil).isEmpty)
        // A baseline of no results: everything that turns up is new.
        XCTAssertEqual(SavedSearchAlerts.newMatches(in: works, known: [], baselined: true, lastCheckedAt: lastCheck).count, 5)
    }

    func test_savedSearchBaseline_keepsTheNewestIds() {
        let many = Array(1...250)
        let kept = SavedSearchAlerts.baseline(many, adding: [300])
        XCTAssertEqual(kept.count, SavedSearchAlerts.knownWorkIdLimit)
        XCTAssertEqual(kept.first, 300)
        XCTAssertFalse(kept.contains(1))
    }

    // Editing a saved search starts its alerts over.
    func test_resetBaseline_forgetsWhatTheSearchSaw() throws {
        let ctx = try makeContext()
        let search = try alertingSearch(in: ctx)
        search.alertKnownWorkIds = [1, 2]
        search.alertsBaselineAt = .now
        search.alertNewWorkIds = [2]
        SavedSearchAlerts.resetBaseline(of: search)
        XCTAssertTrue(search.alertKnownWorkIds.isEmpty)
        XCTAssertNil(search.alertsBaselineAt)
        XCTAssertTrue(search.alertNewWorkIds.isEmpty)
        XCTAssertTrue(search.alertsEnabled)
    }

    func test_alertLimit() throws {
        let ctx = try makeContext()
        for i in 0..<SavedSearchAlerts.maxAlertingSearches {
            let search = SavedSearch(name: "S\(i)", prompt: "p\(i)")
            search.alertsEnabled = true
            ctx.insert(search)
        }
        ctx.insert(SavedSearch(name: "Off", prompt: "off"))
        try ctx.save()
        XCTAssertFalse(SavedSearchAlerts.canEnableMore(in: ctx))
    }

    // MARK: Saved search alert backup merge

    private func searchBackup(prompt: String = "angst", savedAt: Date, enabled: Bool? = true, changedAt: Date?,
                              known: [Int]?, baselineAt: Date? = nil, checkedAt: Date? = nil) -> SearchBackup {
        SearchBackup(name: "Angst", prompt: prompt, sortColumn: "_score", sortDirection: "desc", savedAt: savedAt,
                     alertsEnabled: enabled, alertsChangedAt: changedAt, alertKnownWorkIds: known,
                     alertsBaselineAt: baselineAt, alertsLastCheckedAt: checkedAt)
    }

    // Two devices running the same alerts: what either has seen stays seen,
    // so a restore never fires an alert again.
    func test_mergedSearch_sameAlertsUnionTheirBaselines() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let local = searchBackup(savedAt: t0, changedAt: t0, known: [1, 2], baselineAt: t0.addingTimeInterval(60),
                                 checkedAt: t0.addingTimeInterval(100))
        let other = searchBackup(savedAt: t0, changedAt: t0, known: [2, 3], baselineAt: t0.addingTimeInterval(30),
                                 checkedAt: t0.addingTimeInterval(200))
        let merged = iCloudSyncManager.mergedSearch(local: local, other: other)
        XCTAssertEqual(Set(merged.alertKnownWorkIds ?? []), [1, 2, 3])
        XCTAssertEqual(merged.alertsBaselineAt, t0.addingTimeInterval(30))
        XCTAssertEqual(merged.alertsLastCheckedAt, t0.addingTimeInterval(200))
        XCTAssertEqual(merged.alertsEnabled, true)
    }

    // Switching alerts off on one device switches them off everywhere.
    func test_mergedSearch_laterSwitchWins() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let local = searchBackup(savedAt: t0, enabled: true, changedAt: t0, known: [1, 2], baselineAt: t0)
        let other = searchBackup(savedAt: t0, enabled: nil, changedAt: t0.addingTimeInterval(60), known: nil)
        let merged = iCloudSyncManager.mergedSearch(local: local, other: other)
        XCTAssertNil(merged.alertsEnabled)
        XCTAssertEqual(merged.alertsChangedAt, t0.addingTimeInterval(60))
        XCTAssertNil(merged.alertKnownWorkIds)
        // And from the other side.
        XCTAssertNil(iCloudSyncManager.mergedSearch(local: other, other: local).alertsEnabled)
    }

    // An edited search takes the newer definition and that side's fresh
    // baseline, never the old prompt's seen works.
    func test_mergedSearch_editedSearchKeepsTheNewerBaseline() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let local = searchBackup(prompt: "angst", savedAt: t0, changedAt: t0, known: [1, 2], baselineAt: t0)
        let other = searchBackup(prompt: "angst complete:yes", savedAt: t0.addingTimeInterval(60), changedAt: t0, known: nil)
        let merged = iCloudSyncManager.mergedSearch(local: local, other: other)
        XCTAssertEqual(merged.prompt, "angst complete:yes")
        XCTAssertEqual(merged.savedAt, t0.addingTimeInterval(60))
        XCTAssertNil(merged.alertKnownWorkIds)
        XCTAssertNil(merged.alertsBaselineAt)
    }

    // A backup from before alerts existed leaves this device's alerts alone.
    func test_mergedSearch_olderBackupKeepsLocalAlerts() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let local = searchBackup(savedAt: t0, changedAt: t0, known: [5], baselineAt: t0)
        let legacy = SearchBackup(name: "Angst", prompt: "angst", sortColumn: "_score", sortDirection: "desc", savedAt: t0)
        let merged = iCloudSyncManager.mergedSearch(local: local, other: legacy)
        XCTAssertEqual(merged.alertsEnabled, true)
        XCTAssertEqual(merged.alertKnownWorkIds, [5])
        XCTAssertEqual(merged.alertsBaselineAt, t0)
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

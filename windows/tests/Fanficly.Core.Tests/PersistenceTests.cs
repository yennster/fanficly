using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Port of PersistenceTests.swift (the ReaderProfile merge/device-key
/// cases live with the ReaderProfile port).</summary>
public sealed class PersistenceTests : IDisposable
{
    private readonly List<string> _tempFiles = [];

    private static LibraryStore MakeContext() => LibraryStore.OpenInMemory();

    private static AO3WorkPayload Payload(int id, int chapters)
    {
        var summary = new AO3WorkSummary
        {
            Id = id, Title = $"Test Work {id}", Author = "tester",
            Summary = "A summary", Rating = "Mature", Warnings = ["No Archive Warnings Apply"],
            Categories = ["M/M"], Fandoms = ["Harry Potter - J. K. Rowling"],
            Characters = ["Harry Potter"], Relationships = ["Harry/Draco"],
            Freeforms = ["Fluff"], WordCount = 5000, ChapterCount = chapters,
            TotalChapters = chapters, Language = "English", Kudos = 100, Hits = 2000,
            IsComplete = true, UpdatedAt = null,
        };
        var chs = Enumerable.Range(1, chapters).Select(i => new AO3ChapterPayload(i, $"Ch {i}", $"<p>Body {i}</p>")).ToList();
        return new AO3WorkPayload(summary, chs);
    }

    /// <summary>A fresh "device": its own settings and a sync manager on a shared backup file.</summary>
    private LibrarySyncManager MakeSync(string backupPath, IKeyValueStore? settings = null) =>
        new(settings ?? new InMemoryKeyValueStore()) { BackupPathOverride = backupPath };

    private string MakeTempBackupPath()
    {
        var path = Path.Combine(Path.GetTempPath(), $"test_backup_{Guid.NewGuid()}.json");
        _tempFiles.Add(path);
        return path;
    }

    public void Dispose()
    {
        foreach (var f in _tempFiles)
        {
            try { File.Delete(f); } catch (IOException) { }
        }
    }

    [Fact]
    public void BackupSaysWhetherItWroteTheFile()
    {
        using var store = LibraryStore.OpenInMemory();
        Assert.Equal(BackupOutcome.NoFolder, new LibrarySyncManager(new InMemoryKeyValueStore()).Backup(store));

        var path = MakeTempBackupPath();
        var placeholder = Path.Combine(Path.GetDirectoryName(path)!, $".{Path.GetFileName(path)}.icloud");
        _tempFiles.Add(placeholder);
        File.WriteAllText(placeholder, "");
        Assert.Equal(BackupOutcome.NotDownloaded, MakeSync(path).Backup(store));
        Assert.False(File.Exists(path));

        File.Delete(placeholder);
        Assert.Equal(BackupOutcome.Written, MakeSync(path).Backup(store));
        Assert.True(File.Exists(path));
    }

    [Fact]
    public void UpsertInsertsThenUpdates()
    {
        using var ctx = MakeContext();
        var w1 = WorkPersistence.Upsert(Payload(1, 3), ctx);
        Assert.Equal(3, w1.Chapters.Count);
        Assert.Equal(["Harry Potter - J. K. Rowling"], w1.Fandoms);

        // Re-upsert with fewer chapters replaces them, no duplicate Work.
        var w2 = WorkPersistence.Upsert(Payload(1, 2), ctx);
        Assert.Equal(2, w2.Chapters.Count);
        Assert.Single(ctx.All<Work>());
    }

    // MARK: Result-row badges (RM-002)

    [Fact]
    public void ResultBadge_UnknownWorkHasNone()
    {
        Assert.Null(WorkPersistence.ResultBadgeFor(inLibrary: false, started: false, progress: null, isComplete: false));
        Assert.Null(WorkPersistence.ResultBadgeFor(inLibrary: false, started: false, progress: 0, isComplete: true));
    }

    [Fact]
    public void ResultBadge_SavedWorkReadsInLibrary() =>
        Assert.Equal<ResultBadge?>(ResultBadge.InLibrary, WorkPersistence.ResultBadgeFor(inLibrary: true, started: false, progress: null, isComplete: false));

    [Fact]
    public void ResultBadge_StartedWorkShowsPercent()
    {
        Assert.Equal<ResultBadge?>(ResultBadge.Read(42), WorkPersistence.ResultBadgeFor(inLibrary: true, started: true, progress: 0.42, isComplete: false));
        Assert.Equal<ResultBadge?>(ResultBadge.Read(42), WorkPersistence.ResultBadgeFor(inLibrary: false, started: true, progress: 0.42, isComplete: true));
        // A sliver of progress still reads as begun, never 0%.
        Assert.Equal<ResultBadge?>(ResultBadge.Read(1), WorkPersistence.ResultBadgeFor(inLibrary: false, started: true, progress: 0.001, isComplete: false));
        // Opened but no fraction yet.
        Assert.Equal<ResultBadge?>(ResultBadge.Started, WorkPersistence.ResultBadgeFor(inLibrary: true, started: true, progress: null, isComplete: false));
    }

    [Fact]
    public void ResultBadge_FinishedFollowsTheLibraryRule()
    {
        Assert.Equal<ResultBadge?>(ResultBadge.Finished, WorkPersistence.ResultBadgeFor(inLibrary: true, started: true, progress: 0.99, isComplete: false));
        Assert.Equal<ResultBadge?>(ResultBadge.Finished, WorkPersistence.ResultBadgeFor(inLibrary: false, started: true, progress: 1.4, isComplete: false));
        // 95% finishes a complete work but not a work in progress.
        Assert.Equal<ResultBadge?>(ResultBadge.Finished, WorkPersistence.ResultBadgeFor(inLibrary: false, started: true, progress: 0.96, isComplete: true));
        Assert.Equal<ResultBadge?>(ResultBadge.Read(96), WorkPersistence.ResultBadgeFor(inLibrary: false, started: true, progress: 0.96, isComplete: false));
    }

    [Fact]
    public void ResultBadges_LookUpAPage()
    {
        using var ctx = MakeContext();
        // 1: saved, never read. 2: saved and half read. 3: read without saving.
        // 4: opened without saving, no fraction. 5: unknown.
        WorkPersistence.UpsertMetadata(Payload(1, 1).Summary, ctx);
        var half = WorkPersistence.UpsertMetadata(Payload(2, 4).Summary, ctx);
        half.LastReadProgress = 0.5;
        half.LastReadAt = DateTimeOffset.Now;
        ctx.Insert(new ReadingProgress(3, chapterIndex: 2));
        ctx.Insert(new ReadingStat(3, maxProgress: 1, workIsComplete: true));
        ctx.Insert(new ReadingProgress(4));

        var page = Enumerable.Range(1, 5).Select(id => Payload(id, 1).Summary).ToList();
        var badges = WorkPersistence.ResultBadges(page, ctx);
        Assert.Equal<ResultBadge?>(ResultBadge.InLibrary, badges[1]);
        Assert.Equal<ResultBadge?>(ResultBadge.Read(50), badges[2]);
        Assert.Equal<ResultBadge?>(ResultBadge.Finished, badges[3]);
        Assert.Equal<ResultBadge?>(ResultBadge.Started, badges[4]);
        Assert.False(badges.ContainsKey(5));
        Assert.Empty(WorkPersistence.ResultBadges([], ctx));
    }

    [Fact]
    public void ToggleFollowAuthor()
    {
        using var ctx = MakeContext();
        Assert.False(WorkPersistence.IsAuthorFollowed("tester", ctx));

        // Following seeds the already-published work ids so the poller won't
        // alert for the back catalogue on its first check.
        var nowFollowed = WorkPersistence.ToggleFollowAuthor("tester", "Tester", ctx, seedWorkIds: [1, 2, 3]);
        Assert.True(nowFollowed);
        Assert.True(WorkPersistence.IsAuthorFollowed("tester", ctx));

        var followed = ctx.All<FollowedAuthor>();
        Assert.Single(followed);
        Assert.Equal("Tester", followed[0].DisplayName);
        Assert.Equal([1, 2, 3], followed[0].KnownWorkIds.Order());

        var nowUnfollowed = WorkPersistence.ToggleFollowAuthor("tester", "Tester", ctx);
        Assert.False(nowUnfollowed);
        Assert.False(WorkPersistence.IsAuthorFollowed("tester", ctx));
        Assert.Empty(ctx.All<FollowedAuthor>());
    }

    /// <summary>An empty username (anonymous byline) can't be followed.</summary>
    [Fact]
    public void FollowAuthorIgnoresEmptyUsername()
    {
        using var ctx = MakeContext();
        var followed = WorkPersistence.ToggleFollowAuthor("", "Anonymous", ctx);
        Assert.False(followed);
        Assert.Empty(ctx.All<FollowedAuthor>());
    }

    [Fact]
    public void UpsertMetadataDoesNotTouchChapters()
    {
        using var ctx = MakeContext();
        WorkPersistence.Upsert(Payload(7, 4), ctx);
        var summary = Payload(7, 4).Summary;
        var w = WorkPersistence.UpsertMetadata(summary, ctx);
        Assert.Equal(4, w.Chapters.Count); // metadata upsert must keep existing chapters
    }

    [Fact]
    public void ToggleFollow()
    {
        using var ctx = MakeContext();
        var summary = Payload(9, 1).Summary;
        Assert.False(WorkPersistence.IsFollowed(9, ctx));

        Assert.True(WorkPersistence.ToggleFollow(summary, ctx));
        Assert.True(WorkPersistence.IsFollowed(9, ctx));

        Assert.False(WorkPersistence.ToggleFollow(summary, ctx));
        Assert.False(WorkPersistence.IsFollowed(9, ctx));
    }

    [Fact]
    public void RecordViewInsertsBumpsAndTrims()
    {
        using var ctx = MakeContext();
        // First view inserts.
        WorkPersistence.RecordView(Payload(1, 1).Summary, ctx);
        WorkPersistence.RecordView(Payload(2, 1).Summary, ctx);
        Assert.Equal(2, ctx.Count<RecentlyViewed>());

        // Re-viewing id 1 bumps it to the front without duplicating.
        WorkPersistence.RecordView(Payload(1, 1).Summary, ctx);
        var ordered = ctx.RecentlyViewedNewestFirst();
        Assert.Equal(2, ordered.Count);
        Assert.Equal(1, ordered[0].Ao3Id);

        // Trims to the newest `limit`.
        for (var id = 100; id < 110; id++) WorkPersistence.RecordView(Payload(id, 1).Summary, ctx, limit: 3);
        Assert.Equal(3, ctx.Count<RecentlyViewed>());
    }

    [Fact]
    public void ReadingProgressRoundTrips()
    {
        using var ctx = MakeContext();
        Assert.Null(ReadingProgressStore.Load(42, ctx));

        ReadingProgressStore.Save(42, chapter: 5, paragraph: 12, title: "T", author: "A", ctx);
        var a = ReadingProgressStore.Load(42, ctx);
        Assert.Equal(5, a?.Chapter);
        Assert.Equal(12, a?.Paragraph);

        // Saving again updates in place (no duplicate row).
        ReadingProgressStore.Save(42, chapter: 6, paragraph: 0, title: "T", author: "A", ctx);
        Assert.Equal(6, ReadingProgressStore.Load(42, ctx)?.Chapter);
        Assert.Equal(1, ctx.Count<ReadingProgress>());
    }

    // MARK: - Reading stats

    private static DateTimeOffset Day(int year, int month, int dayOfMonth) =>
        ReadingStatsAggregator.StartOfDay(new DateTime(year, month, dayOfMonth), TimeZoneInfo.Local);

    [Fact]
    public void ReadingStatsStore_AccumulatesAndBucketsByDay()
    {
        using var ctx = MakeContext();
        var d1 = Day(2026, 6, 15);
        var d2 = Day(2026, 6, 16);

        ReadingStatsStore.Record(7, "T", "A", ["Fandom X"], ["M/M"], ["A/B"], "Teen", 5000, 600, ctx, progress: 0.3, date: d1);
        // Second read, same work, same day → accrues onto the one bucket.
        ReadingStatsStore.Record(7, "T", "A", ["Fandom X"], ["M/M"], ["A/B"], "Teen", 5000, 300, ctx, progress: 0.8, date: d1);
        // Same work read on a new day → new day bucket, same row. Progress went
        // backward this read (re-skim); the stored max must not regress.
        ReadingStatsStore.Record(7, "T", "A", [], [], [], "", 0, 120, ctx, progress: 0.5, date: d2);

        var rows = ctx.All<ReadingStat>();
        Assert.Single(rows);
        var row = rows[0];
        Assert.Equal(1020, row.TotalSeconds, 3);
        Assert.Equal(900, row.DaySeconds.GetValueOrDefault(ReadingStatsAggregator.DayKey(d1)), 3);
        Assert.Equal(120, row.DaySeconds.GetValueOrDefault(ReadingStatsAggregator.DayKey(d2)), 3);
        // Empty metadata on the later read must not wipe the snapshot.
        Assert.Equal(["Fandom X"], row.Fandoms);
        Assert.Equal(5000, row.WordCount);
        // Progress is the furthest reached (0.8), never a later lower value.
        Assert.Equal(0.8, row.MaxProgress, 3);
    }

    [Fact]
    public void ReadingStatsAggregator_WordsFollowProgressAndStoriesCountFinished()
    {
        var d = Day(2026, 6, 10);
        var key = ReadingStatsAggregator.DayKey(d);
        ReadingStatSnapshot Snap(int id, int words, double progress, bool complete = false) =>
            new(id, "", "A", [], [], [], "", words, d, d, 60, new Dictionary<string, double> { [key] = 60 }, progress, complete);
        ReadingStatSnapshot[] snaps =
        [
            Snap(1, 10_000, 1.0),               // finished → 10k words
            Snap(2, 10_000, 0.25),              // a quarter read → 2.5k words, not finished
            Snap(3, 4_000, 0.96, complete: true), // complete work at 96% → finished
        ];
        var all = ReadingStatsAggregator.Summarize(snaps, null);
        // Words read tracks progress, not full length: 10000 + 2500 + 3840.
        Assert.Equal(16_340, all.TotalWords);
        // Only the two finished works count as stories read.
        Assert.Equal(2, all.StoriesRead);
    }

    // MARK: Yearly reading goal (RM-011)

    private static DateTimeOffset Utc(int year, int month, int dayOfMonth, int hour = 0) =>
        new(year, month, dayOfMonth, hour, 0, 0, TimeSpan.Zero);

    [Fact]
    public void GoalProgress_AtYearStartIsOnPace()
    {
        var p = ReadingStatsAggregator.GoalProgress(0, 52, Utc(2026, 1, 1, hour: 1), TimeZoneInfo.Utc);
        Assert.NotNull(p);
        Assert.Equal(0, p.Expected);
        Assert.Equal(0, p.Ahead);
        Assert.Equal(0, p.Fraction, 4);
        Assert.False(p.IsComplete);
        Assert.Equal("On pace", p.PaceLabel);
    }

    [Fact]
    public void GoalProgress_MidYearReportsAheadAndBehind()
    {
        // July 2 2026 00:00 UTC is 182 of 365 days in: an even pace of 24 a
        // year expects 11 (11.97 rounded down).
        var mid = Utc(2026, 7, 2);
        var onPace = ReadingStatsAggregator.GoalProgress(11, 24, mid, TimeZoneInfo.Utc);
        Assert.NotNull(onPace);
        Assert.Equal(11, onPace.Expected);
        Assert.Equal("On pace", onPace.PaceLabel);
        Assert.Equal(11.0 / 24.0, onPace.Fraction, 4);

        var ahead = ReadingStatsAggregator.GoalProgress(14, 24, mid, TimeZoneInfo.Utc);
        Assert.NotNull(ahead);
        Assert.Equal(3, ahead.Ahead);
        Assert.Equal("3 ahead", ahead.PaceLabel);

        var behind = ReadingStatsAggregator.GoalProgress(9, 24, mid, TimeZoneInfo.Utc);
        Assert.NotNull(behind);
        Assert.Equal(-2, behind.Ahead);
        Assert.Equal("2 behind", behind.PaceLabel);
    }

    [Fact]
    public void GoalProgress_PastTheGoalIsCompleteWithAFullRing()
    {
        var p = ReadingStatsAggregator.GoalProgress(30, 20, Utc(2026, 9, 1), TimeZoneInfo.Utc);
        Assert.NotNull(p);
        Assert.True(p.IsComplete);
        Assert.Equal(1, p.Fraction, 4);
        Assert.Equal("Goal reached", p.PaceLabel);
    }

    [Fact]
    public void GoalProgress_ZeroGoalIsHidden()
    {
        Assert.Null(ReadingStatsAggregator.GoalProgress(5, 0, Utc(2026, 6, 1), TimeZoneInfo.Utc));
        Assert.Null(ReadingStatsAggregator.GoalProgress(5, -3, Utc(2026, 6, 1), TimeZoneInfo.Utc));
    }

    [Fact]
    public void Backfill_SeedsZeroTimeStatsFromHistory()
    {
        using var ctx = MakeContext();
        var read = Day(2026, 5, 10);

        // A saved work the user finished (metadata + saved progress available)…
        var work = new Work(11, "Saved Read", "Alice", categories: ["M/M"], fandoms: ["Fandom X"],
                            relationships: ["A/B"], wordCount: 4000)
        {
            LastReadAt = read,
            LastReadProgress = 1.0,
        };
        ctx.Insert(work);
        ctx.Insert(new ReadingProgress(11, chapterIndex: 3, title: "Saved Read", author: "Alice", updatedAt: read));
        // …and a work read but never saved (progress only, no metadata/progress).
        ctx.Insert(new ReadingProgress(22, chapterIndex: 1, title: "Unsaved Read", author: "Bob", updatedAt: read));

        Assert.Equal(2, ReadingStatsBackfill.Backfill(ctx));

        var stats = ctx.All<ReadingStat>().OrderBy(s => s.Ao3Id).ToList();
        Assert.Equal([11, 22], stats.Select(s => s.Ao3Id));

        var saved = stats[0];
        Assert.Equal("Saved Read", saved.Title);
        Assert.Equal(["Fandom X"], saved.Fandoms);
        Assert.Equal(4000, saved.WordCount);
        // Progress carried over from the saved reading position.
        Assert.Equal(1.0, saved.MaxProgress, 3);
        // Time stays honest at zero, but a zero day bucket dates the read.
        Assert.Equal(0, saved.TotalSeconds, 3);
        Assert.Equal(0, saved.DaySeconds[ReadingStatsAggregator.DayKey(read)]);

        var snaps = stats.Select(s => s.Snapshot).ToList();
        var all = ReadingStatsAggregator.Summarize(snaps, null);
        // Only the finished work counts as a story read; words follow progress.
        Assert.Equal(1, all.StoriesRead);
        Assert.Equal(4000, all.TotalWords);
        Assert.Equal(0, all.TotalSeconds, 3);

        // Backfilled works still appear in the period containing their read day
        // (the yearly-wrap path), even with zero recorded time.
        var may = DateSpan.Of(StatsCalendarUnit.Month, read);
        var month = ReadingStatsAggregator.Summarize(snaps, may);
        Assert.Equal(1, month.StoriesRead);
        Assert.Equal("Fandom X", month.TopFandoms.FirstOrDefault().Name);
    }

    [Fact]
    public void Backfill_SkipsWorksThatAlreadyHaveStats()
    {
        using var ctx = MakeContext();
        var d = Day(2026, 4, 1);
        // A real, timed stat already exists for this work…
        ReadingStatsStore.Record(11, "T", "Alice", ["Fandom X"], [], [], "Teen", 4000, 600, ctx, date: d);
        // …and there's also reading history for it.
        ctx.Insert(new ReadingProgress(11, chapterIndex: 2, title: "T", author: "Alice"));

        Assert.Equal(0, ReadingStatsBackfill.Backfill(ctx));
        var rows = ctx.All<ReadingStat>();
        Assert.Single(rows);
        // The real recorded time must be left untouched.
        Assert.Equal(600, rows[0].TotalSeconds, 3);
    }

    [Fact]
    public void Backfill_EnrichesExistingRowMissingProgress()
    {
        using var ctx = MakeContext();
        var read = Day(2026, 3, 20);
        // A stat row created before progress was tracked: real time, but
        // MaxProgress defaulted to 0 — so it'd wrongly show 0 words / 0 stories.
        ReadingStatsStore.Record(11, "T", "Alice", ["Fandom X"], [], [], "Teen", 8000, 1800, ctx, date: read);
        Assert.Equal(0, ctx.All<ReadingStat>()[0].MaxProgress);

        // The reading progress the user already has: finished this work.
        ctx.Insert(new Work(11, "T", "Alice", wordCount: 8000) { LastReadAt = read, LastReadProgress = 1.0 });
        ctx.Insert(new ReadingProgress(11, chapterIndex: 1, title: "T", author: "Alice", updatedAt: read));

        // Enrichment inserts no new row but fills in the missing progress…
        Assert.Equal(0, ReadingStatsBackfill.Backfill(ctx));
        var row = Assert.Single(ctx.All<ReadingStat>());
        Assert.Equal(1.0, row.MaxProgress, 3);
        Assert.Equal(1800, row.TotalSeconds, 3); // time untouched
        // …so it now counts as a finished story with its full words read.
        var all = ReadingStatsAggregator.Summarize([row.Snapshot], null);
        Assert.Equal(1, all.StoriesRead);
        Assert.Equal(8000, all.TotalWords);
    }

    [Fact]
    public void Backfill_RunIfNeededIsOneTime()
    {
        using var ctx = MakeContext();
        var defaults = new InMemoryKeyValueStore();
        ctx.Insert(new ReadingProgress(11, chapterIndex: 1, title: "One", author: "A"));

        ReadingStatsBackfill.RunIfNeeded(ctx, defaults);
        Assert.Equal(1, ctx.Count<ReadingStat>());

        // New history arrives after the one-shot pass; RunIfNeeded is now a no-op.
        ctx.Insert(new ReadingProgress(22, chapterIndex: 1, title: "Two", author: "B"));
        ReadingStatsBackfill.RunIfNeeded(ctx, defaults);
        Assert.Equal(1, ctx.Count<ReadingStat>());
    }

    [Fact]
    public void ReadingStatsAggregator_SummarizeByPeriod()
    {
        string Key(DateTimeOffset d) => ReadingStatsAggregator.DayKey(d);
        ReadingStatSnapshot[] snaps =
        [
            new(1, "", "Alice", ["HP", "Naruto"], ["M/M"], ["A/B"], "Teen", 1000,
                Day(2026, 6, 15), Day(2026, 6, 15), 600,
                new Dictionary<string, double> { [Key(Day(2026, 6, 15))] = 600 }, MaxProgress: 1.0),
            new(2, "", "Alice", ["HP"], ["F/M"], ["C/D"], "Mature", 2000,
                Day(2025, 3, 2), Day(2025, 3, 2), 1200,
                new Dictionary<string, double> { [Key(Day(2025, 3, 2))] = 1200 }, MaxProgress: 1.0),
        ];

        // All-time.
        var all = ReadingStatsAggregator.Summarize(snaps, null);
        Assert.Equal(2, all.StoriesRead);
        Assert.Equal(1800, all.TotalSeconds, 3);
        Assert.Equal(3000, all.TotalWords);
        Assert.Equal("HP", all.TopFandoms[0].Name);
        Assert.Equal(2, all.TopFandoms[0].Count);
        Assert.Equal("Alice", all.TopAuthors[0].Name);

        // June 2026 (month) → only the first work.
        var june = DateSpan.Of(StatsCalendarUnit.Month, Day(2026, 6, 15));
        var month = ReadingStatsAggregator.Summarize(snaps, june);
        Assert.Equal(1, month.StoriesRead);
        Assert.Equal(600, month.TotalSeconds, 3);
        Assert.Equal(1000, month.TotalWords);

        // 2025 (year) → only the second work.
        var year2025 = DateSpan.Of(StatsCalendarUnit.Year, Day(2025, 3, 2));
        var year = ReadingStatsAggregator.Summarize(snaps, year2025);
        Assert.Equal(1, year.StoriesRead);
        Assert.Equal(1200, year.TotalSeconds, 3);

        // A period with no reads is empty.
        var june2024 = DateSpan.Of(StatsCalendarUnit.Month, Day(2024, 6, 15));
        Assert.Equal(ReadingStatsSummary.Empty, ReadingStatsAggregator.Summarize(snaps, june2024));

        // Data range spans the earliest to latest reading day.
        var range = ReadingStatsAggregator.DataDateRange(snaps);
        Assert.Equal(Day(2025, 3, 2), range?.Lower);
        Assert.Equal(Day(2026, 6, 15), range?.Upper);

        Assert.Equal(ReadingStatsSummary.Empty, ReadingStatsAggregator.Summarize([], null));
    }

    [Fact]
    public void ReadingStatsAggregator_RankOrdersByCountThenName()
    {
        var ranked = ReadingStatsAggregator.Rank(["B", "A", "A", "B", "C", "B", " "], topCount: 2);
        Assert.Equal(["B", "A"], ranked.Select(r => r.Name));
        Assert.Equal(3, ranked[0].Count);
        // Whitespace-only names are ignored.
        Assert.DoesNotContain(ranked, r => r.Name.Trim().Length == 0);
    }

    [Fact]
    public void StatsFormatting()
    {
        Assert.Equal("0m", StatsFormat.FormatDuration(0));
        Assert.Equal("<1m", StatsFormat.FormatDuration(30));
        Assert.Equal("45m", StatsFormat.FormatDuration(45 * 60));
        Assert.Equal("1h", StatsFormat.FormatDuration(3600));
        Assert.Equal("1h 34m", StatsFormat.FormatDuration(3600 + 34 * 60));
        // Compact branches are culture-independent (the <10K branch uses a
        // grouping separator that varies by culture, so it isn't asserted here).
        Assert.Equal("12K", StatsFormat.FormatWords(12_000));
        Assert.Equal("2.5M", StatsFormat.FormatWords(2_500_000));
    }

    /// <summary>Settings ride in the backup and are restored, with reader
    /// profiles going through the merge hook (the real merge is ReaderProfile's,
    /// tested with that port) rather than a plain overwrite.</summary>
    [Fact]
    public async Task SyncRestoresSettings()
    {
        using var ctx = MakeContext();
        var path = MakeTempBackupPath();
        var defaults = new InMemoryKeyValueStore();
        var published = new List<string>();
        var sync = MakeSync(path, defaults);
        sync.MergeReaderProfiles = (local, incoming) => $"{local}+{incoming}";
        sync.PublishReaderProfiles = published.Add;

        // 1. Settings on this device.
        defaults.SetString("reader.theme", "sepia");
        defaults.SetString("reader.fontFamily", "rounded");
        defaults.SetString("reader.width", "wide");
        defaults.SetDouble("reader.fontSizePt", 22.0);
        defaults.SetBool("content.filterMatureExplicit", true);
        // Device-specific settings.
        defaults.SetString("reader.theme.pad", "dracula");
        defaults.SetString("reader.activeProfile.pad", "compact");
        defaults.SetDouble("reader.fontSizePt.pad", 18.0);
        defaults.SetString("reader.profiles", "[Mac]");

        // 2. Back up.
        sync.Backup(ctx);

        // 3. Reset settings.
        foreach (var key in new[] { "reader.theme", "reader.fontFamily", "reader.width", "reader.fontSizePt",
                                    "content.filterMatureExplicit", "reader.theme.pad", "reader.activeProfile.pad",
                                    "reader.fontSizePt.pad" })
            defaults.Remove(key);
        defaults.SetString("reader.profiles", "[iPhone]");
        Assert.Null(defaults.GetString("reader.theme"));
        Assert.Null(defaults.GetString("reader.theme.pad"));

        // 4. Restore.
        Assert.True(await sync.RestoreAsync(ctx));

        // 5. Verify.
        Assert.Equal("sepia", defaults.GetString("reader.theme"));
        Assert.Equal("rounded", defaults.GetString("reader.fontFamily"));
        Assert.Equal("wide", defaults.GetString("reader.width"));
        Assert.Equal(22.0, defaults.GetDouble("reader.fontSizePt"));
        Assert.True(defaults.GetBool("content.filterMatureExplicit"));
        Assert.Equal("dracula", defaults.GetString("reader.theme.pad"));
        Assert.Equal("compact", defaults.GetString("reader.activeProfile.pad"));
        Assert.Equal(18.0, defaults.GetDouble("reader.fontSizePt.pad"));
        // Profiles merged (local + incoming), stored and published.
        Assert.Equal("[iPhone]+[Mac]", defaults.GetString("reader.profiles"));
        Assert.Equal(["[iPhone]+[Mac]"], published);
    }

    // MARK: - Backup/restore merge rules

    private static LibraryBackup DecodeBackup(string path) => LibraryBackupJson.Decode(File.ReadAllBytes(path));

    /// <summary>A device holding only part of the library must union with the
    /// backup, not overwrite it (the "laptop with 5 works clobbers the phone's
    /// 50" data-loss scenario).</summary>
    [Fact]
    public void BackupUnionsWithExistingCloudBackup()
    {
        var path = MakeTempBackupPath();

        // The "phone": three works, backed up first.
        using var phone = MakeContext();
        for (var id = 1; id <= 3; id++) WorkPersistence.Upsert(Payload(id, 2), phone);
        MakeSync(path).Backup(phone);
        Assert.Equal(3, DecodeBackup(path).Works.Count);

        // The "PC": holds only work 4. Its backup must keep the other three.
        using var pc = MakeContext();
        WorkPersistence.Upsert(Payload(4, 1), pc);
        MakeSync(path).Backup(pc);

        Assert.Equal([1, 2, 3, 4], DecodeBackup(path).Works.Select(w => w.Ao3Id));
    }

    /// <summary>A backup file that's there but won't decode (truncated, or a
    /// newer app's format) is left alone: writing this library over it would
    /// drop every other device's records (#125).</summary>
    [Fact]
    public void BackupSkipsAnUnreadableBackupAndLeavesItUntouched()
    {
        var path = MakeTempBackupPath();
        _tempFiles.Add(LibrarySyncManager.PreviousBackupPath(path));
        using var store = MakeContext();
        WorkPersistence.Upsert(Payload(1, 1), store);

        foreach (var garbage in new[] { "", "not json", """{"works":[{"ao3Id":1}]""" })
        {
            File.WriteAllText(path, garbage);
            var sync = MakeSync(path);
            Assert.Equal(BackupOutcome.Unreadable, sync.Backup(store));
            Assert.Equal(garbage, File.ReadAllText(path));
            Assert.NotNull(sync.LastBackupError);
        }
        Assert.False(File.Exists(LibrarySyncManager.PreviousBackupPath(path)));
    }

    /// <summary>Each write keeps the file it replaces as library_backup.prev.json,
    /// and Clear removes both.</summary>
    [Fact]
    public void BackupKeepsThePreviousFileAndClearRemovesIt()
    {
        var path = MakeTempBackupPath();
        var prev = LibrarySyncManager.PreviousBackupPath(path);
        _tempFiles.Add(prev);
        using var store = MakeContext();
        WorkPersistence.Upsert(Payload(1, 1), store);
        var sync = MakeSync(path);

        sync.Backup(store);
        Assert.False(File.Exists(prev));
        var first = File.ReadAllBytes(path);

        WorkPersistence.Upsert(Payload(2, 1), store);
        sync.Backup(store);
        Assert.Equal(first, File.ReadAllBytes(prev));
        Assert.Equal([1, 2], DecodeBackup(path).Works.Select(w => w.Ao3Id));

        Assert.True(sync.Clear());
        Assert.False(File.Exists(path));
        Assert.False(File.Exists(prev));
    }

    /// <summary>The Apple app writes fields this one doesn't know (notes and
    /// personal tags, newer settings, whatever comes later). A PC backup that
    /// merges with its file keeps them, while the PC's own values still win
    /// where it has them (#126).</summary>
    [Fact]
    public void BackupKeepsKeysOnlyTheOtherAppKnows()
    {
        var path = MakeTempBackupPath();
        File.WriteAllText(path, """
            {"works":[{"ao3Id":1,"title":"Mac Title","authorName":"A","authorUsername":"","summary":"","rating":"Not Rated","warnings":[],"categories":[],"fandoms":[],"characters":[],"relationships":[],"freeforms":[],"language":"en","wordCount":0,"chapterCount":1,"kudos":0,"hits":0,"bookmarksCount":0,"commentsCount":0,"isComplete":false,"savedAt":"2026-01-01T00:00:00Z","isFollowed":false,"note":"Reread before the sequel","personalTags":["comfort","reread"],"notesUpdatedAt":"2026-06-01T00:00:00Z","chapters":[{"index":1,"title":"Ch","bodyHTML":"<p>x<\/p>","futureChapterField":7}]},
              {"ao3Id":2,"title":"Mac Only","authorName":"B","authorUsername":"","summary":"","rating":"Not Rated","warnings":[],"categories":[],"fandoms":[],"characters":[],"relationships":[],"freeforms":[],"language":"en","wordCount":0,"chapterCount":1,"kudos":0,"hits":0,"bookmarksCount":0,"commentsCount":0,"isComplete":false,"savedAt":"2026-01-01T00:00:00Z","isFollowed":false,"note":"Mac-only note","chapters":[]}],
             "bookmarks":[],"subscriptions":[],"searches":[],"progress":[],"filters":[],"hidden":[{"ao3Id":9,"title":"Nope","hiddenAt":"2026-01-01T00:00:00Z","futureReason":"spoilers"}],
             "settings":{"themePhone":"sepia","fontSizePtMac":18,"futureSetting":true,"theme":"night"},
             "futureList":[{"id":1}],"timestamp":"2026-01-01T00:00:00Z"}
            """);

        using var pc = MakeContext();
        WorkPersistence.Upsert(Payload(1, 1), pc); // "Test Work 1": the PC's title wins
        pc.Insert(new HiddenWork(9, "Nope", DateTimeOffset.UnixEpoch));
        pc.Save();
        var settings = new InMemoryKeyValueStore();
        settings.SetString("reader.theme", "dracula");
        Assert.Equal(BackupOutcome.Written, MakeSync(path, settings).Backup(pc));

        using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(path));
        var root = doc.RootElement;
        var works = root.GetProperty("works").EnumerateArray().ToList();
        var shared = works.Single(w => w.GetProperty("ao3Id").GetInt32() == 1);
        Assert.Equal("Test Work 1", shared.GetProperty("title").GetString());
        Assert.Equal("Reread before the sequel", shared.GetProperty("note").GetString());
        Assert.Equal(["comfort", "reread"], shared.GetProperty("personalTags").EnumerateArray().Select(t => t.GetString()));
        Assert.Equal("2026-06-01T00:00:00Z", shared.GetProperty("notesUpdatedAt").GetString());
        Assert.Equal(7, shared.GetProperty("chapters")[0].GetProperty("futureChapterField").GetInt32());
        Assert.Equal("Mac-only note", works.Single(w => w.GetProperty("ao3Id").GetInt32() == 2).GetProperty("note").GetString());
        Assert.Equal("spoilers", root.GetProperty("hidden")[0].GetProperty("futureReason").GetString());
        var merged = root.GetProperty("settings");
        Assert.Equal("dracula", merged.GetProperty("theme").GetString());
        Assert.Equal("sepia", merged.GetProperty("themePhone").GetString());
        Assert.Equal(18, merged.GetProperty("fontSizePtMac").GetInt32());
        Assert.True(merged.GetProperty("futureSetting").GetBoolean());
        Assert.Equal(1, root.GetProperty("futureList")[0].GetProperty("id").GetInt32());
        // And the file still reads back.
        Assert.Equal(2, DecodeBackup(path).Works.Count);
    }

    /// <summary>A backup that merges in another device's records puts them in
    /// the file, not in this library, so it must not stamp the file as applied
    /// here: the next launch sync still has to restore them (#124). The iPad's
    /// file can arrive dated after the PC's last write or, when it was written
    /// offline or by a device whose clock runs behind, before it.</summary>
    [Theory]
    [InlineData(5)]
    [InlineData(-60)]
    public async Task BackupAfterAnotherDeviceStillRestoresItsRecordsAtLaunch(int padFileOffsetSeconds)
    {
        var path = MakeTempBackupPath();

        // The PC backs up first and stamps the file it wrote.
        using var pc = MakeContext();
        WorkPersistence.Upsert(Payload(1, 1), pc);
        var pcSync = MakeSync(path);
        pcSync.Backup(pc);
        Assert.False(pcSync.CloudBackupHasUnappliedChanges);
        var pcStamp = pcSync.LastBackupDate!.Value;

        // The iPad saves five works and backs up later.
        using var pad = MakeContext();
        for (var id = 10; id <= 14; id++) WorkPersistence.Upsert(Payload(id, 1), pad);
        MakeSync(path).Backup(pad);
        File.SetLastWriteTimeUtc(path, pcStamp.UtcDateTime.AddSeconds(padFileOffsetSeconds));

        // Back on the PC (still open): starring something backs up again,
        // merging the iPad's works into the file but not into the PC's library.
        var starred = pc.GetWork(1)!;
        starred.IsStarred = true;
        pc.Save();
        Assert.Equal(BackupOutcome.Written, pcSync.Backup(pc));
        Assert.Equal(6, DecodeBackup(path).Works.Count);
        Assert.Single(pc.All<Work>());

        // So the PC's next launch still restores, and gets the iPad's works.
        Assert.True(pcSync.CloudBackupHasUnappliedChanges);
        Assert.True(await pcSync.RestoreAsync(pc));
        Assert.Equal([1, 10, 11, 12, 13, 14], pc.All<Work>().Select(w => w.Ao3Id).Order());
        Assert.False(pcSync.CloudBackupHasUnappliedChanges);

        // Once applied, the PC's own backups stamp the file again.
        pcSync.Backup(pc);
        Assert.False(pcSync.CloudBackupHasUnappliedChanges);
    }

    [Fact]
    public async Task SyncNowBringsInAnotherDevicesChangesThenBacksUp()
    {
        var path = MakeTempBackupPath();
        using var pc = MakeContext();
        WorkPersistence.Upsert(Payload(1, 1), pc);
        var pcSync = MakeSync(path);

        // Nothing in the folder yet: Sync Now just backs up.
        Assert.Equal(new SyncNowResult(false, BackupOutcome.Written), await pcSync.SyncNowAsync(pc));

        // The iPad backs up two works; the PC's Sync Now pulls them in before
        // it backs up, and stamps the file it wrote.
        using var pad = MakeContext();
        WorkPersistence.Upsert(Payload(10, 1), pad);
        WorkPersistence.Upsert(Payload(11, 1), pad);
        MakeSync(path).Backup(pad);
        File.SetLastWriteTimeUtc(path, File.GetLastWriteTimeUtc(path).AddSeconds(5));
        Assert.Equal(new SyncNowResult(true, BackupOutcome.Written), await pcSync.SyncNowAsync(pc));
        Assert.Equal([1, 10, 11], pc.All<Work>().Select(w => w.Ao3Id).Order());
        Assert.Equal(3, DecodeBackup(path).Works.Count);
        Assert.False(pcSync.CloudBackupHasUnappliedChanges);

        // With nothing new, it doesn't restore again.
        Assert.Equal(new SyncNowResult(false, BackupOutcome.Written), await pcSync.SyncNowAsync(pc));
    }

    [Fact]
    public async Task SyncNowLeavesAnUnreadableBackupAlone()
    {
        var path = MakeTempBackupPath();
        File.WriteAllText(path, "not json");
        using var pc = MakeContext();
        WorkPersistence.Upsert(Payload(1, 1), pc);
        var pcSync = MakeSync(path);
        Assert.Equal(new SyncNowResult(false, BackupOutcome.Unreadable), await pcSync.SyncNowAsync(pc));
        Assert.Equal("not json", File.ReadAllText(path));
        Assert.True(pcSync.CloudBackupHasUnappliedChanges);
    }

    [Fact]
    public async Task FollowedAuthorsSyncBetweenDevices()
    {
        var path = MakeTempBackupPath();
        var followed = new DateTimeOffset(2026, 3, 1, 0, 0, 0, TimeSpan.Zero);

        using var phone = MakeContext();
        phone.Insert(new FollowedAuthor("writer", "The Writer", followed, knownWorkIds: [1, 2]));
        phone.Save();
        MakeSync(path).Backup(phone);

        // The PC follows the same author (spelt with a capital) with a newer
        // work seen, plus another.
        using var pc = MakeContext();
        pc.Insert(new FollowedAuthor("Writer", "The Writer", followed.AddDays(5), knownWorkIds: [2, 3]));
        pc.Insert(new FollowedAuthor("other", "Other", followed, knownWorkIds: [9]));
        pc.Save();
        MakeSync(path).Backup(pc);

        var backup = DecodeBackup(path);
        Assert.Equal(2, backup.FollowedAuthors!.Count);
        var writer = backup.FollowedAuthors!.Single(a => a.Username.Equals("writer", StringComparison.OrdinalIgnoreCase));
        Assert.Equal([1, 2, 3], writer.KnownWorkIds.Order());
        Assert.Equal(followed, writer.FollowedAt);

        // A fresh device gets both, with every work already seen.
        using var laptop = MakeContext();
        laptop.Insert(new FollowedAuthor("writer", "The Writer", followed, knownWorkIds: [1]));
        laptop.Save();
        Assert.True(await MakeSync(path).RestoreAsync(laptop));
        Assert.Equal(["other", "writer"], laptop.All<FollowedAuthor>().Select(a => a.Username).Order());
        Assert.Equal([1, 2, 3], laptop.GetFollowedAuthor("writer")!.KnownWorkIds.Order());
        Assert.Equal([9], laptop.GetFollowedAuthor("other")!.KnownWorkIds);
    }

    /// <summary>Blocked tags and authors from two devices union in the backup
    /// (the same term in different case counts once), and restoring the merged
    /// file gives either device the whole list (RM-006).</summary>
    [Fact]
    public async Task BackupUnionsBlockedTermsAcrossDevices()
    {
        var path = MakeTempBackupPath();

        using var phone = MakeContext();
        BlocklistStore.Block(BlockedTermKind.Tag, "Major Character Death", phone);
        BlocklistStore.Block(BlockedTermKind.Author, "writer", phone);
        MakeSync(path).Backup(phone);

        using var pc = MakeContext();
        BlocklistStore.Block(BlockedTermKind.Tag, "major character death", pc);
        BlocklistStore.Block(BlockedTermKind.Tag, "Angst", pc);
        MakeSync(path).Backup(pc);

        Assert.Equal(["author:writer", "tag:angst", "tag:major character death"],
                     DecodeBackup(path).Blocked!.Select(b => b.Key));

        Assert.True(await MakeSync(path).RestoreAsync(pc));
        Assert.Equal(["author:writer", "tag:angst", "tag:major character death"],
                     pc.All<BlockedTerm>().Select(t => t.Key).Order(StringComparer.Ordinal));
    }

    [Fact]
    public void BackupsWithoutBlockedTermsStillDecode()
    {
        var json = """{"works":[],"bookmarks":[],"subscriptions":[],"searches":[],"progress":[],"filters":[],"hidden":[],"timestamp":"2026-01-01T00:00:00Z"}""";
        Assert.Null(LibraryBackupJson.Decode(System.Text.Encoding.UTF8.GetBytes(json)).Blocked);
    }

    /// <summary>The Swift app writes the blocklist under "blocked" as
    /// {kind, value, createdAt}; Windows reads and writes the same keys.</summary>
    [Fact]
    public void BlockedTermsRoundTripInTheSwiftFormat()
    {
        var json = """{"works":[],"bookmarks":[],"subscriptions":[],"searches":[],"progress":[],"filters":[],"hidden":[],"blocked":[{"kind":"tag","value":"Angst","createdAt":"2026-01-02T03:04:05Z"}],"timestamp":"2026-01-01T00:00:00Z"}""";
        var backup = LibraryBackupJson.Decode(System.Text.Encoding.UTF8.GetBytes(json));
        var term = Assert.Single(backup.Blocked!);
        Assert.Equal(("tag", "Angst", "tag:angst"), (term.Kind, term.Value, term.Key));
        Assert.Contains("\"blocked\":[{\"kind\":\"tag\",\"value\":\"Angst\",\"createdAt\":\"2026-01-02T03:04:05Z\"}]",
                        System.Text.Encoding.UTF8.GetString(LibraryBackupJson.Encode(backup)));
    }

    [Fact]
    public void BackupsWithoutFollowedAuthorsStillDecode()
    {
        var json = """{"works":[],"bookmarks":[],"subscriptions":[],"searches":[],"progress":[],"filters":[],"hidden":[],"timestamp":"2026-01-01T00:00:00Z"}""";
        Assert.Null(LibraryBackupJson.Decode(System.Text.Encoding.UTF8.GetBytes(json)).FollowedAuthors);
    }

    /// <summary>On a per-work conflict the backing-up device's record wins, but
    /// the cloud copy's chapters survive when the local copy is metadata-only.</summary>
    [Fact]
    public void BackupMergeLocalWinsButKeepsCloudChapters()
    {
        var path = MakeTempBackupPath();

        // Device A saved the full download (3 chapters, with AO3 chapter ids)…
        using var a = MakeContext();
        var downloaded = new Work(1, "Old Title", "A");
        a.Insert(downloaded);
        for (var i = 0; i < 3; i++) a.Insert(new Chapter(downloaded, i + 1, $"Ch {i + 1}", "<p>body</p>", 900 + i));
        a.Save();
        MakeSync(path).Backup(a);

        // …device B holds a metadata-only copy with fresher metadata.
        using var b = MakeContext();
        b.Insert(new Work(1, "New Title", "A"));
        b.Save();
        MakeSync(path).Backup(b);

        var merged = DecodeBackup(path);
        var work = Assert.Single(merged.Works);
        Assert.Equal("New Title", work.Title);
        // Cloud chapters (and their AO3 ids) must survive a metadata-only backup.
        Assert.Equal([900, 901, 902], work.Chapters.Select(c => c.AoId));
    }

    /// <summary>Stats from two devices union in the backup file: per-day maxima,
    /// and a total lifted to Σ DaySeconds rather than the max of the totals.</summary>
    [Fact]
    public void BackupMergesStatsAcrossDevices()
    {
        var path = MakeTempBackupPath();

        using var a = MakeContext();
        a.Insert(new ReadingStat(7, "T", "A", totalSeconds: 1000, daySeconds: new Dictionary<string, double> { ["2026-06-01"] = 1000 }));
        a.Save();
        MakeSync(path).Backup(a);

        using var b = MakeContext();
        b.Insert(new ReadingStat(7, "T", "A", totalSeconds: 2000, daySeconds: new Dictionary<string, double> { ["2026-06-02"] = 2000 }));
        b.Save();
        MakeSync(path).Backup(b);

        var stat = Assert.Single(DecodeBackup(path).Stats!);
        Assert.Equal(1000, stat.DaySeconds["2026-06-01"], 3);
        Assert.Equal(2000, stat.DaySeconds["2026-06-02"], 3);
        Assert.Equal(3000, stat.TotalSeconds, 3);
    }

    /// <summary>Restoring a metadata-only backup (chapters: []) must not delete a
    /// fuller offline download.</summary>
    [Fact]
    public async Task RestoreKeepsDownloadedChaptersWhenBackupHasFewer()
    {
        var path = MakeTempBackupPath();

        // A metadata-only device (follow without download) wrote the backup…
        using var metadataOnly = MakeContext();
        metadataOnly.Insert(new Work(1, "T", "A"));
        metadataOnly.Save();
        MakeSync(path).Backup(metadataOnly);

        // …restoring on the device holding the 4-chapter download keeps it.
        using var device = MakeContext();
        WorkPersistence.Upsert(Payload(1, 4), device);
        Assert.True(await MakeSync(path).RestoreAsync(device));
        Assert.Equal(4, Assert.Single(device.All<Work>()).Chapters.Count);
    }

    /// <summary>When the backup carries more chapters than the local copy, they
    /// replace it — and each chapter's AO3 id survives the round trip.</summary>
    [Fact]
    public async Task RestoreReplacesChaptersWhenBackupHasMoreAndKeepsAoId()
    {
        var path = MakeTempBackupPath();

        using var full = MakeContext();
        var downloaded = new Work(1, "T", "A");
        full.Insert(downloaded);
        for (var i = 0; i < 3; i++) full.Insert(new Chapter(downloaded, i + 1, $"Ch {i + 1}", "<p>body</p>", 900 + i));
        full.Save();
        MakeSync(path).Backup(full);

        using var device = MakeContext();
        WorkPersistence.Upsert(Payload(1, 1), device);
        Assert.True(await MakeSync(path).RestoreAsync(device));
        var work = Assert.Single(device.All<Work>());
        var chapters = work.Chapters.OrderBy(c => c.Index).ToList();
        Assert.Equal(3, chapters.Count);
        Assert.Equal([900, 901, 902], chapters.Select(c => c.AoId));
    }

    /// <summary>Restore also runs as a background launch sync, so it must be a
    /// strictly forward merge: an older backup can never rewind a reading
    /// position — but a newer one still advances it.</summary>
    [Fact]
    public async Task RestoreNeverRewindsNewerLocalProgress()
    {
        var path = MakeTempBackupPath();
        var now = DateTimeOffset.Now;

        // The cloud device read work 1 an hour ago (ch 2) but work 2 just now (ch 9).
        using var cloudDevice = MakeContext();
        cloudDevice.Insert(new ReadingProgress(1, 2, 5, "T", "A", now.AddHours(-1)));
        cloudDevice.Insert(new ReadingProgress(2, 9, 0, "U", "A", now));
        cloudDevice.Save();
        MakeSync(path).Backup(cloudDevice);

        // This device is ahead on work 1 (ch 7) and behind on work 2 (ch 1).
        using var device = MakeContext();
        device.Insert(new ReadingProgress(1, 7, 0, "T", "A", now));
        device.Insert(new ReadingProgress(2, 1, 0, "U", "A", now.AddHours(-2)));
        device.Save();

        Assert.True(await MakeSync(path).RestoreAsync(device));
        Assert.Equal(7, device.GetReadingProgress(1)?.ChapterIndex); // kept local
        Assert.Equal(9, device.GetReadingProgress(2)?.ChapterIndex); // took cloud
    }

    /// <summary>Star/follow flags and folder assignments made locally since the
    /// last backup survive a restore (OR/union semantics), and the subscription
    /// notification baseline never regresses to re-fire old alerts.</summary>
    [Fact]
    public async Task RestoreKeepsLocalFlagsFoldersAndSeenBaseline()
    {
        var path = MakeTempBackupPath();

        // The cloud copy predates this device's star, folder, and seen-count.
        using var cloudDevice = MakeContext();
        cloudDevice.Insert(new Work(1, "T", "A") { LastSeenChapterCount = 3 });
        cloudDevice.Save();
        MakeSync(path).Backup(cloudDevice);

        using var device = MakeContext();
        var folder = new CustomFolder("Faves");
        device.Insert(folder);
        var local = new Work(1, "T", "A") { IsStarred = true, IsFollowed = true, LastSeenChapterCount = 8 };
        device.Insert(local);
        local.Folders.Add(folder);
        device.Save();

        Assert.True(await MakeSync(path).RestoreAsync(device));
        var work = Assert.Single(device.All<Work>());
        Assert.True(work.IsStarred);
        Assert.True(work.IsFollowed);
        Assert.Equal(8, work.LastSeenChapterCount);
        Assert.Equal(["Faves"], work.Folders.Select(f => f.Name));
    }

    /// <summary>Only works with restored chapter text (downloaded on the device
    /// that made the backup) and no local EPUB file are offered for re-download.</summary>
    [Fact]
    public void RedownloadCandidatesRequireChapters()
    {
        using var ctx = MakeContext();
        WorkPersistence.Upsert(Payload(987654321, 2), ctx);            // downloaded
        ctx.Insert(new Work(987654322, "Metadata only", "A"));          // follow
        ctx.Save();
        Assert.Equal([987654321], RestoreDownloadCenter.RedownloadCandidates(ctx));
    }

    /// <summary>Restore's stat merge must keep TotalSeconds == Σ DaySeconds: per-day
    /// maxima from two devices sum past either device's own total, and taking
    /// only max(totals) left All Time showing less than a single Year.</summary>
    [Fact]
    public async Task RestoreStatMergeKeepsTotalAtLeastSumOfDays()
    {
        var path = MakeTempBackupPath();

        // The phone backed up 1000s read on Monday…
        using var phone = MakeContext();
        phone.Insert(new ReadingStat(7, "T", "A", totalSeconds: 1000, daySeconds: new Dictionary<string, double> { ["2026-06-01"] = 1000 }));
        phone.Save();
        MakeSync(path).Backup(phone);

        // …the PC read 2000s on Tuesday, then restores.
        using var pc = MakeContext();
        pc.Insert(new ReadingStat(7, "T", "A", totalSeconds: 2000, daySeconds: new Dictionary<string, double> { ["2026-06-02"] = 2000 }));
        pc.Save();
        Assert.True(await MakeSync(path).RestoreAsync(pc));

        var row = Assert.Single(pc.All<ReadingStat>());
        Assert.Equal(1000, row.DaySeconds["2026-06-01"], 3);
        Assert.Equal(2000, row.DaySeconds["2026-06-02"], 3);
        // Total must be Σ DaySeconds (3000), not max of device totals (2000).
        Assert.Equal(3000, row.TotalSeconds, 3);
    }

    [Fact]
    public void WorkMatchesSearchQuery()
    {
        var work = new Work(
            101, "The Golden Snitch", "GryffindorWriter",
            summary: "A story about quidditch",
            rating: "Teen",
            warnings: ["Graphic Depictions Of Violence"],
            categories: ["F/M"],
            fandoms: ["Harry Potter - J. K. Rowling"],
            characters: ["Harry Potter", "Hermione Granger"],
            relationships: ["Harry Potter/Hermione Granger"],
            freeforms: ["Quidditch", "Enemies to Lovers"]);

        // Matching titles
        Assert.True(work.Matches("Golden"));
        Assert.True(work.Matches("snitch"));      // Case-insensitive
        Assert.True(work.Matches("  Snitch  "));  // Trimmed whitespace
        // Matching authors
        Assert.True(work.Matches("Gryffindor"));
        // Matching fandoms
        Assert.True(work.Matches("Rowling"));
        // Matching characters
        Assert.True(work.Matches("Hermione"));
        // Matching relationships
        Assert.True(work.Matches("Harry Potter/Hermione Granger"));
        // Matching tags/freeforms
        Assert.True(work.Matches("Enemies"));
        // Matching warnings & rating
        Assert.True(work.Matches("Teen"));
        Assert.True(work.Matches("Violence"));
        // No match
        Assert.False(work.Matches("Snape"));
    }

    [Fact]
    public void WorkMultiFolderPersistence()
    {
        using var ctx = MakeContext();
        var work = new Work(999, "Multi Folder Story", "author");
        ctx.Insert(work);

        var folder1 = new CustomFolder("Folder A");
        var folder2 = new CustomFolder("Folder B");
        ctx.Insert(folder1);
        ctx.Insert(folder2);

        work.Folders.Add(folder1);
        work.Folders.Add(folder2);

        ctx.Save();

        // Fetch back and assert
        var fetched = ctx.All<Work>().FirstOrDefault();
        Assert.NotNull(fetched);
        Assert.Equal(2, fetched.Folders.Count);
        Assert.Contains(fetched.Folders, f => f.Name == "Folder A");
        Assert.Contains(fetched.Folders, f => f.Name == "Folder B");

        // Inverse relationship
        var fetchedFolder = ctx.GetFolder("Folder A");
        Assert.NotNull(fetchedFolder);
        Assert.Single(fetchedFolder.Works);
        Assert.Equal(999, fetchedFolder.Works[0].Ao3Id);
    }

    // MARK: - Subscription list sync (fail closed)

    private static void SeedSubscriptionRecords(LibraryStore ctx)
    {
        ctx.Insert(new SubscriptionRecord("work:1", "work", "Fic One") { LastSeenChapterCount = 5 });
        ctx.Insert(new SubscriptionRecord("series:9", "series", "Saga"));
        ctx.TrySave();
    }

    /// <summary>An empty fetch (stale session, markup drift) must never prune the
    /// stored records — a wrong delete also destroys the LastSeenChapterCount
    /// baselines that new-chapter notifications compare against.</summary>
    [Fact]
    public async Task SyncSubscriptionList_EmptyFetchKeepsRecords()
    {
        using var ctx = MakeContext();
        SeedSubscriptionRecords(ctx);
        var client = new PollerFakeClient { SubscriptionsResponse = [] };

        var poller = new SubscriptionPoller(client, ctx, "reader");
        await poller.SyncSubscriptionListAsync();

        var remaining = ctx.All<SubscriptionRecord>();
        Assert.Equal(2, remaining.Count);
        Assert.Equal(5, remaining.First(r => r.Key == "work:1").LastSeenChapterCount);
    }

    /// <summary>A non-empty fetch is trusted: records missing from it are pruned
    /// and new ones inserted.</summary>
    [Fact]
    public async Task SyncSubscriptionList_NonEmptyFetchPrunesStaleRecords()
    {
        using var ctx = MakeContext();
        SeedSubscriptionRecords(ctx);
        var client = new PollerFakeClient
        {
            SubscriptionsResponse =
            [
                new AO3Subscription(AO3SubscriptionKind.Work, "1", "Fic One", "alice"),
                new AO3Subscription(AO3SubscriptionKind.User, "carol", "carol", null),
            ],
        };

        var poller = new SubscriptionPoller(client, ctx, "reader");
        await poller.SyncSubscriptionListAsync();

        Assert.Equal(new HashSet<string> { "work:1", "user:carol" }, ctx.All<SubscriptionRecord>().Select(r => r.Key).ToHashSet());
    }
}

/// <summary>The Spotlight hook follows the library, not the follow flag, as in
/// Swift's WorkPersistence (RM-016): saving indexes, unfollowing keeps the work
/// indexed, deleting removes it.</summary>
[Collection(GlobalStoreCollection.Name)]
public sealed class SearchIndexHookTests : IDisposable
{
    private sealed class RecordingIndexer : IWorkSearchIndexer
    {
        public readonly List<string> Calls = [];
        public void Index(Work work) { lock (Calls) Calls.Add($"index {work.Ao3Id}"); }
        public void Remove(int ao3Id) { lock (Calls) Calls.Add($"remove {ao3Id}"); }
        public List<string> For(int id) { lock (Calls) return Calls.Where(c => c.EndsWith($" {id}")).ToList(); }
    }

    private readonly RecordingIndexer _indexer = new();

    public SearchIndexHookTests() => LibraryHooks.SearchIndexer = _indexer;

    public void Dispose() => LibraryHooks.SearchIndexer = null;

    private static AO3WorkSummary Summary(int id) => new()
    {
        Id = id, Title = $"Work {id}", Author = "tester", ChapterCount = 1, TotalChapters = 1,
    };

    [Fact]
    public void SavingAnUnfollowedWorkIndexesIt()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.UpsertMetadata(Summary(81001), store);
        Assert.False(work.IsFollowed);
        Assert.Equal(["index 81001"], _indexer.For(81001));
    }

    [Fact]
    public void UnfollowingKeepsTheWorkIndexed()
    {
        using var store = LibraryStore.OpenInMemory();
        Assert.True(WorkPersistence.ToggleFollow(Summary(81002), store));
        Assert.False(WorkPersistence.ToggleFollow(Summary(81002), store));
        WorkPersistence.Unfollow(store.GetWork(81002)!, store);
        Assert.DoesNotContain("remove 81002", _indexer.For(81002));
    }

    [Fact]
    public void DeletingAWorkRemovesItFromTheIndex()
    {
        using var store = LibraryStore.OpenInMemory();
        var work = WorkPersistence.UpsertMetadata(Summary(81003), store);
        WorkPersistence.DeleteWork(work, store);
        Assert.Equal(["index 81003", "remove 81003"], _indexer.For(81003));
    }
}

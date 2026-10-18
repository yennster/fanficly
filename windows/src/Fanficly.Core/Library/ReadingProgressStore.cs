using System.Globalization;

namespace Fanficly.Core;

/// <summary>Loads and saves the per-work reading position.</summary>
public static class ReadingProgressStore
{
    /// <summary>The saved chapter + paragraph anchor for a work, or null.</summary>
    public static (int Chapter, int Paragraph)? Load(int ao3Id, LibraryStore store) =>
        store.GetReadingProgress(ao3Id) is { } rec ? (rec.ChapterIndex, rec.ParagraphIndex) : null;

    /// <summary>Saves the reading position, stamps the saved work's
    /// <c>LastRead*</c> fields, and — when <paramref name="progress"/> is known —
    /// feeds the last-read widget store with the same timestamp (so a resume
    /// tap on this device always ties, never overrides). Also records a
    /// reading event for the streak and refreshes the widget data.</summary>
    public static void Save(int ao3Id, int chapter, int paragraph, string title, string author,
                            LibraryStore store, double? progress = null, bool syncWidgetImmediately = false)
    {
        var now = DateTimeOffset.Now;
        if (store.GetReadingProgress(ao3Id) is { } rec)
        {
            rec.ChapterIndex = chapter;
            rec.ParagraphIndex = paragraph;
            rec.Title = title;
            rec.Author = author;
            rec.UpdatedAt = now;
        }
        else
        {
            store.Insert(new ReadingProgress(ao3Id, chapter, paragraph, title, author, now));
        }

        if (store.GetWork(ao3Id) is { } work)
        {
            work.LastReadAt = now;
            work.LastReadChapter = chapter;
            if (progress is { } p) work.LastReadProgress = p;
        }

        store.TrySave();

        if (progress is { } value)
        {
            LibraryHooks.SaveWidgetProgress?.Invoke(new WidgetProgressUpdate(
                ao3Id, title, author, value, chapter, paragraph, now, syncWidgetImmediately));
        }

        LibraryHooks.RecordReadingEvent?.Invoke();
        LibraryHooks.UpdateWidgetData?.Invoke(store);
    }
}

// MARK: - Reading statistics

/// <summary>A half-open date interval [Start, End) — Foundation's <c>DateInterval</c>
/// as the Stats screen uses it.</summary>
public readonly record struct DateSpan(DateTimeOffset Start, DateTimeOffset End)
{
    public bool Contains(DateTimeOffset date) => date >= Start && date < End;

    /// <summary>The calendar week / month / year (or day) containing
    /// <paramref name="date"/> in <paramref name="timeZone"/> (local by default) —
    /// <c>Calendar.dateInterval(of:for:)</c>. Weeks start on
    /// <paramref name="firstDayOfWeek"/> (the current culture's by default).</summary>
    public static DateSpan Of(StatsCalendarUnit unit, DateTimeOffset date, TimeZoneInfo? timeZone = null, DayOfWeek? firstDayOfWeek = null)
    {
        var tz = timeZone ?? TimeZoneInfo.Local;
        var wall = TimeZoneInfo.ConvertTime(date, tz).DateTime.Date;
        DateTime start, end;
        switch (unit)
        {
            case StatsCalendarUnit.Day:
                start = wall;
                end = wall.AddDays(1);
                break;
            case StatsCalendarUnit.Week:
                var first = firstDayOfWeek ?? CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek;
                var back = ((int)wall.DayOfWeek - (int)first + 7) % 7;
                start = wall.AddDays(-back);
                end = start.AddDays(7);
                break;
            case StatsCalendarUnit.Month:
                start = new DateTime(wall.Year, wall.Month, 1);
                end = start.AddMonths(1);
                break;
            default:
                start = new DateTime(wall.Year, 1, 1);
                end = start.AddYears(1);
                break;
        }
        return new DateSpan(ReadingStatsAggregator.StartOfDay(start, tz), ReadingStatsAggregator.StartOfDay(end, tz));
    }
}

public enum StatsCalendarUnit { Day, Week, Month, Year }

/// <summary>A pure snapshot of a <see cref="ReadingStat"/>, so the aggregation
/// that drives the Stats screen can be tested away from the database.</summary>
public sealed record ReadingStatSnapshot(
    int Ao3Id,
    string Title,
    string Author,
    IReadOnlyList<string> Fandoms,
    IReadOnlyList<string> Categories,
    IReadOnlyList<string> Relationships,
    string Rating,
    int WordCount,
    DateTimeOffset FirstReadAt,
    DateTimeOffset LastReadAt,
    double TotalSeconds,
    IReadOnlyDictionary<string, double> DaySeconds,
    /// <summary>Furthest reading position reached, 0…1.</summary>
    double MaxProgress = 0,
    /// <summary>Whether the underlying AO3 work is a completed work.</summary>
    bool WorkIsComplete = false)
{
    /// <summary>Clamped progress, defensive against out-of-range stored values.</summary>
    public double Progress => Math.Min(Math.Max(MaxProgress, 0), 1);

    /// <summary>Whether the reader finished the work — the same rule the Library
    /// row uses for its "Finished" badge. Only finished works count toward
    /// "stories read".</summary>
    public bool IsFinished => Progress >= 0.99 || (WorkIsComplete && Progress >= 0.95);

    /// <summary>Words actually read: full length scaled by how far the reader
    /// got. Crediting the whole work for merely opening it was the bug.</summary>
    public int WordsRead => (int)Math.Round(WordCount * Progress, MidpointRounding.AwayFromZero);

    public bool Equals(ReadingStatSnapshot? other) =>
        other is not null &&
        Ao3Id == other.Ao3Id && Title == other.Title && Author == other.Author &&
        Fandoms.SequenceEqual(other.Fandoms) && Categories.SequenceEqual(other.Categories) &&
        Relationships.SequenceEqual(other.Relationships) && Rating == other.Rating &&
        WordCount == other.WordCount && FirstReadAt == other.FirstReadAt && LastReadAt == other.LastReadAt &&
        TotalSeconds.Equals(other.TotalSeconds) &&
        DaySeconds.Count == other.DaySeconds.Count &&
        DaySeconds.All(kv => other.DaySeconds.TryGetValue(kv.Key, out var v) && v.Equals(kv.Value)) &&
        MaxProgress.Equals(other.MaxProgress) && WorkIsComplete == other.WorkIsComplete;

    public override int GetHashCode() => HashCode.Combine(Ao3Id, Title, WordCount, TotalSeconds, MaxProgress);
}

/// <summary>A name with a tally (work count) for the "top fandoms / ships /
/// authors" lists. <see cref="Id"/> is the name, for stable list identity.</summary>
public readonly record struct ReadingTagCount(string Name, int Count)
{
    public string Id => Name;
}

/// <summary>The aggregated numbers shown on the Stats screen for one scope —
/// all-time or a single week/month/year period.</summary>
public sealed record ReadingStatsSummary(
    int StoriesRead,
    double TotalSeconds,
    int TotalWords,
    IReadOnlyList<ReadingTagCount> TopFandoms,
    IReadOnlyList<ReadingTagCount> TopCategories,
    IReadOnlyList<ReadingTagCount> TopRelationships,
    IReadOnlyList<ReadingTagCount> TopAuthors)
{
    public static ReadingStatsSummary Empty { get; } = new(0, 0, 0, [], [], [], []);

    public bool Equals(ReadingStatsSummary? other) =>
        other is not null &&
        StoriesRead == other.StoriesRead && TotalSeconds.Equals(other.TotalSeconds) && TotalWords == other.TotalWords &&
        TopFandoms.SequenceEqual(other.TopFandoms) && TopCategories.SequenceEqual(other.TopCategories) &&
        TopRelationships.SequenceEqual(other.TopRelationships) && TopAuthors.SequenceEqual(other.TopAuthors);

    public override int GetHashCode() => HashCode.Combine(StoriesRead, TotalSeconds, TotalWords, TopFandoms.Count);
}

/// <summary>Where the reader stands against their yearly goal (RM-011,
/// ReadingGoalProgress), from <see cref="ReadingStatsAggregator.GoalProgress"/>.
/// The goal is per-device (<see cref="ReadingGoal.StorageKey"/>) and never synced.</summary>
public sealed record ReadingGoalProgress(int Goal, int Finished, int Expected)
{
    /// <summary>0…1 for the progress ring; stays full once the goal is passed.</summary>
    public double Fraction => Math.Min((double)Finished / Goal, 1);
    public bool IsComplete => Finished >= Goal;
    /// <summary>Stories ahead of an even pace (negative when behind).</summary>
    public int Ahead => Finished - Expected;

    /// <summary>"Goal reached", "On pace", "3 ahead", "2 behind".</summary>
    public string PaceLabel =>
        IsComplete ? "Goal reached"
        : Ahead == 0 ? "On pace"
        : Ahead > 0 ? $"{Ahead} ahead"
        : $"{-Ahead} behind";
}

public static class ReadingGoal
{
    /// <summary>Stories to finish this year; 0 means no goal. Per-device, not
    /// synced or backed up. The Swift <c>@AppStorage</c> key.</summary>
    public const string StorageKey = "reading.yearlyGoal";
}

/// <summary>Pure aggregation over <see cref="ReadingStatSnapshot"/>s. Time is
/// bucketed per calendar day, so any <see cref="DateSpan"/> (a week, month,
/// year, or null for all-time) rolls up from the same data.</summary>
public static class ReadingStatsAggregator
{
    /// <summary>"yyyy-MM-dd" in the given time zone (local by default) — the
    /// <see cref="ReadingStat.DaySeconds"/> key.</summary>
    public static string DayKey(DateTimeOffset date, TimeZoneInfo? timeZone = null) =>
        TimeZoneInfo.ConvertTime(date, timeZone ?? TimeZoneInfo.Local).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// <summary>Parse a "yyyy-MM-dd" key back to the start of that day.</summary>
    public static DateTimeOffset? DateFromDayKey(string key, TimeZoneInfo? timeZone = null)
    {
        if (!DateTime.TryParseExact(key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day))
            return null;
        return StartOfDay(day, timeZone ?? TimeZoneInfo.Local);
    }

    /// <summary>The instant a wall-clock date's day starts in <paramref name="tz"/>
    /// (skipping forward past a DST gap at midnight, as Foundation does).</summary>
    internal static DateTimeOffset StartOfDay(DateTime wallDate, TimeZoneInfo tz)
    {
        var wall = DateTime.SpecifyKind(wallDate.Date, DateTimeKind.Unspecified);
        var probe = wall;
        for (var i = 0; i < 24 * 4 && tz.IsInvalidTime(probe); i++) probe = probe.AddMinutes(15);
        return new DateTimeOffset(probe, tz.GetUtcOffset(probe));
    }

    /// <summary>The span from the earliest to the latest day with recorded
    /// reading, used to bound the period navigator. Null when there's no data.</summary>
    public static (DateTimeOffset Lower, DateTimeOffset Upper)? DataDateRange(
        IEnumerable<ReadingStatSnapshot> snapshots, TimeZoneInfo? timeZone = null)
    {
        DateTimeOffset? lo = null, hi = null;
        foreach (var snapshot in snapshots)
            foreach (var key in snapshot.DaySeconds.Keys)
            {
                if (DateFromDayKey(key, timeZone) is not { } d) continue;
                if (lo is null || d < lo) lo = d;
                if (hi is null || d > hi) hi = d;
            }
        return lo is { } l && hi is { } h ? (l, h) : null;
    }

    /// <summary>Aggregate snapshots for a scope. <paramref name="interval"/> null
    /// means all-time; otherwise only days within [Start, End) count — both for
    /// the time total and for which works/tags are included.</summary>
    public static ReadingStatsSummary Summarize(IEnumerable<ReadingStatSnapshot> snapshots, DateSpan? interval,
                                                TimeZoneInfo? timeZone = null, int topCount = 8)
    {
        // Per snapshot: seconds read inside the interval (all-time = total).
        double SecondsInScope(ReadingStatSnapshot s)
        {
            if (interval is not { } span) return s.TotalSeconds;
            var sum = 0.0;
            foreach (var (key, secs) in s.DaySeconds)
            {
                if (DateFromDayKey(key, timeZone) is not { } day) continue;
                // Interval is [start, end); a day key is the start of its day.
                if (day >= span.Start && day < span.End) sum += secs;
            }
            return sum;
        }

        // Whether the work was read on any day inside the interval. This, not
        // "time > 0", decides period membership so works backfilled from old
        // reading history — a read date but zero recorded time — still show up
        // in their week/month/year (and the yearly wrap).
        bool WasReadInScope(ReadingStatSnapshot s)
        {
            if (interval is not { } span) return true;
            foreach (var key in s.DaySeconds.Keys)
            {
                if (DateFromDayKey(key, timeZone) is not { } day) continue;
                if (day >= span.Start && day < span.End) return true;
            }
            return false;
        }

        var scoped = snapshots
            .Where(s => interval is null || WasReadInScope(s))
            .Select(s => (Snapshot: s, Seconds: SecondsInScope(s)))
            .ToList();
        if (scoped.Count == 0) return ReadingStatsSummary.Empty;

        var totalSeconds = scoped.Sum(x => x.Seconds);
        var works = scoped.Select(x => x.Snapshot).ToList();
        // Words read reflects how far the reader got; stories read counts only
        // works the reader finished.
        var totalWords = works.Sum(w => w.WordsRead);

        return new ReadingStatsSummary(
            StoriesRead: works.Count(w => w.IsFinished),
            TotalSeconds: totalSeconds,
            TotalWords: totalWords,
            TopFandoms: Rank(works.SelectMany(w => w.Fandoms), topCount),
            TopCategories: Rank(works.SelectMany(w => w.Categories), topCount),
            TopRelationships: Rank(works.SelectMany(w => w.Relationships), topCount),
            TopAuthors: Rank(works.Where(w => w.Author.Length > 0).Select(w => w.Author), topCount));
    }

    /// <summary>Progress toward a yearly goal of <paramref name="goal"/> finished
    /// stories, given how many the reader has finished so far in the year
    /// containing <paramref name="now"/>. Null when there's no goal (zero or
    /// negative), which hides the ring. Pace compares against an even spread
    /// across the year, rounded down so nobody starts January 1st already behind.</summary>
    public static ReadingGoalProgress? GoalProgress(int finished, int goal, DateTimeOffset now, TimeZoneInfo? timeZone = null)
    {
        if (goal <= 0) return null;
        var year = DateSpan.Of(StatsCalendarUnit.Year, now, timeZone);
        var length = (year.End - year.Start).TotalSeconds;
        var elapsed = length > 0 ? Math.Clamp((now - year.Start).TotalSeconds / length, 0, 1) : 0;
        var expected = (int)Math.Floor(goal * elapsed);
        return new ReadingGoalProgress(goal, Math.Max(finished, 0), expected);
    }

    /// <summary>Tally occurrences of each name, most common first. Ties break
    /// alphabetically so the order is deterministic.</summary>
    public static IReadOnlyList<ReadingTagCount> Rank(IEnumerable<string> names, int topCount)
    {
        var counts = new Dictionary<string, int>();
        foreach (var raw in names)
        {
            var name = raw.Trim();
            if (name.Length == 0) continue;
            counts[name] = counts.GetValueOrDefault(name) + 1;
        }
        return counts
            .Select(kv => new ReadingTagCount(kv.Key, kv.Value))
            .OrderByDescending(t => t.Count)
            .ThenBy(t => t.Name, StringComparer.Ordinal)
            .Take(topCount)
            .ToList();
    }
}

/// <summary>Records active reading time into <see cref="ReadingStat"/> rows.</summary>
public static class ReadingStatsStore
{
    /// <summary>Record <paramref name="seconds"/> of active reading for a work,
    /// creating or updating its row and refreshing the metadata snapshot. Time
    /// is bucketed into the calendar day of <paramref name="date"/>. Non-empty
    /// metadata overwrites the snapshot; empty fields are left untouched so a
    /// later read lacking metadata can't wipe it. Progress only ever advances.
    /// Returns true when this call is what finished the story (it wasn't
    /// finished before, it is now) — the cue for the rating prompt.</summary>
    public static bool Record(int ao3Id, string title, string author,
                              IReadOnlyList<string> fandoms, IReadOnlyList<string> categories,
                              IReadOnlyList<string> relationships,
                              string rating, int wordCount, double seconds, LibraryStore store,
                              double progress = 0, bool isComplete = false,
                              DateTimeOffset? date = null, TimeZoneInfo? timeZone = null)
    {
        if (!double.IsFinite(seconds) || seconds < 0) return false;
        var when = date ?? DateTimeOffset.Now;
        bool justFinished;
        var clampedProgress = double.IsFinite(progress) ? Math.Min(Math.Max(progress, 0), 1) : 0;
        var dayKey = ReadingStatsAggregator.DayKey(when, timeZone);
        if (store.GetReadingStat(ao3Id) is { } stat)
        {
            var wasFinished = stat.Snapshot.IsFinished;
            if (title.Length > 0) stat.Title = title;
            if (author.Length > 0) stat.Author = author;
            if (fandoms.Count > 0) stat.Fandoms = fandoms;
            if (categories.Count > 0) stat.Categories = categories;
            if (relationships.Count > 0) stat.Relationships = relationships;
            if (rating.Length > 0) stat.Rating = rating;
            if (wordCount > 0) stat.WordCount = wordCount;
            stat.LastReadAt = when;
            stat.TotalSeconds += seconds;
            var days = new Dictionary<string, double>(stat.DaySeconds);
            days[dayKey] = days.GetValueOrDefault(dayKey) + seconds;
            stat.DaySeconds = days;
            stat.MaxProgress = Math.Max(stat.MaxProgress, clampedProgress);
            if (isComplete) stat.WorkIsComplete = true;
            justFinished = !wasFinished && stat.Snapshot.IsFinished;
        }
        else
        {
            var created = new ReadingStat(
                ao3Id, title, author, fandoms, categories, relationships, rating, wordCount,
                firstReadAt: when, lastReadAt: when,
                totalSeconds: seconds, daySeconds: new Dictionary<string, double> { [dayKey] = seconds },
                maxProgress: clampedProgress, workIsComplete: isComplete);
            store.Insert(created);
            justFinished = created.Snapshot.IsFinished;
        }
        store.TrySave();
        return justFinished;
    }

    /// <summary>Every <see cref="ReadingStat"/> as a value snapshot for aggregation.</summary>
    public static IReadOnlyList<ReadingStatSnapshot> Snapshots(LibraryStore store) =>
        store.All<ReadingStat>().Select(s => s.Snapshot).ToList();
}

/// <summary>Seeds <see cref="ReadingStat"/> rows from reading history that
/// predates the Stats feature, so people who'd already read fics don't open
/// the Stats tab to a blank screen.
///
/// The source is every <see cref="ReadingProgress"/> row, enriched with the
/// saved <see cref="Work"/>'s metadata, plus any Work with a LastReadAt. Words
/// read and "finished" come from saved reading progress — never the full
/// length of a work merely opened. The app never recorded historical reading
/// time, so backfilled rows carry zero seconds; a zero-valued day bucket on the
/// last-read date still dates each read so it lands in the right period.
///
/// It also enriches stat rows that predate progress tracking (MaxProgress 0),
/// without touching their real recorded time. Runs after the launch restore
/// (so synced history is covered too); a per-id lookup and a one-shot flag
/// keep it from duplicating rows or lowering progress.</summary>
public static class ReadingStatsBackfill
{
    /// <summary>v2: also enriches stat rows created before progress was tracked.</summary>
    public const string BackfilledKey = "reading.stats.backfilled.v2";

    /// <summary>A value view of one previously-read work.</summary>
    public sealed record Candidate(
        int Ao3Id,
        string Title,
        string Author,
        IReadOnlyList<string> Fandoms,
        IReadOnlyList<string> Categories,
        IReadOnlyList<string> Relationships,
        string Rating,
        int WordCount,
        /// <summary>Furthest progress the existing history shows, 0…1.</summary>
        double MaxProgress,
        bool IsComplete,
        DateTimeOffset ReadDate);

    /// <summary>Run the migration once, then set the flag.</summary>
    public static void RunIfNeeded(LibraryStore store, IKeyValueStore? defaults = null)
    {
        var settings = defaults ?? KeyValueStores.Default;
        if (settings.GetBool(BackfilledKey)) return;
        Backfill(store);
        settings.SetBool(BackfilledKey, true);
    }

    /// <summary>The insertion + enrichment pass, without the flag gate. Returns
    /// the number of new rows inserted (enrichment isn't counted).</summary>
    public static int Backfill(LibraryStore store)
    {
        var inserted = 0;
        var changed = false;
        foreach (var c in Candidates(store))
        {
            if (store.GetReadingStat(c.Ao3Id) is { } stat)
            {
                // Only fill in a missing (zero) progress, never lower a value the
                // live recorder set. Time and day buckets are left untouched.
                if (stat.MaxProgress == 0 && c.MaxProgress > 0)
                {
                    stat.MaxProgress = c.MaxProgress;
                    changed = true;
                }
                if (c.IsComplete && !stat.WorkIsComplete)
                {
                    stat.WorkIsComplete = true;
                    changed = true;
                }
                continue;
            }
            var dayKey = ReadingStatsAggregator.DayKey(c.ReadDate);
            store.Insert(new ReadingStat(
                c.Ao3Id, c.Title, c.Author, c.Fandoms, c.Categories, c.Relationships, c.Rating, c.WordCount,
                firstReadAt: c.ReadDate, lastReadAt: c.ReadDate,
                totalSeconds: 0, daySeconds: new Dictionary<string, double> { [dayKey] = 0 },
                maxProgress: c.MaxProgress, workIsComplete: c.IsComplete));
            inserted++;
        }
        if (inserted > 0 || changed) store.TrySave();
        return inserted;
    }

    /// <summary>One candidate per previously-read work: ReadingProgress rows
    /// joined to their saved Work, unioned with any Work that has a LastReadAt
    /// but no progress row. Progress-only works carry just title/author.</summary>
    public static IReadOnlyList<Candidate> Candidates(LibraryStore store)
    {
        var works = store.All<Work>();
        var worksById = new Dictionary<int, Work>();
        foreach (var w in works) worksById.TryAdd(w.Ao3Id, w);
        var progress = store.All<ReadingProgress>();

        // How far through a work the existing data shows: the saved
        // LastReadProgress fraction, else the chapter reached over the chapter
        // count. Unknown ⇒ 0.
        static double Fraction(Work? work, int? chapter)
        {
            if (work?.LastReadProgress is { } p && double.IsFinite(p) && p > 0) return Math.Min(1, p);
            if (work is not null && (chapter ?? work.LastReadChapter) is { } ch && ch >= 1)
            {
                var total = Math.Max(work.TotalChapters ?? 0, work.ChapterCount);
                if (total > 1) return Math.Min(1, (double)ch / total);
            }
            return 0;
        }

        var byId = new Dictionary<int, Candidate>();
        foreach (var p in progress)
        {
            worksById.TryGetValue(p.Ao3Id, out var work);
            byId[p.Ao3Id] = new Candidate(
                p.Ao3Id,
                work?.Title ?? p.Title,
                work?.AuthorName ?? p.Author,
                work?.Fandoms ?? [],
                work?.Categories ?? [],
                work?.Relationships ?? [],
                work?.Rating ?? "",
                work?.WordCount ?? 0,
                Fraction(work, p.ChapterIndex),
                work?.IsComplete ?? false,
                p.UpdatedAt);
        }
        foreach (var work in works)
        {
            if (work.LastReadAt is null || byId.ContainsKey(work.Ao3Id)) continue;
            byId[work.Ao3Id] = new Candidate(
                work.Ao3Id, work.Title, work.AuthorName, work.Fandoms, work.Categories, work.Relationships,
                work.Rating, work.WordCount, Fraction(work, null), work.IsComplete,
                work.LastReadAt ?? DateTimeOffset.Now);
        }
        return byId.Values.ToList();
    }
}

/// <summary>The Stats screen's number formats (Swift <c>StatsView.formatDuration</c>
/// / <c>formatWords</c>).</summary>
public static class StatsFormat
{
    /// <summary>"12h 34m" / "45m" / "&lt;1m" / "0m". Active reading time, never zero-padded.</summary>
    public static string FormatDuration(double seconds)
    {
        var total = (int)Math.Round(seconds, MidpointRounding.AwayFromZero);
        if (total < 60) return total <= 0 ? "0m" : "<1m";
        var hours = total / 3600;
        var minutes = total % 3600 / 60;
        if (hours > 0) return minutes > 0 ? $"{hours}h {minutes}m" : $"{hours}h";
        return $"{minutes}m";
    }

    /// <summary>Compact word count: "1.2M", "340K", "8,500" (grouped per culture).</summary>
    public static string FormatWords(int words)
    {
        if (words >= 1_000_000) return (words / 1_000_000.0).ToString("0.0", CultureInfo.InvariantCulture) + "M";
        if (words >= 10_000) return $"{words / 1000}K";
        return words.ToString("N0", CultureInfo.CurrentCulture);
    }
}

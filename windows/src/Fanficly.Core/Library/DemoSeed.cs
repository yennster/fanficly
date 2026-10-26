namespace Fanficly.Core;

/// <summary>Seeds the in-memory library for demo-mode runs so the screens that
/// read local data (Library with reading progress, Recently Viewed, followed
/// authors, saved searches and filters, Stats) have realistic, all-ages content
/// for store screenshots. Only ever called in demo mode.</summary>
public static class DemoSeed
{
    /// <summary>A fixed instant so the seed is deterministic between runs.</summary>
    private static readonly DateTimeOffset SeedDate = DateTimeOffset.FromUnixTimeSeconds(1_780_000_000);

    /// <summary>Seeds <paramref name="store"/> from the demo catalogue
    /// (<c>DemoCatalog.Works</c>, passed in by the caller). Idempotent: does
    /// nothing when the store already holds works.</summary>
    public static void Seed(LibraryStore store, IReadOnlyList<AO3WorkSummary> catalog)
    {
        if (store.Count<Work>() > 0) return;
        AO3WorkSummary Summary(int id) => catalog.First(w => w.Id == id);

        // Library: a mix of followed and downloaded works.
        int[] followed = [90001, 90006, 90002];   // show with the bookmark badge
        int[] downloaded = [90001, 90004];        // show with the download badge

        // Reading progress for the Library progress-bar story: two works mid-read
        // and one finished (>= 99% → "Finished"). (fraction, chapter, hoursAgo)
        var progress = new Dictionary<int, (double Fraction, int Chapter, int HoursAgo)>
        {
            [90001] = (0.66, 8, 5),     // The Long Way Home — mid-read
            [90002] = (0.40, 4, 28),    // Letters Never Sent — earlier on
            [90006] = (1.00, 7, 72),    // Gardens in Winter — finished
        };

        foreach (var summary in catalog)
        {
            var work = WorkPersistence.UpsertMetadata(summary, store, save: false);
            if (followed.Contains(summary.Id))
            {
                work.IsFollowed = true;
                work.FollowedAt = summary.UpdatedAt;
                work.LastSeenChapterCount = summary.ChapterCount;
            }
            if (downloaded.Contains(summary.Id))
            {
                work.EpubLocalPath = $"library/{summary.Id}.epub";
                WritePlaceholderEpub(summary.Id);
            }
            if (progress.TryGetValue(summary.Id, out var p))
            {
                work.LastReadProgress = p.Fraction;
                work.LastReadChapter = p.Chapter;
                work.LastReadAt = SeedDate.AddHours(-p.HoursAgo);
            }
        }

        // Followed authors (Authors tab + the "follow your favourite authors" story).
        string[] demoAuthors = ["wanderlight", "paperboats", "tealeaf", "frostfern", "orbital"];
        for (var i = 0; i < demoAuthors.Length; i++)
            store.Insert(new FollowedAuthor(demoAuthors[i], demoAuthors[i], followedAt: AddDaysLocal(SeedDate, -i)));

        // Recently Viewed: a handful, newest first.
        (int Id, int DaysAgo)[] recents = [(90003, 0), (90001, 1), (90007, 2), (90004, 3), (90006, 5)];
        foreach (var (id, daysAgo) in recents)
        {
            var s = Summary(id);
            store.Insert(new RecentlyViewed(id, s.Title, s.Author, s.Fandoms.FirstOrDefault() ?? "",
                                            SeedDate.AddHours(-daysAgo * 8)));
        }

        // Reading stats (Stats tab). Spread active reading time across several
        // days per work — some this week, some this month, some earlier in the
        // year — so the Week / Month / Year views all populate.
        for (var i = 0; i < catalog.Count; i++)
        {
            var summary = catalog[i];
            int[] dayOffsets = [i % 6, 3 + i % 9, 12 + (i % 5) * 4, 40 + i * 11, 150 + i * 7];
            var daySeconds = new Dictionary<string, double>();
            var total = 0.0;
            for (var j = 0; j < dayOffsets.Length; j++)
            {
                double secs = 600 + ((i + j) % 5) * 480;     // 10 … 42 min
                var key = ReadingStatsAggregator.DayKey(AddDaysLocal(SeedDate, -dayOffsets[j]));
                daySeconds[key] = daySeconds.GetValueOrDefault(key) + secs;
                total += secs;
            }
            var firstRead = AddDaysLocal(SeedDate, -dayOffsets.Max());
            var lastRead = AddDaysLocal(SeedDate, -dayOffsets.Min());
            // Most demo works are finished reads; every fourth is left partway so
            // "words read" reflects partial progress, not full length.
            var maxProgress = i % 4 == 0 ? 0.45 : 1.0;
            store.Insert(new ReadingStat(
                summary.Id, summary.Title, summary.Author, summary.Fandoms, summary.Categories,
                summary.Relationships, summary.Rating, summary.WordCount, firstRead, lastRead,
                total, daySeconds, maxProgress, summary.IsComplete));
        }

        // Saved searches, in the search box's own syntax (SearchSyntax), so
        // loading one shows exact tag chips as a saved search made in the app would.
        // One has new-fic alerts on (#309) with two alerted fics unseen, so the
        // screenshots show the "2 new" line. Demo mode never runs checks.
        store.Insert(new SavedSearch("Slow burn, complete", """tag:"Slow Burn" complete:yes""")
        {
            AlertsEnabled = true,
            AlertsChangedAt = DateTimeOffset.Now,
            AlertsBaselineAt = DateTimeOffset.Now,
            AlertNewWorkIds = [90001, 90002],
        });
        store.Insert(new SavedSearch("Found family", """tag:"Found Family" tag:Hurt/Comfort"""));
        store.Insert(new SavedSearch("Coffee shop AUs", "coffee shop tag:Fluff rating:teen"));

        // Saved filters (Browse landing).
        var slowBurn = new AO3SearchFilters { FreeformNames = ["Slow Burn"], Complete = TriState.Yes };
        store.Insert(new SavedFilter("Slow Burn · Complete", slowBurn.SavedJson()));

        var cosy = new AO3SearchFilters { FreeformNames = ["Fluff"], Ratings = [Rating.General] };
        store.Insert(new SavedFilter("Fluff · General", cosy.SavedJson()));

        store.TrySave();
    }

    /// <summary>Calendar day arithmetic in the local time zone (keeps the wall
    /// clock across DST, like <c>Calendar.date(byAdding: .day …)</c>).</summary>
    private static DateTimeOffset AddDaysLocal(DateTimeOffset date, int days)
    {
        var tz = TimeZoneInfo.Local;
        var wall = TimeZoneInfo.ConvertTime(date, tz).DateTime.AddDays(days);
        wall = DateTime.SpecifyKind(wall, DateTimeKind.Unspecified);
        if (tz.IsInvalidTime(wall)) wall = wall.AddHours(1);
        return new DateTimeOffset(wall, tz.GetUtcOffset(wall));
    }

    /// <summary>The Library "Downloaded" filter checks for a real file in the
    /// library folder (see <see cref="WorkPersistence.EpubPath"/>), so write a
    /// tiny placeholder there. Demo-only.</summary>
    private static void WritePlaceholderEpub(int workId)
    {
        try
        {
            Directory.CreateDirectory(WorkPersistence.LibraryFolder);
            var path = WorkPersistence.EpubTargetPath(workId);
            if (!File.Exists(path)) File.WriteAllBytes(path, "PK\u0003\u0004demo"u8.ToArray());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

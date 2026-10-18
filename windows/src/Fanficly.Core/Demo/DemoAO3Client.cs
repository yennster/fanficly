namespace Fanficly.Core;

/// <summary>A fully offline client backed by a curated, all-ages catalog of
/// <b>original</b> (non-fandom) works. Used only for store screenshots and manual
/// demos — selected at launch when the app is started with <c>-demoMode</c>.
/// Nothing here ever ships in a normal run, and no request ever touches the
/// network.
///
/// Everything is rated General/Teen with no archive warnings, and the fandoms are
/// invented "(Original Work)" titles, so screenshots never surface mature or
/// explicit third-party content.</summary>
public sealed class DemoAO3Client : IAO3Client
{
    public Task LoginAsync(string username, string password, CancellationToken ct = default) => Task.CompletedTask;
    public Task LogoutAsync() => Task.CompletedTask;
    public Task<string?> CurrentUsernameAsync() => Task.FromResult<string?>("demo_reader");

    public Task<AO3SearchResults> SearchAsync(AO3SearchFilters filters, int page, CancellationToken ct = default)
    {
        IEnumerable<AO3WorkSummary> works = DemoCatalog.Works;

        // Light, best-effort filtering so typing a prompt narrows the list.
        if (filters.Ratings.Count > 0)
        {
            var names = filters.Ratings.Select(r => r.DisplayName()).ToHashSet();
            works = works.Where(w => names.Contains(w.Rating));
        }
        if (filters.FandomNames.Count > 0)
        {
            var wanted = filters.FandomNames.Select(n => n.ToLowerInvariant()).ToList();
            works = works.Where(w => w.Fandoms.Any(f => wanted.Any(x => f.ToLowerInvariant().Contains(x, StringComparison.Ordinal))));
        }
        if (filters.FreeformNames.Count > 0)
        {
            var wanted = filters.FreeformNames.Select(n => n.ToLowerInvariant()).ToList();
            works = works.Where(w => w.Freeforms.Any(t => wanted.Any(x => t.ToLowerInvariant().Contains(x, StringComparison.Ordinal))));
        }
        // Tags tapped from search suggestions can be any kind.
        if (filters.OtherTagNames.Count > 0)
        {
            var wanted = filters.OtherTagNames.Select(n => n.ToLowerInvariant()).ToList();
            works = works.Where(w =>
            {
                var tags = w.Fandoms.Concat(w.Relationships).Concat(w.Characters).Concat(w.Freeforms)
                    .Select(t => t.ToLowerInvariant()).ToList();
                return wanted.All(tags.Contains);
            });
        }
        if (filters.Categories.Count > 0)
        {
            var names = filters.Categories.Select(c => c.DisplayName()).ToHashSet();
            works = works.Where(w => w.Categories.Any(names.Contains));
        }
        works = filters.Complete switch
        {
            TriState.Yes => works.Where(w => w.IsComplete),
            TriState.No => works.Where(w => !w.IsComplete),
            _ => works,
        };

        // If nothing matched the structured filters, fall back to the full catalog
        // so the results screen is never empty in a demo.
        var list = works.ToList();
        if (list.Count == 0) list = DemoCatalog.Works.ToList();

        return Task.FromResult(new AO3SearchResults(list, 1, page, list.Count));
    }

    public Task<AO3SearchResults> FetchAuthorWorksAsync(string username, int page, CancellationToken ct = default)
    {
        var mine = DemoCatalog.Works.Where(w => w.AuthorUsername == username || w.Author == username).ToList();
        return Task.FromResult(new AO3SearchResults(mine.Count == 0 ? DemoCatalog.Works : mine, 1, page));
    }

    public Task<AO3SearchResults> FetchBookmarksAsync(string username, int page, CancellationToken ct = default) =>
        Task.FromResult(new AO3SearchResults(DemoCatalog.Works, 1, page));

    public Task<AO3WorkPayload> FetchWorkAsync(int id, CancellationToken ct = default) =>
        Task.FromResult(DemoCatalog.Payload(id));

    public Task<AO3WorkMetadata> FetchWorkMetadataAsync(int id, CancellationToken ct = default)
    {
        var w = DemoCatalog.Summary(id);
        return Task.FromResult(new AO3WorkMetadata(id, w.ChapterCount, w.TotalChapters, w.UpdatedAt));
    }

    public Task<IReadOnlyList<AO3Subscription>> FetchSubscriptionsAsync(string username, CancellationToken ct = default) =>
        Task.FromResult(DemoCatalog.Subscriptions);

    public Task<IReadOnlyList<AO3Comment>> FetchCommentsAsync(int workId, int? chapterId, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<AO3Comment>>(
        [
            new AO3Comment("1", "reader_one", "reader_one", "Today", "<p>This was wonderful — thank you for sharing!</p>", 0),
            new AO3Comment("2", "author", "author", "Today", "<p>Thank you so much! 💛</p>", 1),
        ]);

    public Task PostCommentAsync(int workId, int? chapterId, string text, CancellationToken ct = default) => Task.CompletedTask;

    public Task<IReadOnlyList<BrowseFandom>> FetchFandomsInCategoryAsync(string categoryName, CancellationToken ct = default) =>
        Task.FromResult(DemoCatalog.Fandoms);

    public Task<PopularSnapshot> FetchPopularSnapshotAsync(CancellationToken ct = default) =>
        Task.FromResult(new PopularSnapshot(PopularTags.Fandoms, PopularTags.Ships, PopularTags.Characters, DateTimeOffset.Now));

    public Task<IReadOnlyList<string>> AutocompleteAsync(AO3AutocompleteField field, string term, CancellationToken ct = default)
    {
        if (field != AO3AutocompleteField.Tag) return Task.FromResult<IReadOnlyList<string>>([term]);
        // Search suggestions: real tags from the curated catalog, so the offline
        // demo (and its screenshots) shows genuine matches.
        var needle = term.ToLowerInvariant();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        IReadOnlyList<string> matches = DemoCatalog.Works
            .SelectMany(w => w.Fandoms.Concat(w.Relationships).Concat(w.Characters).Concat(w.Freeforms))
            .Where(t => t.ToLowerInvariant().Contains(needle, StringComparison.Ordinal) && seen.Add(t))
            .ToList();
        return Task.FromResult(matches);
    }

    public Task<string> DownloadEpubAsync(int workId, CancellationToken ct = default) =>
        Task.FromResult(Path.Combine(Path.GetTempPath(), $"{workId}.epub"));

    public Task<string> ExportWorkAsync(int workId, WorkExportFormat format, string filename, CancellationToken ct = default) =>
        Task.FromResult(Path.Combine(Path.GetTempPath(), $"{filename}.{format.Ext()}"));

    public Task SubscribeToWorkAsync(int workId, CancellationToken ct = default) => Task.CompletedTask;

    public Task<KudosOutcome> LeaveKudosAsync(int workId, CancellationToken ct = default) => Task.FromResult(KudosOutcome.Left);
}

/// <summary>The curated demo catalog.</summary>
public static class DemoCatalog
{
    /// <summary>A fixed reference instant so the demo is deterministic (no clock reads).</summary>
    private static readonly DateTimeOffset ReferenceDate = DateTimeOffset.FromUnixTimeSeconds(1_780_000_000); // ~mid 2026

    /// <summary>The eight all-ages works shown across Search, Browse, Library,
    /// Recently Viewed and Subscriptions. Order doubles as the default search
    /// ranking.</summary>
    public static readonly IReadOnlyList<AO3WorkSummary> Works =
    [
        Make(90001, "The Long Way Home", "wanderlight",
            summary: "Stranded a galaxy from home, a salvage crew of strangers learns that the fastest route back is the one you build together.",
            rating: "General Audiences", categories: ["Gen"],
            fandoms: ["Starbound Atlas (Original Work)"],
            relationships: [], characters: ["Captain Reyes", "Wira", "Ode"],
            freeforms: ["Found Family", "Slow Burn", "Hurt/Comfort", "Adventure"],
            words: 48_213, chapters: 12, total: 12, kudos: 3204, hits: 51_882, complete: true, daysAgo: 4),
        Make(90002, "Letters Never Sent", "paperboats",
            summary: "Two lighthouse keepers on opposite headlands write the letters they never quite dare to deliver.",
            rating: "Teen And Up Audiences", categories: ["F/M"],
            fandoms: ["The Lighthouse Keepers (Original Work)"],
            relationships: ["Mara & Soren"], characters: ["Mara", "Soren"],
            freeforms: ["Epistolary", "Mutual Pining", "Slow Burn", "Soft"],
            words: 22_150, chapters: 8, total: 8, kudos: 1890, hits: 28_400, complete: true, daysAgo: 9),
        Make(90003, "Of Maps and Mistakes", "tealeaf",
            summary: "A disgraced cartographer and the rival who got her exiled are assigned to chart the same impossible coastline.",
            rating: "General Audiences", categories: ["Gen"],
            fandoms: ["Cartographer's Guild (Original Work)"],
            relationships: [], characters: ["Isolde", "Brannoch"],
            freeforms: ["Enemies to Lovers", "Adventure", "Banter", "Slow Burn"],
            words: 64_002, chapters: 15, total: 20, kudos: 5120, hits: 88_120, complete: false, daysAgo: 1),
        Make(90004, "Coffee, Two Sugars", "morningmugs",
            summary: "The new barista keeps spelling Theo's name wrong. Theo keeps coming back anyway.",
            rating: "Teen And Up Audiences", categories: ["M/M"],
            fandoms: ["Brewhaven (Original Work)"],
            relationships: ["Eli & Theo"], characters: ["Eli", "Theo"],
            freeforms: ["Coffee Shop AU", "Fluff", "First Meetings", "Slow Burn"],
            words: 12_400, chapters: 3, total: 3, kudos: 2750, hits: 40_310, complete: true, daysAgo: 6),
        Make(90005, "The Understudy", "stagelights",
            summary: "When the lead breaks her ankle on opening night, the understudy nobody believed in finally steps into the light.",
            rating: "General Audiences", categories: ["Gen"],
            fandoms: ["Marigold Theatre (Original Work)"],
            relationships: [], characters: ["Priya", "Daniel"],
            freeforms: ["Theatre", "Friendship", "Found Family", "Hurt/Comfort"],
            words: 31_200, chapters: 9, total: 9, kudos: 1450, hits: 19_905, complete: true, daysAgo: 14),
        Make(90006, "Gardens in Winter", "frostfern",
            summary: "Two neighbours, one shared greenhouse, and a whole cold season to figure out what's growing between them.",
            rating: "Teen And Up Audiences", categories: ["F/F"],
            fandoms: ["Hollowdale (Original Work)"],
            relationships: ["Ivy & Wren"], characters: ["Ivy", "Wren"],
            freeforms: ["Cottagecore", "Soft", "Found Family", "Slow Burn"],
            words: 27_800, chapters: 7, total: 7, kudos: 3380, hits: 44_770, complete: true, daysAgo: 3),
        Make(90007, "Signal Lost", "orbital",
            summary: "The only two researchers left awake on a sleeper ship trade messages across a failing comms link to keep each other sane.",
            rating: "Teen And Up Audiences", categories: ["Gen"],
            fandoms: ["Deep Field (Original Work)"],
            relationships: [], characters: ["Yuki", "Cole"],
            freeforms: ["Science Fiction", "Slow Burn", "Hurt/Comfort", "Space"],
            words: 41_000, chapters: 11, total: 16, kudos: 2210, hits: 33_540, complete: false, daysAgo: 2),
        Make(90008, "The Baker's Dozen", "flourchild",
            summary: "A failing small-town bakery, twelve impossible orders, and one very stubborn pastry chef who refuses to close.",
            rating: "General Audiences", categories: ["Gen"],
            fandoms: ["Sweetbriar Lane (Original Work)"],
            relationships: [], characters: ["Margot", "Sam"],
            freeforms: ["Small Town", "Baking", "Fluff", "Found Family"],
            words: 19_500, chapters: 6, total: 6, kudos: 1675, hits: 22_115, complete: true, daysAgo: 11),
    ];

    public static readonly IReadOnlyList<BrowseFandom> Fandoms =
        Works.Select(w => new BrowseFandom(w.Fandoms.Count > 0 ? w.Fandoms[0] : "Original Work")).ToList();

    public static readonly IReadOnlyList<AO3Subscription> Subscriptions =
    [
        new AO3Subscription(AO3SubscriptionKind.Work, "90003", "Of Maps and Mistakes", "tealeaf"),
        new AO3Subscription(AO3SubscriptionKind.Work, "90007", "Signal Lost", "orbital"),
        new AO3Subscription(AO3SubscriptionKind.User, "wanderlight", "wanderlight", null),
    ];

    /// <summary>UI tests (ReaderLayoutTests) pass <c>-demoLongChapters</c> so a chapter
    /// runs to many pages and a page in its middle is always full. The screenshots
    /// keep the short chapters.</summary>
    public static bool LongChapters { get; set; } = Environment.GetCommandLineArgs().Contains("-demoLongChapters");

    public static AO3WorkSummary Summary(int id) => Works.FirstOrDefault(w => w.Id == id) ?? Works[0];

    public static AO3WorkPayload Payload(int id)
    {
        var s = Summary(id);
        var count = Math.Max(1, Math.Min(s.ChapterCount, 3)); // render up to 3 chapters for the reader
        var chapters = Enumerable.Range(1, count)
            .Select(idx => new AO3ChapterPayload(idx, ChapterTitles[(idx - 1) % ChapterTitles.Length], ChapterHtml(idx)))
            .ToList();
        return new AO3WorkPayload(s, chapters);
    }

    private static readonly string[] ChapterTitles = ["Landfall", "What the Tide Brought", "The Long Way Home"];

    private static AO3WorkSummary Make(
        int id, string title, string author, string summary,
        string rating, IReadOnlyList<string> categories, IReadOnlyList<string> fandoms,
        IReadOnlyList<string> relationships, IReadOnlyList<string> characters, IReadOnlyList<string> freeforms,
        int words, int chapters, int total, int kudos, int hits,
        bool complete, int daysAgo) => new()
        {
            Id = id,
            Title = title,
            Author = author,
            AuthorUsername = author,
            Summary = summary,
            Rating = rating,
            Warnings = ["No Archive Warnings Apply"],
            Categories = categories,
            Fandoms = fandoms,
            Characters = characters,
            Relationships = relationships,
            Freeforms = freeforms,
            WordCount = words,
            ChapterCount = complete ? total : chapters,
            TotalChapters = total,
            Language = "English",
            Kudos = kudos,
            Hits = hits,
            IsComplete = complete,
            UpdatedAt = ReferenceDate.AddDays(-daysAgo),
        };

    /// <summary>Original, wholesome prose so the reader screenshot looks like a real fic.</summary>
    private static string ChapterHtml(int chapter)
    {
        var opening = chapter switch
        {
            1 => "<p>The morning the engines finally went quiet, Reyes woke to the strangest sound in the world: nothing at all. No hum in the deck plating, no rattle of the coolant lines, no distant cough of the recyclers. Just the small noises of a ship full of people pretending, very hard, to still be asleep.</p>",
            2 => "<p>By the second week they had a routine, which Wira insisted was the same thing as a plan if you said it with enough confidence. Wake. Check the patch on the hull. Argue gently about breakfast. Pretend the long-range array might, today, finally catch something other than static.</p>",
            _ => "<p>Home, Ode decided, was not a place after all. It was the particular way the others laughed when they thought no one was keeping score — Reyes too loud, Wira not nearly loud enough, and somewhere underneath it the steady thrum of a ship that had decided, against all odds, to keep going.</p>",
        };
        var repeats = LongChapters ? 10 : 1;
        return opening + "\n" + string.Join("\n", Enumerable.Repeat(Body, repeats));
    }

    private const string Body =
        """
        <p>“You're up early,” said Wira, who was already three cups of something vaguely coffee-shaped into the day. She slid a mug across the table without being asked, which was its own kind of language. “Couldn't sleep, or didn't want to?”</p>
        <p>“Both,” Reyes admitted. “Mostly I keep thinking about the long way round. Six months, maybe seven, if the slingshot holds. Everyone keeps asking me if it's worth it.”</p>
        <p>Wira considered this with the seriousness she reserved for genuinely important questions and absolutely nothing else. “And what do you tell them?”</p>
        <p>Outside the viewport the stars hung close and patient, the way they only ever did when you had nowhere to be and all the time in the world to get there. Reyes wrapped both hands around the warm mug and, for the first time in a long while, found that the answer came easily.</p>
        <p>“I tell them,” she said, “that the long way home is still the way home.”</p>
        """;
}

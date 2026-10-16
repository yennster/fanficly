namespace Fanficly.Core;

/// <summary>
/// When it's OK to ask for a store rating. The bar is deliberately high so the
/// prompt only ever reaches people who are clearly enjoying the app: it needs a
/// moment of success (a story just finished, checked by the caller), a few
/// finished stories over several reading days, at least a week since the first
/// read, and it asks at most once per app version and months apart. The store
/// adds its own limits on top.
/// </summary>
public static class ReviewPromptPolicy
{
    public const int MinFinishedStories = 3;
    public const int MinReadingDays = 3;
    public const int MinDaysSinceFirstRead = 7;
    public const int MinDaysBetweenPrompts = 120;

    public static bool ShouldAsk(
        DateTimeOffset now,
        int finishedStories,
        int readingDays,
        DateTimeOffset? firstReadAt,
        DateTimeOffset? lastPromptAt,
        string? lastPromptVersion,
        string currentVersion)
    {
        if (finishedStories < MinFinishedStories || readingDays < MinReadingDays) return false;
        if (firstReadAt is not { } first || (now - first).TotalSeconds < MinDaysSinceFirstRead * 86_400.0) return false;
        if (lastPromptVersion == currentVersion) return false;
        if (lastPromptAt is { } last && (now - last).TotalSeconds < MinDaysBetweenPrompts * 86_400.0) return false;
        return true;
    }
}

/// <summary>What <see cref="ReviewPromptPolicy"/> needs from the reading stats.</summary>
/// <param name="FinishedStories">Stats rows whose work is finished.</param>
/// <param name="ReadingDays">Distinct days with reading time, across all rows.</param>
/// <param name="FirstReadAt">The earliest first-read date; null with no stats.</param>
public sealed record ReviewPromptStats(int FinishedStories, int ReadingDays, DateTimeOffset? FirstReadAt)
{
    /// <summary>Summarizes reading-stat rows: each row's finished flag, the
    /// <c>yyyy-MM-dd</c> keys of its day buckets, and its first-read date.</summary>
    public static ReviewPromptStats From(IEnumerable<(bool IsFinished, IEnumerable<string> DayKeys, DateTimeOffset FirstReadAt)> stats)
    {
        var finished = 0;
        var days = new HashSet<string>(StringComparer.Ordinal);
        DateTimeOffset? first = null;
        foreach (var (isFinished, dayKeys, firstReadAt) in stats)
        {
            if (isFinished) finished++;
            days.UnionWith(dayKeys);
            if (first is null || firstReadAt < first) first = firstReadAt;
        }
        return new ReviewPromptStats(finished, days.Count, first);
    }
}

/// <summary>Shows the platform's rate-this-app dialog. The Windows app implements
/// it with the Microsoft Store rating dialog (<c>StoreContext.RequestRateAndReviewAppAsync</c>).</summary>
public interface IStoreReviewRequester
{
    Task RequestReviewAsync();
}

/// <summary>
/// Decides when to show the store rating prompt. The reader reports a story it
/// just finished; when that reader closes, and only then, the policy is checked
/// and the prompt shows over the list the reader returns to — never on top of
/// the story text and never mid-read.
/// </summary>
public sealed class ReviewPrompter
{
    public static ReviewPrompter Shared { get; set; } = new();

    public const string LastPromptAtKey = "review.lastPromptAt";
    public const string LastPromptVersionKey = "review.lastPromptVersion";

    /// <summary>The Swift app's App Store "write a review" link.</summary>
    public static readonly Uri WriteReviewUri = new("https://apps.apple.com/app/id6775897153?action=write-review");

    /// <summary>The Microsoft Store review page for a Store product id (Settings →
    /// About "Rate Fanficly").</summary>
    public static Uri MicrosoftStoreReviewUri(string productId) =>
        new($"ms-windows-store://review/?ProductId={Uri.EscapeDataString(productId)}");

    /// <summary>How long after the reader closes the prompt shows, so the
    /// navigation settles and it lands over the list, not mid-transition.</summary>
    public static TimeSpan PromptDelay { get; set; } = TimeSpan.FromSeconds(1.2);

    private readonly IKeyValueStore? _store;
    private IKeyValueStore Store => _store ?? KeyValueStores.Default;

    /// <summary>A story was finished during the current reading session.</summary>
    private bool _finishedThisSession;

    /// <param name="store">Where the ask is recorded; null uses <see cref="KeyValueStores.Default"/>.</param>
    public ReviewPrompter(IKeyValueStore? store = null) => _store = store;

    /// <summary>Shows the dialog; when null only <see cref="ReviewRequested"/> fires.</summary>
    public IStoreReviewRequester? Requester { get; set; }

    /// <summary>The app's version (the package version); asks at most once per version.</summary>
    public string CurrentVersion { get; set; } = "";

    /// <summary>True in demo and unit-test runs, which never ask.</summary>
    public bool IsSuppressed { get; set; }

    /// <summary>Bumped each time the prompt should show.</summary>
    public int RequestCount { get; private set; }

    /// <summary>Raised when the prompt should show (before <see cref="PromptDelay"/>).</summary>
    public event Action? ReviewRequested;

    public void StoryFinished() => _finishedThisSession = true;

    /// <summary>Called as a reader leaves the screen. Loads the reading stats and
    /// checks the policy only if a story was just finished. Returns whether the
    /// prompt was requested.</summary>
    public bool ReaderClosed(Func<ReviewPromptStats> loadStats, DateTimeOffset? now = null)
    {
        if (!_finishedThisSession) return false;
        _finishedThisSession = false;
        if (IsSuppressed) return false;

        var at = now ?? DateTimeOffset.Now;
        var stats = loadStats();
        if (!ReviewPromptPolicy.ShouldAsk(
                at, stats.FinishedStories, stats.ReadingDays, stats.FirstReadAt,
                Store.GetDate(LastPromptAtKey), Store.GetString(LastPromptVersionKey), CurrentVersion))
            return false;

        // Recorded up front: the store never says whether the prompt showed.
        Store.SetDate(LastPromptAtKey, at);
        Store.SetString(LastPromptVersionKey, CurrentVersion);
        RequestCount++;
        ReviewRequested?.Invoke();
        if (Requester is { } requester) _ = ShowAfterDelayAsync(requester);
        return true;
    }

    private static async Task ShowAfterDelayAsync(IStoreReviewRequester requester)
    {
        try
        {
            await Task.Delay(PromptDelay);
            await requester.RequestReviewAsync();
        }
        catch (Exception)
        {
            // A rating dialog that fails to show is not worth surfacing.
        }
    }
}

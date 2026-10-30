using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The store rating prompt must stay well-timed: only for readers with
/// real history, every few weeks at most, never again once they've rated or
/// dismissed it, and only on the read that actually finishes a story.</summary>
public class ReviewPromptTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
    private static DateTimeOffset DaysAgo(double n) => Now.AddSeconds(-n * 86_400);

    private static bool Ask(int finished = 3, int days = 3, DateTimeOffset? firstRead = null,
                            DateTimeOffset? lastPrompt = null, bool isDone = false) =>
        ReviewPromptPolicy.ShouldAsk(Now, finished, days, firstRead ?? DaysAgo(60), lastPrompt, isDone);

    [Fact]
    public void EngagedReader_NeverAskedBefore_IsAsked()
    {
        Assert.True(Ask());
    }

    [Fact]
    public void NeedsEnoughFinishedStoriesAndReadingDays()
    {
        Assert.False(Ask(finished: 2));
        Assert.False(Ask(days: 2));
    }

    [Fact]
    public void NeedsAWeekSinceTheFirstRead()
    {
        Assert.False(Ask(firstRead: DaysAgo(6)));
        Assert.True(Ask(firstRead: DaysAgo(7)));
        Assert.False(ReviewPromptPolicy.ShouldAsk(Now, 9, 9, null, null, false));
    }

    [Fact]
    public void AsksAgainEveryFewWeeks()
    {
        Assert.False(Ask(lastPrompt: DaysAgo(20)));
        Assert.True(Ask(lastPrompt: DaysAgo(21)));
        // Someone asked under the old once-per-version rules is asked again
        // on the new cadence, whatever version they're on.
        Assert.True(Ask(lastPrompt: DaysAgo(130)));
    }

    [Fact]
    public void NeverAgainOnceRatedOrDismissed()
    {
        Assert.False(Ask(isDone: true));
        Assert.False(Ask(lastPrompt: DaysAgo(400), isDone: true));
    }

    // MARK: - The "just finished" cue
    // test_record_* live in ReadingStatsRecordTests (they exercise ReadingStatsStore.Record).

    // MARK: - Windows-only: the prompter's bookkeeping

    private sealed class CountingRequester(ReviewPromptOutcome outcome = ReviewPromptOutcome.Unknown) : IStoreReviewRequester
    {
        public int Calls;
        public Task<ReviewPromptOutcome> RequestReviewAsync() { Interlocked.Increment(ref Calls); return Task.FromResult(outcome); }
    }

    private static ReviewPromptStats Engaged() => ReviewPromptStats.From(
    [
        (true, ["2026-01-01"], DaysAgo(30)),
        (true, ["2026-01-02", "2026-01-01"], DaysAgo(20)),
        (true, ["2026-01-03"], DaysAgo(10)),
    ]);

    [Fact]
    public void Stats_CountFinishedStoriesDistinctDaysAndFirstRead()
    {
        Assert.Equal(new ReviewPromptStats(3, 3, DaysAgo(30)), Engaged());
        Assert.Equal(new ReviewPromptStats(0, 0, null), ReviewPromptStats.From([]));
    }

    [Fact]
    public void Prompter_AsksOnlyAfterAFinishedStory_AndRecordsTheAsk()
    {
        var store = new InMemoryKeyValueStore();
        var prompter = new ReviewPrompter(store);
        var requested = 0;
        prompter.ReviewRequested += () => requested++;

        Assert.False(prompter.ReaderClosed(Engaged, Now)); // nothing finished this session
        prompter.StoryFinished();
        Assert.True(prompter.ReaderClosed(Engaged, Now));
        Assert.Equal(1, prompter.RequestCount);
        Assert.Equal(1, requested);
        Assert.Equal(Now, store.GetDate(ReviewPrompter.LastPromptAtKey));

        prompter.StoryFinished();
        Assert.False(prompter.ReaderClosed(Engaged, Now)); // not again so soon
        prompter.StoryFinished();
        Assert.True(prompter.ReaderClosed(Engaged, Now.AddDays(21))); // nor rated, so ask again
    }

    [Fact]
    public void Prompter_OldVersionKeyStillCountsTheLastAsk()
    {
        // A reader asked under the old rules has review.lastPromptAt (and a
        // version key nothing reads any more); the new cadence starts from it.
        var store = new InMemoryKeyValueStore();
        store.SetDate(ReviewPrompter.LastPromptAtKey, DaysAgo(5));
        store.SetString("review.lastPromptVersion", "1.8.0");
        var prompter = new ReviewPrompter(store);
        prompter.StoryFinished();
        Assert.False(prompter.ReaderClosed(Engaged, Now));
    }

    [Theory]
    [InlineData(ReviewPromptOutcome.Rated, true)]
    [InlineData(ReviewPromptOutcome.Dismissed, true)]
    [InlineData(ReviewPromptOutcome.Unknown, false)]
    public async Task Prompter_StopsForGoodOnceRatedOrDismissed(ReviewPromptOutcome outcome, bool done)
    {
        var store = new InMemoryKeyValueStore();
        var requester = new CountingRequester(outcome);
        var prompter = new ReviewPrompter(store) { Requester = requester };
        prompter.StoryFinished();
        Assert.True(prompter.ReaderClosed(Engaged, Now));
        for (var i = 0; i < 100 && Volatile.Read(ref requester.Calls) == 0; i++) await Task.Delay(50);
        // The outcome is recorded just after the requester returns.
        for (var i = 0; i < 20 && store.GetBool(ReviewPrompter.DoneKey) != done; i++) await Task.Delay(50);
        Assert.Equal(done, store.GetBool(ReviewPrompter.DoneKey));

        prompter.StoryFinished();
        Assert.Equal(!done, prompter.ReaderClosed(Engaged, Now.AddDays(400)));
    }

    [Fact]
    public void Prompter_OpeningTheReviewPageStopsTheAsks()
    {
        var store = new InMemoryKeyValueStore();
        var prompter = new ReviewPrompter(store);
        prompter.OpenedReviewPage();
        prompter.StoryFinished();
        Assert.False(prompter.ReaderClosed(Engaged, Now));
    }

    [Fact]
    public void Prompter_NeverAsksWhenSuppressed()
    {
        var prompter = new ReviewPrompter(new InMemoryKeyValueStore()) { IsSuppressed = true };
        prompter.StoryFinished();
        Assert.False(prompter.ReaderClosed(Engaged, Now));
    }

    [Fact]
    public async Task Prompter_ShowsTheStoreDialogAfterTheDelay()
    {
        var requester = new CountingRequester();
        var prompter = new ReviewPrompter(new InMemoryKeyValueStore()) { Requester = requester };
        prompter.StoryFinished();
        Assert.True(prompter.ReaderClosed(Engaged, Now));
        for (var i = 0; i < 100 && Volatile.Read(ref requester.Calls) == 0; i++) await Task.Delay(50);
        Assert.Equal(1, requester.Calls);
    }

    [Fact]
    public void MicrosoftStoreReviewUri()
    {
        Assert.Equal("ms-windows-store://review/?ProductId=9NBLGGH4R315", ReviewPrompter.MicrosoftStoreReviewUri("9NBLGGH4R315").OriginalString);
        Assert.Equal("https://apps.apple.com/app/id6775897153?action=write-review", ReviewPrompter.WriteReviewUri.OriginalString);
    }
}

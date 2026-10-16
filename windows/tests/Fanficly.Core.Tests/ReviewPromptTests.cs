using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The store rating prompt must stay rare and well-timed: only for
/// readers with real history, once per version, months apart, and only on the
/// read that actually finishes a story.</summary>
public class ReviewPromptTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
    private static DateTimeOffset DaysAgo(double n) => Now.AddSeconds(-n * 86_400);

    private static bool Ask(int finished = 3, int days = 3, DateTimeOffset? firstRead = null,
                            DateTimeOffset? lastPrompt = null, string? lastVersion = null,
                            string version = "1.9.0") =>
        ReviewPromptPolicy.ShouldAsk(
            Now, finished, days, firstRead ?? DaysAgo(30), lastPrompt, lastVersion, version);

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
        Assert.False(ReviewPromptPolicy.ShouldAsk(Now, 9, 9, null, null, null, "1.9.0"));
    }

    [Fact]
    public void AtMostOncePerVersion()
    {
        Assert.False(Ask(lastPrompt: DaysAgo(400), lastVersion: "1.9.0", version: "1.9.0"));
    }

    [Fact]
    public void MonthsBetweenPrompts_EvenAcrossVersions()
    {
        Assert.False(Ask(lastPrompt: DaysAgo(30), lastVersion: "1.8.0", version: "1.9.0"));
        Assert.True(Ask(lastPrompt: DaysAgo(121), lastVersion: "1.8.0", version: "1.9.0"));
    }

    // MARK: - The "just finished" cue
    // test_record_flagsOnlyTheReadThatFinishesTheStory and
    // test_record_firstReadThatAlreadyFinishes_counts exercise
    // ReadingStatsStore.record (the persistence worker's area).

    // MARK: - Windows-only: the prompter's bookkeeping

    private sealed class CountingRequester : IStoreReviewRequester
    {
        public int Calls;
        public Task RequestReviewAsync() { Interlocked.Increment(ref Calls); return Task.CompletedTask; }
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
        var prompter = new ReviewPrompter(store) { CurrentVersion = "1.9.0" };
        var requested = 0;
        prompter.ReviewRequested += () => requested++;

        Assert.False(prompter.ReaderClosed(Engaged, Now)); // nothing finished this session
        prompter.StoryFinished();
        Assert.True(prompter.ReaderClosed(Engaged, Now));
        Assert.Equal(1, prompter.RequestCount);
        Assert.Equal(1, requested);
        Assert.Equal("1.9.0", store.GetString(ReviewPrompter.LastPromptVersionKey));
        Assert.Equal(Now, store.GetDate(ReviewPrompter.LastPromptAtKey));

        prompter.StoryFinished();
        Assert.False(prompter.ReaderClosed(Engaged, Now)); // once per version
    }

    [Fact]
    public void Prompter_NeverAsksWhenSuppressed()
    {
        var prompter = new ReviewPrompter(new InMemoryKeyValueStore()) { CurrentVersion = "1.9.0", IsSuppressed = true };
        prompter.StoryFinished();
        Assert.False(prompter.ReaderClosed(Engaged, Now));
    }

    [Fact]
    public async Task Prompter_ShowsTheStoreDialogAfterTheDelay()
    {
        var requester = new CountingRequester();
        var prompter = new ReviewPrompter(new InMemoryKeyValueStore()) { CurrentVersion = "2.0", Requester = requester };
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

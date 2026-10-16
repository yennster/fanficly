using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The "just finished" cue for the rating prompt (the
/// <c>ReadingStatsStore.record</c> cases of ReviewPromptTests.swift): only the
/// read that actually finishes a story counts.</summary>
public sealed class ReadingStatsRecordTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    private static bool Record(double progress, LibraryStore context) =>
        ReadingStatsStore.Record(42, "A Fic", "someone", [], [], [], "", 10_000, 60, context,
                                 progress: progress, isComplete: true, date: Now);

    [Fact]
    public void Record_FlagsOnlyTheReadThatFinishesTheStory()
    {
        using var context = LibraryStore.OpenInMemory();
        Assert.False(Record(0.4, context));  // mid-read isn't a finish
        Assert.True(Record(1.0, context));   // reaching the end is
        Assert.False(Record(1.0, context));  // re-reading a finished story isn't new
        Assert.False(Record(0.2, context));  // a re-skim never un-finishes
    }

    [Fact]
    public void Record_FirstReadThatAlreadyFinishes_Counts()
    {
        using var context = LibraryStore.OpenInMemory();
        Assert.True(Record(0.97, context));  // complete work at 95%+ is finished
    }
}

using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>RM-003 (ReadingSpeedTests in PersistenceTests.swift): the
/// reading-time estimate's pace (fallback and clamping) and its formatting at
/// no words, under a minute, minutes and hours.</summary>
public sealed class ReadingSpeedTests
{
    private static ReadingStatSnapshot Snap(int id, int words, double seconds, double progress = 1.0) =>
        new(id, "", "A", [], [], [], "", words, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch,
            seconds, new Dictionary<string, double>(), progress, false);

    [Fact]
    public void WordsPerMinute_FallsBackUntilThreeFinishedTimedWorks()
    {
        Assert.Equal(250.0, ReadingSpeed.WordsPerMinute([]));
        // Two finished works at 300 wpm aren't enough yet.
        ReadingStatSnapshot[] two = [Snap(1, 3_000, 600), Snap(2, 3_000, 600)];
        Assert.Equal(250.0, ReadingSpeed.WordsPerMinute(two));
        // Unfinished and zero-time (backfilled) works don't count toward the three.
        Assert.Equal(250.0, ReadingSpeed.WordsPerMinute([.. two, Snap(3, 3_000, 600, progress: 0.5), Snap(4, 3_000, 0)]));
        // A third finished, timed work switches to the personal pace.
        Assert.Equal(300.0, ReadingSpeed.WordsPerMinute([.. two, Snap(5, 3_000, 600)]), 3);
    }

    [Fact]
    public void WordsPerMinute_IsTheMedianWorksPace()
    {
        // 400, 500 and 200 wpm → 400; an unfinished work's time doesn't count.
        ReadingStatSnapshot[] snaps = [Snap(1, 2_000, 300), Snap(2, 4_000, 480), Snap(3, 6_000, 1_800),
                                       Snap(4, 50_000, 36_000, progress: 0.1)];
        Assert.Equal(400.0, ReadingSpeed.WordsPerMinute(snaps), 3);
        // An even count averages the middle two: 200, 400, 500, 600 → 450.
        Assert.Equal(450.0, ReadingSpeed.WordsPerMinute([.. snaps, Snap(5, 6_000, 600)]), 3);
    }

    [Fact]
    public void WordsPerMinute_IgnoresASkimAndARereadSwing()
    {
        var honest = Enumerable.Range(1, 3).Select(i => Snap(i, 5_000, 1_200)).ToList();   // 250 wpm each
        // A 150k-word work jumped to the end in 5 minutes, and a re-read that
        // doubled a work's time, leave the pace where it was.
        var skimmed = Snap(4, 150_000, 300);
        var reread = Snap(5, 5_000, 4_800);
        Assert.Equal(250.0, ReadingSpeed.WordsPerMinute([.. honest, skimmed]), 3);
        Assert.Equal(250.0, ReadingSpeed.WordsPerMinute([.. honest, skimmed, reread]), 3);
    }

    [Fact]
    public void WordsPerMinute_IsClamped()
    {
        Assert.Equal(600.0, ReadingSpeed.WordsPerMinute(Enumerable.Range(1, 3).Select(i => Snap(i, 10_000, 60))));
        Assert.Equal(120.0, ReadingSpeed.WordsPerMinute(Enumerable.Range(1, 3).Select(i => Snap(i, 1_000, 3_600))));
    }

    [Fact]
    public void WordsPerMinute_FromTheLibrary_FollowsNewStats()
    {
        using var store = LibraryStore.OpenInMemory();
        Assert.Equal(250.0, ReadingSpeed.WordsPerMinute(store));
        // Three finished works of 3,000 words in 10 minutes each: 300 wpm, and
        // the cached pace updates as each saves.
        for (var id = 1; id <= 3; id++)
            ReadingStatsStore.Record(id, "Fic", "someone", [], [], [], "", 3_000, 600, store, progress: 1.0);
        Assert.Equal(300.0, ReadingSpeed.WordsPerMinute(store), 3);
        // A different library isn't served the first one's pace.
        using var other = LibraryStore.OpenInMemory();
        Assert.Equal(250.0, ReadingSpeed.WordsPerMinute(other));
    }

    [Theory]
    [InlineData(0, null)]
    [InlineData(-5, null)]
    [InlineData(100, "<1 min")]       // 0.4 min
    [InlineData(250, "~1 min")]
    [InlineData(11_250, "~45 min")]
    [InlineData(14_900, "~1 hr")]     // 59.6 rounds up
    [InlineData(15_000, "~1 hr")]
    [InlineData(31_250, "~2 hr 5 min")]
    [InlineData(200_000, "~13 hr")]   // 13 hr 20 min, minutes dropped
    public void Estimate_Formatting(int words, string? expected) =>
        Assert.Equal(expected, ReadingSpeed.Estimate(words));

    [Fact]
    public void Estimate_FollowsThePace() =>
        Assert.Equal("~30 min", ReadingSpeed.Estimate(12_000, 400));

    [Theory]
    [InlineData(0, null)]
    [InlineData(100, "Under a minute to read")]
    [InlineData(250, "About 1 minute to read")]
    [InlineData(15_000, "About 1 hour to read")]
    [InlineData(31_250, "About 2 hours 5 minutes to read")]
    public void SpokenEstimate(int words, string? expected) =>
        Assert.Equal(expected, ReadingSpeed.SpokenEstimate(words));
}

using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The Listen sleep timer (#182): 15, 30 or 60 minutes, or the end of
/// the chapter, always pausing between paragraphs; and the screen let go while
/// narration plays.</summary>
public class SleepTimerTests
{
    [Fact]
    public void ChoicesAreTheIssuesFour()
    {
        Assert.Equal([new SleepTimer(15), new SleepTimer(30), new SleepTimer(60), SleepTimer.EndOfChapter], SleepTimer.Choices);
        Assert.Equal(["15 minutes", "30 minutes", "1 hour", "End of chapter"], SleepTimer.Choices.Select(c => c.Title));
    }

    [Fact]
    public void TimedChoicesRunTheirMinutes()
    {
        Assert.Equal(TimeSpan.FromMinutes(15), new SleepTimer(15).Duration);
        Assert.Equal(TimeSpan.FromHours(1), new SleepTimer(60).Duration);
        Assert.Null(SleepTimer.EndOfChapter.Duration);
    }

    [Fact]
    public void RunningOutPausesOnlyNarrationThatsPlaying()
    {
        Assert.True(SleepTimer.PausesWhenRunningOut(isPlaying: true));
        Assert.False(SleepTimer.PausesWhenRunningOut(isPlaying: false));
    }

    [Fact]
    public void OnlyEndOfChapterPausesAtTheChaptersEnd()
    {
        Assert.True(SleepTimer.PausesAtChapterEnd(SleepTimer.EndOfChapter));
        Assert.False(SleepTimer.PausesAtChapterEnd(new SleepTimer(15)));
        Assert.False(SleepTimer.PausesAtChapterEnd(null));
    }

    [Fact]
    public void APendingPauseStopsBeforeTheNextParagraph()
    {
        Assert.Equal(SleepParagraphEnd.Pause, SleepTimer.ParagraphEnd(isLast: false, sleepPausePending: true));
        Assert.Equal(SleepParagraphEnd.CarryOn, SleepTimer.ParagraphEnd(isLast: false, sleepPausePending: false));
    }

    [Fact]
    public void TheLastParagraphAlwaysFinishesTheChapter()
    {
        Assert.Equal(SleepParagraphEnd.FinishChapter, SleepTimer.ParagraphEnd(isLast: true, sleepPausePending: true));
        Assert.Equal(SleepParagraphEnd.FinishChapter, SleepTimer.ParagraphEnd(isLast: true, sleepPausePending: false));
    }

    [Fact]
    public void TheScreenIsHeldOnlyWhileNarrationIsntPlaying()
    {
        Assert.True(SleepTimer.HoldsScreenAwake(keepScreenAwake: true, isPlaying: false, pausedBySleepTimer: false));
        Assert.False(SleepTimer.HoldsScreenAwake(keepScreenAwake: true, isPlaying: true, pausedBySleepTimer: false));
        Assert.False(SleepTimer.HoldsScreenAwake(keepScreenAwake: true, isPlaying: false, pausedBySleepTimer: true));
        Assert.False(SleepTimer.HoldsScreenAwake(keepScreenAwake: false, isPlaying: false, pausedBySleepTimer: false));
    }
}

namespace Fanficly.Core;

/// <summary>
/// The Listen sleep timer (#182; Swift's <c>SleepTimer</c>): bedtime listening
/// pauses once a span runs out, after the paragraph being spoken, or at the end
/// of the chapter. <see cref="Minutes"/> 0 is "End of chapter".
/// </summary>
public readonly record struct SleepTimer(int Minutes)
{
    public static readonly SleepTimer EndOfChapter = new(0);

    /// <summary>What the Listen bar offers, in order.</summary>
    public static IReadOnlyList<SleepTimer> Choices { get; } = [new(15), new(30), new(60), EndOfChapter];

    public bool IsEndOfChapter => Minutes == 0;

    public string Title => Minutes switch
    {
        0 => "End of chapter",
        60 => "1 hour",
        var m => $"{m} minutes",
    };

    /// <summary>How long a timed choice runs; null for "End of chapter".</summary>
    public TimeSpan? Duration => IsEndOfChapter ? null : TimeSpan.FromMinutes(Minutes);

    /// <summary>A timed sleep timer running out pauses only narration that's
    /// playing; with narration already paused it just turns itself off.</summary>
    public static bool PausesWhenRunningOut(bool isPlaying) => isPlaying;

    /// <summary>Whether a chapter's end pauses narration (rather than rolling on).</summary>
    public static bool PausesAtChapterEnd(SleepTimer? timer) => timer is { IsEndOfChapter: true };

    /// <summary>What a paragraph finishing does: the chapter's last one ends the
    /// chapter (a pending sleep pause then holds the next chapter at its start);
    /// any other pauses before the next when a sleep pause is pending, else
    /// narration carries on.</summary>
    public static SleepParagraphEnd ParagraphEnd(bool isLast, bool sleepPausePending) =>
        isLast ? SleepParagraphEnd.FinishChapter
        : sleepPausePending ? SleepParagraphEnd.Pause
        : SleepParagraphEnd.CarryOn;

    /// <summary>"Keep screen awake", except while Listen plays and after the
    /// sleep timer paused it until something plays again, so bedtime listening
    /// lets the display sleep.</summary>
    public static bool HoldsScreenAwake(bool keepScreenAwake, bool isPlaying, bool pausedBySleepTimer) =>
        keepScreenAwake && !isPlaying && !pausedBySleepTimer;
}

public enum SleepParagraphEnd { FinishChapter, Pause, CarryOn }

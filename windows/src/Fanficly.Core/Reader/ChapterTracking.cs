using System.Globalization;

namespace Fanficly.Core;

/// <summary>A reading position: a chapter (1-based index) and a rendered
/// paragraph index within it.</summary>
public readonly record struct ReadingAnchor(int Chapter, int Paragraph);

/// <summary>Reading-position tracking for the flowing reader modes. The WinUI
/// reader reports each anchored paragraph's top offset (keyed
/// <c>c&lt;chapter&gt;-p&lt;paragraph&gt;</c>) and each chapter's top offset, in the
/// scroll viewport's coordinates, and these pure functions pick the position.
/// (Swift's PreferenceKeys, which collected the offsets, have no port.)</summary>
public static class ChapterTracking
{
    /// <summary>The line just below the navigation bar that counts as "the top".</summary>
    public const double DefaultThreshold = 80;

    /// <summary>The topmost paragraph anchor currently at/above the threshold line.</summary>
    public static ReadingAnchor? TopmostAnchor(IReadOnlyDictionary<string, double> offsets,
                                               double threshold = DefaultThreshold)
    {
        KeyValuePair<string, double>? pick = null;
        foreach (var entry in offsets)
            if (entry.Value <= threshold && (pick is null || entry.Value > pick.Value.Value)) pick = entry;
        if (pick is null)
            foreach (var entry in offsets)
                if (pick is null || entry.Value < pick.Value.Value) pick = entry;
        return pick is { } chosen ? Parse(chosen.Key) : null;
    }

    /// <summary>The final paragraph's anchor when the very end of the content is on
    /// screen — its top edge has entered the viewport — else null. Topmost-anchor
    /// sampling alone can never report the true end: fully scrolled down, the
    /// last paragraphs sit <i>below</i> the viewport top, so progress tops out a
    /// screenful short of 100% and a finished work never earns its badge.</summary>
    public static ReadingAnchor? EndOfContentAnchor(IReadOnlyDictionary<string, double> offsets,
                                                    int lastChapter, int lastParagraph, double viewportHeight)
    {
        if (lastParagraph < 0
            || !offsets.TryGetValue(Key(lastChapter, lastParagraph), out var top)
            || top > viewportHeight) return null;
        return new ReadingAnchor(lastChapter, lastParagraph);
    }

    /// <summary>The reader's end-of-work check: the final paragraph of the work's last
    /// chapter, once that chapter's anchors are being laid out (only then is its
    /// HTML converted — cached, but not free). Pass the same
    /// <paramref name="includeImages"/> the reader renders with, so the final
    /// paragraph's index matches the rendered one.</summary>
    public static ReadingAnchor? EndOfContentAnchor(IReadOnlyDictionary<string, double> offsets,
                                                    IReadOnlyList<AO3ChapterPayload> chapters,
                                                    double viewportHeight, bool includeImages = false)
    {
        if (chapters.Count == 0) return null;
        var last = chapters.MaxBy(c => c.Index)!;
        var prefix = $"c{last.Index}-p";
        if (!offsets.Keys.Any(k => k.StartsWith(prefix, StringComparison.Ordinal))) return null;
        var lastParagraph = HTMLToAttributed.ConvertParagraphs(last.BodyHtml, includeImages).Count - 1;
        return EndOfContentAnchor(offsets, last.Index, lastParagraph, viewportHeight);
    }

    /// <summary><paramref name="anchor"/> moved onto the chapters actually loaded
    /// (<paramref name="order"/>, their indices), or null when none are. A saved
    /// position can point past them: new-chapter notifications open the live work,
    /// so you can save a place in chapter 13 while the downloaded copy stops at 12.
    /// An anchor in a chapter that isn't loaded lands on the last paragraph of the
    /// nearest loaded chapter before it (the first chapter's top when there's none),
    /// so every mode has a chapter to show. <paramref name="lastParagraph"/> gives a
    /// loaded chapter's final paragraph index. (Swift:
    /// <c>ChapterTracking.clampedAnchor</c>.)</summary>
    public static ReadingAnchor? ClampedAnchor(ReadingAnchor anchor, IReadOnlyList<int> order,
                                               Func<int, int> lastParagraph)
    {
        if (order.Count == 0) return null;
        if (order.Contains(anchor.Chapter)) return anchor;
        var before = order.Where(c => c < anchor.Chapter).DefaultIfEmpty(int.MinValue).Max();
        if (before == int.MinValue) return new ReadingAnchor(order.Min(), 0);
        return new ReadingAnchor(before, Math.Max(lastParagraph(before), 0));
    }

    /// <summary>Parses <c>"c12-p3"</c>.</summary>
    public static ReadingAnchor? Parse(string key)
    {
        if (key.Length == 0) return null;
        var parts = key[1..].Split("-p", StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 2
            || !int.TryParse(parts[0], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var c)
            || !int.TryParse(parts[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var p))
            return null;
        return new ReadingAnchor(c, p);
    }

    public static string Key(int chapter, int paragraph) =>
        string.Create(CultureInfo.InvariantCulture, $"c{chapter}-p{paragraph}");

    /// <summary>Given each chapter's top offset (in viewport coordinates), the index of
    /// the chapter currently at the top of the viewport: the one with the greatest
    /// offset still at/above the threshold line just below the navigation bar.
    /// Index 0 is the title header and never counts.</summary>
    public static int? CurrentChapter(IReadOnlyDictionary<int, double> offsets, double threshold = DefaultThreshold)
    {
        KeyValuePair<int, double>? top = null;
        foreach (var entry in offsets)
            if (entry.Key >= 1 && entry.Value <= threshold && (top is null || entry.Value > top.Value.Value)) top = entry;
        if (top is { } passed) return passed.Key;
        // Nothing has scrolled past yet — we're in the first chapter.
        KeyValuePair<int, double>? first = null;
        foreach (var entry in offsets)
            if (entry.Key >= 1 && (first is null || entry.Value < first.Value.Value)) first = entry;
        return first?.Key;
    }

    /// <summary>The chapter index one step before/after <paramref name="current"/> within
    /// <paramref name="order"/> (the chapter indices in reading order), or null at the
    /// ends or when <paramref name="current"/> isn't found. Used by the reader's
    /// tap-to-turn page zones.</summary>
    public static int? AdjacentChapter(IReadOnlyList<int> order, int current, bool forward)
    {
        var pos = -1;
        for (var i = 0; i < order.Count; i++)
            if (order[i] == current) { pos = i; break; }
        if (pos < 0) return null;
        var target = forward ? pos + 1 : pos - 1;
        return target >= 0 && target < order.Count ? order[target] : null;
    }
}

/// <summary>Which rendered paragraphs report their offset (Swift:
/// <c>ChapterContentView.anchorStride</c> / <c>isAnchorIndex</c>).</summary>
public static class ChapterAnchors
{
    /// <summary>Position is sampled every N paragraphs — enough for "resume where you
    /// left off" without measuring every paragraph on every scroll frame.</summary>
    public const int AnchorStride = 6;

    /// <summary>Whether paragraph <paramref name="index"/> of <paramref name="count"/>
    /// reports its offset: every <see cref="AnchorStride"/>-th one, plus always the
    /// final paragraph. Without the final anchor the end of a chapter is invisible
    /// to progress tracking, so a work read to the last line could never reach 100%
    /// (see <see cref="ChapterTracking.EndOfContentAnchor(IReadOnlyDictionary{string, double}, int, int, double)"/>).</summary>
    public static bool IsAnchorIndex(int index, int count) => index % AnchorStride == 0 || index == count - 1;
}

/// <summary>What <see cref="ReaderAnchorSampler.OnOffsets"/> tells the reader to do.</summary>
public enum AnchorSampleAction
{
    /// <summary>Nothing (restoring a position, or no anchor laid out).</summary>
    None,
    /// <summary>The offsets came from a resize reflowing the text at another width,
    /// not from scrolling: ignored, so the re-anchor restores the pre-resize paragraph.</summary>
    IgnoredReflow,
    /// <summary>Take <see cref="AnchorSampleResult.Anchor"/> as the reading position now.</summary>
    Apply,
    /// <summary>Throttled: start a <see cref="ReaderAnchorSampler.TrailingDelay"/> timer
    /// and call <see cref="ReaderAnchorSampler.FireTrailing"/> with
    /// <see cref="AnchorSampleResult.TrailingToken"/> when it elapses.</summary>
    ScheduleTrailing,
}

public readonly record struct AnchorSampleResult(AnchorSampleAction Action, ReadingAnchor? Anchor = null,
                                                 int TrailingToken = 0);

/// <summary>The flowing reader modes' position sampling — the logic of Swift's
/// <c>onPreferenceChange(ScrollAnchorKey)</c> handlers and their
/// <c>TrailingAnchorSample</c> holder, with the timers left to the app.
///
/// <list type="bullet">
/// <item><b>Samples are resize-aware.</b> <see cref="Width"/> is the container width
/// the samples belong to; updates at another width are a resize reflowing the text,
/// not reading, and are ignored. Otherwise a reflow sample lands just before the
/// width-change handler and re-anchors to the wrong paragraph.</item>
/// <item><b>Reaching the very end always registers</b>, bypassing the throttle, so a
/// final flick to the bottom can't be dropped and progress can reach 100%.</item>
/// <item>Otherwise it samples at most ~3×/sec, and <b>a trailing sample</b> records
/// where scrolling settles: the throttle alone drops the last updates of a fling,
/// so the tracked anchor (and saved progress) could sit a whole fling behind.</item>
/// </list></summary>
public sealed class ReaderAnchorSampler
{
    /// <summary>Minimum time between throttled samples.</summary>
    public static readonly TimeSpan SampleInterval = TimeSpan.FromSeconds(0.35);

    /// <summary>How long updates must go quiet before the trailing sample is taken.</summary>
    public static readonly TimeSpan TrailingDelay = TimeSpan.FromMilliseconds(400);

    /// <summary>The latest offsets reported at <see cref="Width"/>.</summary>
    public IReadOnlyDictionary<string, double> Offsets { get; private set; } = new Dictionary<string, double>();

    /// <summary>The container width the samples belong to (0 = not seen yet).</summary>
    public double Width { get; private set; }

    public DateTimeOffset LastSampleAt { get; private set; } = DateTimeOffset.MinValue;

    /// <summary>Whether a trailing sample is scheduled and not yet fired or cancelled.</summary>
    public bool TrailingPending { get; private set; }

    private int _trailingToken;

    /// <summary>New paragraph offsets from the reader at container width
    /// <paramref name="containerWidth"/>. <paramref name="endOfContent"/> is the
    /// end-of-work check (e.g. <see cref="ChapterTracking.EndOfContentAnchor(IReadOnlyDictionary{string, double}, IReadOnlyList{AO3ChapterPayload}, double, bool)"/>).</summary>
    public AnchorSampleResult OnOffsets(IReadOnlyDictionary<string, double> offsets, double containerWidth,
                                        bool isRestoring, DateTimeOffset now,
                                        Func<IReadOnlyDictionary<string, double>, ReadingAnchor?>? endOfContent = null)
    {
        if (Width == 0) Width = containerWidth;
        if (Math.Abs(Width - containerWidth) > 1) return new(AnchorSampleAction.IgnoredReflow);
        Offsets = offsets;
        if (isRestoring) return new(AnchorSampleAction.None);
        if (endOfContent?.Invoke(offsets) is { } end)
        {
            LastSampleAt = now;
            return new(AnchorSampleAction.Apply, end);
        }
        if (now - LastSampleAt <= SampleInterval)
        {
            if (TrailingPending) return new(AnchorSampleAction.None);
            TrailingPending = true;
            return new(AnchorSampleAction.ScheduleTrailing, TrailingToken: ++_trailingToken);
        }
        LastSampleAt = now;
        return ChapterTracking.TopmostAnchor(offsets) is { } anchor
            ? new(AnchorSampleAction.Apply, anchor)
            : new(AnchorSampleAction.None);
    }

    /// <summary>The trailing timer elapsed: the anchor to apply where scrolling came
    /// to rest, or null (a stale or cancelled timer, restoring, nothing laid out).</summary>
    public ReadingAnchor? FireTrailing(int token, bool isRestoring, DateTimeOffset now)
    {
        if (!TrailingPending || token != _trailingToken) return null;
        TrailingPending = false;
        if (isRestoring || ChapterTracking.TopmostAnchor(Offsets) is not { } anchor) return null;
        LastSampleAt = now;
        return anchor;
    }

    /// <summary>A resize starts: samples resume at the new width, and a pending
    /// trailing sample (taken from the old layout) is dropped.</summary>
    public void BeginResize(double width)
    {
        Width = width;
        TrailingPending = false;
        _trailingToken++;
    }
}

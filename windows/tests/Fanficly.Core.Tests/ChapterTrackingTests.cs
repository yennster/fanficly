using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class ChapterTrackingTests
{
    [Fact]
    public void KeyRoundTrips()
    {
        var key = ChapterTracking.Key(12, 3);
        Assert.Equal("c12-p3", key);
        var parsed = ChapterTracking.Parse(key);
        Assert.Equal(12, parsed?.Chapter);
        Assert.Equal(3, parsed?.Paragraph);
    }

    [Fact]
    public void TopmostAnchorPicksGreatestPassedOffset()
    {
        // Paragraph offsets in scroll-content coords (decreasing as you scroll).
        var offsets = new Dictionary<string, double>
        {
            ["c1-p0"] = -400, // scrolled well past
            ["c1-p1"] = -120,
            ["c1-p2"] = 40,   // just above threshold (current top)
            ["c1-p3"] = 300,  // below the fold
        };
        var anchor = ChapterTracking.TopmostAnchor(offsets, threshold: 80);
        Assert.Equal(1, anchor?.Chapter);
        Assert.Equal(2, anchor?.Paragraph);
    }

    // MARK: - End-of-content detection (100% progress)

    [Fact]
    public void EndOfContentAnchorWhenFinalParagraphTopEntersViewport()
    {
        // Scrolled to the very bottom of a 60-paragraph one-shot: the final
        // paragraph's top edge is inside the 800pt viewport, even though the
        // *topmost* anchor is still a screenful earlier.
        var offsets = new Dictionary<string, double>
        {
            ["c1-p48"] = -200,
            ["c1-p54"] = 250,
            ["c1-p59"] = 620,
        };
        var end = ChapterTracking.EndOfContentAnchor(offsets, lastChapter: 1, lastParagraph: 59, viewportHeight: 800);
        Assert.Equal(new ReadingAnchor(1, 59), end);
        // The old topmost-anchor path alone would have stalled progress here.
        Assert.Equal(48, ChapterTracking.TopmostAnchor(offsets)?.Paragraph);
    }

    [Fact]
    public void EndOfContentAnchorNilWhileEndStillBelowViewport()
    {
        var offsets = new Dictionary<string, double>
        {
            ["c1-p54"] = 150,
            ["c1-p59"] = 1200, // laid out (lazy pre-render) but below the fold
        };
        Assert.Null(ChapterTracking.EndOfContentAnchor(offsets, lastChapter: 1, lastParagraph: 59, viewportHeight: 800));
    }

    [Fact]
    public void EndOfContentAnchorNilWhenFinalParagraphNotLaidOut()
    {
        var offsets = new Dictionary<string, double> { ["c1-p0"] = 0, ["c1-p6"] = 300 };
        Assert.Null(ChapterTracking.EndOfContentAnchor(offsets, lastChapter: 1, lastParagraph: 59, viewportHeight: 800));
    }

    [Fact]
    public void EndOfContentAnchorMatchesFinalChapterOnly()
    {
        // A mid-work chapter ending on screen isn't the end of the work.
        var offsets = new Dictionary<string, double> { ["c2-p59"] = 500 };
        Assert.Null(ChapterTracking.EndOfContentAnchor(offsets, lastChapter: 3, lastParagraph: 59, viewportHeight: 800));
    }

    // MARK: - Anchor stride

    [Fact]
    public void FinalParagraphAlwaysCarriesAnchor()
    {
        // Every 6th paragraph is anchored — plus always the final one, or a
        // fully-read chapter could never report its true end.
        Assert.True(ChapterAnchors.IsAnchorIndex(0, count: 60));
        Assert.True(ChapterAnchors.IsAnchorIndex(54, count: 60));
        Assert.False(ChapterAnchors.IsAnchorIndex(55, count: 60));
        Assert.True(ChapterAnchors.IsAnchorIndex(59, count: 60)); // final, off-stride
        Assert.True(ChapterAnchors.IsAnchorIndex(60, count: 61)); // final, on-stride
        Assert.True(ChapterAnchors.IsAnchorIndex(0, count: 1));
    }

    [Fact]
    public void CurrentChapterExcludesTitle()
    {
        var offsets = new Dictionary<int, double> { [0] = -500, [1] = -100, [2] = 200 };
        Assert.Equal(1, ChapterTracking.CurrentChapter(offsets));
    }

    // MARK: - AdjacentChapter (tap-to-turn page zones)

    [Fact]
    public void AdjacentChapterMovesForwardAndBack()
    {
        int[] order = [1, 2, 3, 4];
        Assert.Equal(3, ChapterTracking.AdjacentChapter(order, current: 2, forward: true));
        Assert.Equal(1, ChapterTracking.AdjacentChapter(order, current: 2, forward: false));
    }

    [Fact]
    public void AdjacentChapterClampsAtEnds()
    {
        int[] order = [1, 2, 3];
        Assert.Null(ChapterTracking.AdjacentChapter(order, current: 3, forward: true));
        Assert.Null(ChapterTracking.AdjacentChapter(order, current: 1, forward: false));
    }

    [Fact]
    public void AdjacentChapterFollowsReadingOrderNotIndexValue()
    {
        // Indices need not be contiguous or 1-based; navigation follows the
        // array order, stepping to the literal neighbour index.
        int[] order = [3, 7, 8, 15];
        Assert.Equal(8, ChapterTracking.AdjacentChapter(order, current: 7, forward: true));
        Assert.Equal(8, ChapterTracking.AdjacentChapter(order, current: 15, forward: false));
    }

    [Fact]
    public void AdjacentChapterUnknownCurrentReturnsNil()
    {
        Assert.Null(ChapterTracking.AdjacentChapter([1, 2, 3], current: 9, forward: true));
    }

    // MARK: - Windows port additions: the sampling rules from ReaderView

    [Fact]
    public void EndOfContentAnchorFromChaptersUsesTheRenderedLastParagraph()
    {
        AO3ChapterPayload[] chapters =
        [
            new(1, "", "<p>a</p>"),
            new(2, "", "<p>One.</p><img src=\"https://example.com/a.png\"><p>Two.</p>"),
        ];
        var offsets = new Dictionary<string, double> { ["c2-p2"] = 300 };
        // With images on, the final rendered paragraph is index 2.
        Assert.Equal(new ReadingAnchor(2, 2), ChapterTracking.EndOfContentAnchor(offsets, chapters, 800, includeImages: true));
        // Nothing from the last chapter laid out yet: no conversion, no anchor.
        Assert.Null(ChapterTracking.EndOfContentAnchor(new Dictionary<string, double> { ["c1-p0"] = 0 }, chapters, 800));
    }

    [Fact]
    public void SamplerIgnoresReflowAtAnotherWidth()
    {
        var sampler = new ReaderAnchorSampler();
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1000);
        var first = sampler.OnOffsets(new Dictionary<string, double> { ["c1-p6"] = 10 }, 400, false, t0);
        Assert.Equal(new AnchorSampleResult(AnchorSampleAction.Apply, new ReadingAnchor(1, 6)), first);
        // A resize reflows the text before the width-change handler runs.
        var reflow = sampler.OnOffsets(new Dictionary<string, double> { ["c1-p0"] = 10 }, 900, false, t0.AddSeconds(1));
        Assert.Equal(AnchorSampleAction.IgnoredReflow, reflow.Action);
        sampler.BeginResize(900);
        var after = sampler.OnOffsets(new Dictionary<string, double> { ["c1-p12"] = 10 }, 900, false, t0.AddSeconds(2));
        Assert.Equal(new ReadingAnchor(1, 12), after.Anchor);
    }

    [Fact]
    public void SamplerThrottlesThenTakesATrailingSample()
    {
        var sampler = new ReaderAnchorSampler();
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1000);
        sampler.OnOffsets(new Dictionary<string, double> { ["c1-p0"] = 0 }, 400, false, t0);
        var throttled = sampler.OnOffsets(new Dictionary<string, double> { ["c1-p6"] = 0 }, 400, false, t0.AddMilliseconds(100));
        Assert.Equal(AnchorSampleAction.ScheduleTrailing, throttled.Action);
        // Only one trailing sample at a time.
        Assert.Equal(AnchorSampleAction.None,
                     sampler.OnOffsets(new Dictionary<string, double> { ["c1-p12"] = 0 }, 400, false, t0.AddMilliseconds(200)).Action);
        // Where the fling came to rest is recorded.
        Assert.Equal(new ReadingAnchor(1, 12), sampler.FireTrailing(throttled.TrailingToken, false, t0.AddMilliseconds(600)));
        Assert.False(sampler.TrailingPending);
    }

    [Fact]
    public void SamplerDropsATrailingSampleAcrossAResize()
    {
        var sampler = new ReaderAnchorSampler();
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1000);
        sampler.OnOffsets(new Dictionary<string, double> { ["c1-p0"] = 0 }, 400, false, t0);
        var throttled = sampler.OnOffsets(new Dictionary<string, double> { ["c1-p6"] = 0 }, 400, false, t0.AddMilliseconds(100));
        sampler.BeginResize(800);
        Assert.Null(sampler.FireTrailing(throttled.TrailingToken, false, t0.AddMilliseconds(500)));
    }

    [Fact]
    public void SamplerRegistersTheEndBypassingTheThrottle()
    {
        var sampler = new ReaderAnchorSampler();
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1000);
        sampler.OnOffsets(new Dictionary<string, double> { ["c1-p0"] = 0 }, 400, false, t0);
        var end = sampler.OnOffsets(new Dictionary<string, double> { ["c1-p54"] = -300, ["c1-p59"] = 500 }, 400, false,
                                    t0.AddMilliseconds(50),
                                    o => ChapterTracking.EndOfContentAnchor(o, 1, 59, 800));
        Assert.Equal(new AnchorSampleResult(AnchorSampleAction.Apply, new ReadingAnchor(1, 59)), end);
        // Restoring never samples.
        Assert.Equal(AnchorSampleAction.None,
                     sampler.OnOffsets(new Dictionary<string, double> { ["c1-p0"] = 0 }, 400, true, t0.AddSeconds(5)).Action);
    }

    // A saved place past the downloaded chapters: new-chapter notifications open
    // the live work, so chapter 13 can be saved while the copy stops at 12.

    [Fact]
    public void ClampedAnchor_PastTheLastChapter_LandsOnItsLastParagraph() =>
        Assert.Equal(new ReadingAnchor(12, 9),
                     ChapterTracking.ClampedAnchor(new ReadingAnchor(13, 4), Enumerable.Range(1, 12).ToArray(), _ => 9));

    [Fact]
    public void ClampedAnchor_KeepsALoadedChapter() =>
        Assert.Equal(new ReadingAnchor(5, 3),
                     ChapterTracking.ClampedAnchor(new ReadingAnchor(5, 3), Enumerable.Range(1, 12).ToArray(), _ => 9));

    [Fact]
    public void ClampedAnchor_InAGapOrBeforeTheFirst()
    {
        Assert.Equal(new ReadingAnchor(2, 20), ChapterTracking.ClampedAnchor(new ReadingAnchor(3, 2), [1, 2, 4], c => c * 10));
        Assert.Equal(new ReadingAnchor(2, 0), ChapterTracking.ClampedAnchor(new ReadingAnchor(1, 2), [2, 3], _ => 9));
        Assert.Null(ChapterTracking.ClampedAnchor(new ReadingAnchor(1, 0), [], _ => 9));
    }
}

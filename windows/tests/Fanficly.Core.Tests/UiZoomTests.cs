using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The global UI zoom's step and clamp (Ctrl / Ctrl+Shift with Plus or
/// Minus, Ctrl+0), matching the Mac app's <c>UIZoomTests</c>.</summary>
public class UiZoomTests
{
    [Fact]
    public void StepsByATenthEachWay()
    {
        Assert.Equal(1.1, UiZoom.Stepped(1.0, forward: true));
        Assert.Equal(0.9, UiZoom.Stepped(1.0, forward: false));
    }

    [Fact]
    public void UpAtMax_StaysAtMax()
    {
        Assert.Equal(UiZoom.MaxScale, UiZoom.Stepped(UiZoom.MaxScale, forward: true));
        Assert.Equal(UiZoom.MaxScale, UiZoom.Stepped(1.95, forward: true));
    }

    [Fact]
    public void DownAtMin_StaysAtMin()
    {
        Assert.Equal(UiZoom.MinScale, UiZoom.Stepped(UiZoom.MinScale, forward: false));
        Assert.Equal(UiZoom.MinScale, UiZoom.Stepped(0.55, forward: false));
    }

    [Fact]
    public void ActualSize_IsOne() => Assert.Equal(1.0, UiZoom.ActualSize);

    [Fact]
    public void RepeatedSteps_DontDrift()
    {
        var scale = UiZoom.ActualSize;
        for (var i = 0; i < 5; i++) scale = UiZoom.Stepped(scale, forward: true);
        Assert.Equal(1.5, scale);
        for (var i = 0; i < 5; i++) scale = UiZoom.Stepped(scale, forward: false);
        Assert.Equal(1.0, scale);
        for (var i = 0; i < 20; i++) scale = UiZoom.Stepped(scale, forward: false);
        Assert.Equal(UiZoom.MinScale, scale);
        for (var i = 0; i < 20; i++) scale = UiZoom.Stepped(scale, forward: true);
        Assert.Equal(UiZoom.MaxScale, scale);
    }

    [Fact]
    public void OutOfRangeOrInvalidStoredValue_IsClamped()
    {
        Assert.Equal(UiZoom.MaxScale, UiZoom.Stepped(5.0, forward: true));
        Assert.Equal(UiZoom.MaxScale, UiZoom.Stepped(5.0, forward: false));
        Assert.Equal(UiZoom.MinScale, UiZoom.Stepped(0.0, forward: false));
        Assert.Equal(1.1, UiZoom.Stepped(double.NaN, forward: true));
        Assert.Equal(0.9, UiZoom.Stepped(double.PositiveInfinity, forward: false));

        Assert.Equal(UiZoom.MaxScale, UiZoom.Clamped(3.0));
        Assert.Equal(UiZoom.MinScale, UiZoom.Clamped(0.1));
        Assert.Equal(1.3, UiZoom.Clamped(1.3));
        Assert.Equal(UiZoom.ActualSize, UiZoom.Clamped(double.NaN));
    }
}

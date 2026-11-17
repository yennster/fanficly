using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The FlowPanel's layout: wrapping, and each item centered on its
/// line so Browse's filter row lines its icon up with the chips (#246).</summary>
public class FlowLinesTests
{
    private static (double, double) S(double w, double h) => (w, h);

    [Fact]
    public void ShortItemIsCenteredOnTheTallerChipsBesideIt()
    {
        // A 24 px chip, an 11 px icon, another 24 px chip.
        var p = FlowLines.Arrange([S(60, 24), S(11, 11), S(50, 24)], 400, 6, 6);
        Assert.Equal(new FlowPlacement(0, 0, 60, 24), p[0]);
        Assert.Equal(new FlowPlacement(66, 6.5, 11, 11), p[1]);
        Assert.Equal(new FlowPlacement(83, 0, 50, 24), p[2]);
        Assert.Equal(p[0].Y + p[0].Height / 2, p[1].Y + p[1].Height / 2);
    }

    [Fact]
    public void EachWrappedLineCentersOnItsOwnHeight()
    {
        // 70 wide: [60x24] then [11x11, 50x30] on the second line.
        var sizes = new[] { S(60, 24), S(11, 11), S(50, 30) };
        var p = FlowLines.Arrange(sizes, 70, 6, 6);
        Assert.Equal(new FlowPlacement(0, 0, 60, 24), p[0]);
        // Second line starts at 24 + 6 = 30 and is 30 tall.
        Assert.Equal(new FlowPlacement(0, 30 + 9.5, 11, 11), p[1]);
        Assert.Equal(new FlowPlacement(17, 30, 50, 30), p[2]);
        Assert.Equal((67, 60), FlowLines.Measure(sizes, 70, 6, 6));
    }

    [Fact]
    public void WrapsOnlyWhenTheNextItemWontFit()
    {
        // 60 + 6 + 34 = 100 fits exactly; one more pixel wraps.
        Assert.Equal(0, FlowLines.Arrange([S(60, 20), S(34, 20)], 100, 6, 4)[1].Y);
        var wrapped = FlowLines.Arrange([S(60, 20), S(35, 20)], 100, 6, 4);
        Assert.Equal(new FlowPlacement(0, 24, 35, 20), wrapped[1]);
    }

    [Fact]
    public void AnItemWiderThanThePanelGetsItsOwnLineCappedToTheWidth()
    {
        var sizes = new[] { S(30, 20), S(150, 20), S(30, 20) };
        var p = FlowLines.Arrange(sizes, 100, 6, 6);
        Assert.Equal(new FlowPlacement(0, 26, 100, 20), p[1]);
        Assert.Equal(new FlowPlacement(0, 52, 30, 20), p[2]);
        Assert.Equal((100, 72), FlowLines.Measure(sizes, 100, 6, 6));
    }

    [Fact]
    public void CollapsedItemsTakeNoRoom()
    {
        var sizes = new[] { S(0, 0), S(40, 20), S(0, 0), S(40, 20) };
        var p = FlowLines.Arrange(sizes, 400, 6, 6);
        Assert.Equal(default, p[0]);
        Assert.Equal(default, p[2]);
        Assert.Equal(46, p[3].X);
        Assert.Equal((86, 20), FlowLines.Measure(sizes, 400, 6, 6));
    }

    [Fact]
    public void UnboundedWidthIsOneLineAsWideAsItsItems()
    {
        var sizes = new[] { S(40, 20), S(40, 10) };
        Assert.Equal((86, 20), FlowLines.Measure(sizes, double.PositiveInfinity, 6, 6));
        Assert.Equal(0, FlowLines.Measure([], 100, 6, 6).Width);
    }
}

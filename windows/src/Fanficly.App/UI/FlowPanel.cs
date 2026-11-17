using Fanficly.Core;
using Windows.Foundation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.UI;

/// <summary>
/// Lays children out left to right and wraps to a new line when one won't fit
/// — the Mac app's FlowLayout (tag chips, filter chips, metadata rows). Each
/// child is centered vertically on its line (Core's <see cref="FlowLines"/>), so
/// an icon lines up with the chips beside it (#246).
/// </summary>
public sealed partial class FlowPanel : Panel
{
    public double Spacing { get; set; } = 6;
    public double LineSpacing { get; set; } = 6;

    protected override Size MeasureOverride(Size availableSize)
    {
        foreach (var child in Children)
            child.Measure(new Size(availableSize.Width, double.PositiveInfinity));
        var (width, height) = FlowLines.Measure(DesiredSizes(), availableSize.Width, Spacing, LineSpacing);
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var placements = FlowLines.Arrange(DesiredSizes(), finalSize.Width, Spacing, LineSpacing);
        for (var i = 0; i < Children.Count; i++)
        {
            var p = placements[i];
            Children[i].Arrange(new Rect(p.X, p.Y, p.Width, p.Height));
        }
        return finalSize;
    }

    private (double Width, double Height)[] DesiredSizes()
    {
        var sizes = new (double Width, double Height)[Children.Count];
        for (var i = 0; i < Children.Count; i++)
        {
            var size = Children[i].DesiredSize;
            sizes[i] = (size.Width, size.Height);
        }
        return sizes;
    }
}

using Windows.Foundation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.UI;

/// <summary>
/// Lays children out left to right and wraps to a new line when one won't fit
/// — the Mac app's FlowLayout (tag chips, filter chips, metadata rows).
/// </summary>
public sealed partial class FlowPanel : Panel
{
    public double Spacing { get; set; } = 6;
    public double LineSpacing { get; set; } = 6;

    protected override Size MeasureOverride(Size availableSize)
    {
        var maxWidth = availableSize.Width;
        double lineWidth = 0, lineHeight = 0, totalHeight = 0, widest = 0;
        var firstOnLine = true;
        foreach (var child in Children)
        {
            child.Measure(new Size(maxWidth, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (size.Width == 0 && size.Height == 0) continue;
            var needed = firstOnLine ? size.Width : lineWidth + Spacing + size.Width;
            if (!firstOnLine && needed > maxWidth)
            {
                totalHeight += lineHeight + LineSpacing;
                widest = Math.Max(widest, lineWidth);
                lineWidth = size.Width;
                lineHeight = size.Height;
            }
            else
            {
                lineWidth = needed;
                lineHeight = Math.Max(lineHeight, size.Height);
            }
            firstOnLine = false;
        }
        widest = Math.Max(widest, lineWidth);
        totalHeight += lineHeight;
        return new Size(double.IsInfinity(maxWidth) ? widest : Math.Min(widest, maxWidth), totalHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0, lineHeight = 0;
        var firstOnLine = true;
        foreach (var child in Children)
        {
            var size = child.DesiredSize;
            if (size.Width == 0 && size.Height == 0)
            {
                child.Arrange(new Rect(0, 0, 0, 0));
                continue;
            }
            if (!firstOnLine && x + Spacing + size.Width > finalSize.Width)
            {
                x = 0;
                y += lineHeight + LineSpacing;
                lineHeight = 0;
                firstOnLine = true;
            }
            if (!firstOnLine) x += Spacing;
            child.Arrange(new Rect(x, y, Math.Min(size.Width, finalSize.Width), size.Height));
            x += size.Width;
            lineHeight = Math.Max(lineHeight, size.Height);
            firstOnLine = false;
        }
        return finalSize;
    }
}

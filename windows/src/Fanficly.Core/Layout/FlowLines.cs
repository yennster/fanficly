namespace Fanficly.Core;

/// <summary>Where one item of a flow row goes: its top-left corner, and the
/// size it was measured at.</summary>
public readonly record struct FlowPlacement(double X, double Y, double Width, double Height);

/// <summary>
/// The pure layout behind the app's <c>FlowPanel</c> (the Mac's FlowLayout):
/// items go left to right and wrap to a new line when one won't fit. Each item
/// is centered vertically on its line, the way a SwiftUI <c>HStack</c> centers
/// its children, so a short item (an icon, a small label) lines up with the
/// taller chips beside it instead of sitting at the top of the line (#246).
/// An item can ask for the top of its line instead (<c>alignTop</c>), as the
/// series row's links do, matching the Mac's top-aligned FlowLayout there.
/// Empty items (0×0, collapsed) take no room and get a 0×0 placement at the origin.
/// </summary>
public static class FlowLines
{
    /// <summary>The panel's size for <paramref name="sizes"/> laid out in
    /// <paramref name="maxWidth"/> (which may be infinite).</summary>
    public static (double Width, double Height) Measure(
        IReadOnlyList<(double Width, double Height)> sizes, double maxWidth, double spacing, double lineSpacing)
    {
        var lines = Lines(sizes, maxWidth, spacing);
        if (lines.Count == 0) return (0, 0);
        var widest = lines.Max(l => l.Width);
        var height = lines.Sum(l => l.Height) + lineSpacing * (lines.Count - 1);
        return (double.IsInfinity(maxWidth) ? widest : Math.Min(widest, maxWidth), height);
    }

    /// <summary>Where each of <paramref name="sizes"/> goes in a panel
    /// <paramref name="width"/> wide, in the same order. Items for which
    /// <paramref name="alignTop"/> is true sit at the top of their line.</summary>
    public static FlowPlacement[] Arrange(
        IReadOnlyList<(double Width, double Height)> sizes, double width, double spacing, double lineSpacing,
        Func<int, bool>? alignTop = null)
    {
        var placements = new FlowPlacement[sizes.Count];
        double y = 0;
        foreach (var line in Lines(sizes, width, spacing))
        {
            double x = 0;
            var first = true;
            foreach (var i in line.Items)
            {
                var (w, h) = sizes[i];
                if (!first) x += spacing;
                var top = alignTop?.Invoke(i) == true ? y : y + (line.Height - h) / 2;
                placements[i] = new FlowPlacement(x, top, Math.Min(w, width), h);
                x += w;
                first = false;
            }
            y += line.Height + lineSpacing;
        }
        return placements;
    }

    private sealed record Line(List<int> Items, double Width, double Height);

    private static List<Line> Lines(IReadOnlyList<(double Width, double Height)> sizes, double maxWidth, double spacing)
    {
        var lines = new List<Line>();
        List<int>? items = null;
        double lineWidth = 0, lineHeight = 0;
        for (var i = 0; i < sizes.Count; i++)
        {
            var (w, h) = sizes[i];
            if (w == 0 && h == 0) continue;
            if (items is not null && lineWidth + spacing + w > maxWidth)
            {
                lines.Add(new Line(items, lineWidth, lineHeight));
                items = null;
            }
            if (items is null)
            {
                items = [i];
                lineWidth = w;
                lineHeight = h;
            }
            else
            {
                items.Add(i);
                lineWidth += spacing + w;
                lineHeight = Math.Max(lineHeight, h);
            }
        }
        if (items is not null) lines.Add(new Line(items, lineWidth, lineHeight));
        return lines;
    }
}

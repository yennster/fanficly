using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// Page-by-page's text measurement on WinUI (Swift: <c>boundingRect</c> for the
/// estimate, ReaderPageCell's <c>pageContent</c> in a hosting controller for the
/// drawn check). Both measure real XAML text elements built by
/// <see cref="ReaderText"/>, parented in an invisible host inside the reader so
/// they lay out at the window's scale and text-size setting, exactly like the
/// page on screen. UI thread only.
/// </summary>
internal sealed class ReaderTextMeasurer : IReaderTextMeasurer
{
    private const int MaxCacheEntries = 40_000;

    private readonly TextBlock _probe = new();
    private readonly TextBlock _lineProbe = new() { Text = "Ag" };
    private readonly Dictionary<(ReaderRichText Text, double Width, ReaderTypography Typography), double> _heights = [];
    private readonly Dictionary<(ReaderFontFamily Family, double Size), double> _lineHeights = [];

    /// <summary>Put this in the reader's tree; it takes no room and draws nothing.</summary>
    public MeasureHostPanel Host { get; } = new();

    public ReaderTextMeasurer()
    {
        Host.Children.Add(_probe);
        Host.Children.Add(_lineProbe);
    }

    /// <summary>The XAML values a typography lays text out with.</summary>
    public ReaderTextStyle StyleFor(ReaderTypography typography)
    {
        var natural = LineHeight(typography.Family, typography.FontSize);
        var spacing = typography.FontSize > 0 ? (int)Math.Round(typography.Kerning / typography.FontSize * 1000) : 0;
        return new ReaderTextStyle(typography, ReaderText.Font(typography.Family), natural + Math.Max(0, typography.LineSpacing), spacing);
    }

    public double MeasureHeight(ReaderRichText text, double width, ReaderTypography typography)
    {
        var key = (text, width, typography);
        if (_heights.TryGetValue(key, out var cached)) return cached;
        if (_heights.Count > MaxCacheEntries) _heights.Clear();
        ReaderText.Apply(_probe, StyleFor(typography));
        ReaderText.Fill(_probe.Inlines, text);
        _probe.Measure(new Size(Math.Max(1, width), double.PositiveInfinity));
        var height = _probe.DesiredSize.Height;
        _probe.Inlines.Clear();
        _heights[key] = height;
        return height;
    }

    public double LineHeight(ReaderFontFamily family, double fontSize)
    {
        var key = (family, fontSize);
        if (_lineHeights.TryGetValue(key, out var cached)) return cached;
        _lineProbe.FontFamily = ReaderText.Font(family);
        _lineProbe.FontSize = fontSize;
        _lineProbe.LineStackingStrategy = LineStackingStrategy.MaxHeight;
        _lineProbe.LineHeight = 0;
        _lineProbe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var height = _lineProbe.DesiredSize.Height;
        if (height <= 0) height = Math.Ceiling(fontSize * 1.33);
        _lineHeights[key] = height;
        return height;
    }

    public double MeasureDrawnPage(IReadOnlyList<ReaderRichText> blocks, double width, ReaderTypography typography)
    {
        var column = ReaderText.Column(blocks, StyleFor(typography), foreground: null, loadImages: false);
        Host.Children.Add(column);
        try
        {
            column.Measure(new Size(Math.Max(1, width), double.PositiveInfinity));
            return column.DesiredSize.Height;
        }
        finally
        {
            Host.Children.Remove(column);
        }
    }

    /// <summary>Forget measured heights (the window moved to a screen with another
    /// scale, or the system text size changed).</summary>
    public void ClearCache()
    {
        _heights.Clear();
        _lineHeights.Clear();
    }
}

/// <summary>An invisible panel that keeps measuring elements in the visual tree
/// (so they lay out at the window's scale) while taking no room.</summary>
internal sealed partial class MeasureHostPanel : Panel
{
    public MeasureHostPanel()
    {
        Opacity = 0;
        IsHitTestVisible = false;
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Top;
        AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
    }

    protected override Size MeasureOverride(Size availableSize) => new(0, 0);

    protected override Size ArrangeOverride(Size finalSize)
    {
        foreach (var child in Children) child.Arrange(new Rect(0, 0, 0, 0));
        return new Size(0, 0);
    }
}

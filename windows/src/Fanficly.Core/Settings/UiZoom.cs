namespace Fanficly.Core;

/// <summary>
/// The global UI zoom (<c>app.zoomScale</c>): Ctrl / Ctrl+Shift with Plus or
/// Minus step it, Ctrl+0 resets it. The Mac app's <c>UIZoom</c> (⌘ / ⇧⌘ +/−,
/// ⌘0). Values snap to tenths so repeated steps can't drift.
/// </summary>
public static class UiZoom
{
    public const double Step = 0.1;
    public const double MinScale = 0.5;
    public const double MaxScale = 2.0;
    public const double ActualSize = 1.0;

    /// <summary>One step bigger (<paramref name="forward"/>) or smaller, clamped to
    /// <see cref="MinScale"/>…<see cref="MaxScale"/>. A stored value outside the
    /// range (or not a number) comes back inside it.</summary>
    public static double Stepped(double scale, bool forward)
    {
        var current = double.IsFinite(scale) ? scale : ActualSize;
        var next = Math.Round((current + (forward ? Step : -Step)) * 10, MidpointRounding.AwayFromZero) / 10;
        return Math.Clamp(next, MinScale, MaxScale);
    }

    /// <summary>A stored zoom read back at launch: inside the range, 1.0 if it isn't a number.</summary>
    public static double Clamped(double scale) =>
        double.IsFinite(scale) ? Math.Clamp(scale, MinScale, MaxScale) : ActualSize;
}

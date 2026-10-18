using System.Globalization;

namespace Fanficly.Core;

/// <summary>A width × height in DIPs (Swift <c>CGSize</c>).</summary>
public readonly record struct ReaderSize(double Width, double Height);

/// <summary>A rectangle in DIPs (Swift <c>CGRect</c>).</summary>
public readonly record struct ReaderRect(double X, double Y, double Width, double Height)
{
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;
}

/// <summary>An sRGB color the app turns into a brush.</summary>
public readonly record struct ReaderColor(byte A, byte R, byte G, byte B)
{
    /// <summary>From 0…1 components, as SwiftUI's <c>Color(red:green:blue:)</c>.</summary>
    public static ReaderColor FromRgb(double r, double g, double b) => new(255, To8(r), To8(g), To8(b));

    private static byte To8(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255, MidpointRounding.AwayFromZero);

    public static readonly ReaderColor White = new(255, 255, 255, 255);
    public static readonly ReaderColor Black = new(255, 0, 0, 0);

    /// <summary>0xAARRGGBB.</summary>
    public uint Argb => (uint)A << 24 | (uint)R << 16 | (uint)G << 8 | B;

    /// <summary><c>#RRGGBB</c>, or <c>#AARRGGBB</c> when not opaque.</summary>
    public string Hex => A == 255
        ? string.Create(CultureInfo.InvariantCulture, $"#{R:X2}{G:X2}{B:X2}")
        : string.Create(CultureInfo.InvariantCulture, $"#{A:X2}{R:X2}{G:X2}{B:X2}");

    public override string ToString() => Hex;
}

public enum ReaderColorScheme { Light, Dark }

/// <summary>Reader color themes. Raw values (<see cref="ReaderThemeExtensions.RawValue"/>)
/// are what settings and profiles store, shared with the Apple apps.</summary>
public enum ReaderTheme { System, Light, Sepia, Dark, OledBlack, Dracula }

public static class ReaderThemeExtensions
{
    public static IReadOnlyList<ReaderTheme> AllCases { get; } =
        [ReaderTheme.System, ReaderTheme.Light, ReaderTheme.Sepia, ReaderTheme.Dark, ReaderTheme.OledBlack, ReaderTheme.Dracula];

    public static string RawValue(this ReaderTheme theme) => theme switch
    {
        ReaderTheme.System => "system",
        ReaderTheme.Light => "light",
        ReaderTheme.Sepia => "sepia",
        ReaderTheme.Dark => "dark",
        ReaderTheme.OledBlack => "oledBlack",
        ReaderTheme.Dracula => "dracula",
        _ => throw new ArgumentOutOfRangeException(nameof(theme)),
    };

    /// <summary>The theme for a stored raw value, or null when unknown (callers fall back to System).</summary>
    public static ReaderTheme? FromRawValue(string? raw) => AllCases.Cast<ReaderTheme?>().FirstOrDefault(t => t!.Value.RawValue() == raw);

    public static string DisplayName(this ReaderTheme theme) => theme switch
    {
        ReaderTheme.System => "Match System",
        ReaderTheme.Light => "Light",
        ReaderTheme.Sepia => "Sepia",
        ReaderTheme.Dark => "Dark",
        ReaderTheme.OledBlack => "OLED Black",
        ReaderTheme.Dracula => "Dracula Navy",
        _ => throw new ArgumentOutOfRangeException(nameof(theme)),
    };

    /// <summary>The page background. <c>System</c> follows the app's light/dark
    /// scheme (Apple's <c>systemBackground</c>: white / black).</summary>
    public static ReaderColor Background(this ReaderTheme theme, ReaderColorScheme scheme) => theme switch
    {
        ReaderTheme.System => scheme == ReaderColorScheme.Dark ? ReaderColor.Black : ReaderColor.White,
        ReaderTheme.Light => ReaderColor.FromRgb(0.99, 0.99, 0.97),
        ReaderTheme.Sepia => ReaderColor.FromRgb(0.97, 0.93, 0.85),
        ReaderTheme.Dark => ReaderColor.FromRgb(0.12, 0.12, 0.13),
        ReaderTheme.OledBlack => ReaderColor.Black,
        ReaderTheme.Dracula => ReaderColor.FromRgb(0.157, 0.165, 0.212),
        _ => throw new ArgumentOutOfRangeException(nameof(theme)),
    };

    /// <summary>The text color. <c>System</c> follows the app's scheme (Apple's
    /// <c>label</c>: black / white).</summary>
    public static ReaderColor Foreground(this ReaderTheme theme, ReaderColorScheme scheme) => theme switch
    {
        ReaderTheme.System => scheme == ReaderColorScheme.Dark ? ReaderColor.White : ReaderColor.Black,
        ReaderTheme.Light => ReaderColor.FromRgb(0.08, 0.08, 0.10),
        ReaderTheme.Sepia => ReaderColor.FromRgb(0.30, 0.20, 0.10),
        ReaderTheme.Dark => ReaderColor.FromRgb(0.92, 0.92, 0.90),
        ReaderTheme.OledBlack => ReaderColor.FromRgb(0.88, 0.88, 0.85),
        ReaderTheme.Dracula => ReaderColor.FromRgb(0.973, 0.973, 0.949),
        _ => throw new ArgumentOutOfRangeException(nameof(theme)),
    };

    /// <summary>The scheme the reader's own bars take (never the whole window — see
    /// CLAUDE.md: a window-wide scheme flipped the app light↔dark when leaving a
    /// light reader). Null for <c>System</c>.</summary>
    public static ReaderColorScheme? PreferredColorScheme(this ReaderTheme theme) => theme switch
    {
        ReaderTheme.System => null,
        ReaderTheme.Light or ReaderTheme.Sepia => ReaderColorScheme.Light,
        _ => ReaderColorScheme.Dark,
    };
}

/// <summary>Numeric reader metrics adjusted by sliders in Settings. Stored as raw
/// point (DIP) values so they can vary continuously.</summary>
public static class ReaderMetrics
{
    /// <summary>The reading column: <paramref name="widthPercent"/> of the container,
    /// capped at <see cref="MaxLineLengthEm"/> (~80 characters) when
    /// <paramref name="limitLineLength"/>. The phone profile sets it: its width was
    /// tuned on a ~400pt screen, and the same percentage stretches lines unreadably
    /// across a wide phone layout. Whole points: the platform lays text out in a
    /// pixel-snapped frame while page-by-page measures it at the width given, and
    /// at a fractional width the two broke lines differently when a word only just
    /// fit, so pages were cut a line early.</summary>
    public static double TextColumnWidth(double containerWidth, double widthPercent, double fontSize, bool limitLineLength)
    {
        var column = containerWidth * (widthPercent / 100.0);
        if (!limitLineLength) return Math.Floor(column);
        return Math.Floor(Math.Min(column, fontSize * MaxLineLengthEm));
    }

    public const double MaxLineLengthEm = 40;

    public const double DefaultFontSize = 18;
    public static readonly (double Min, double Max) FontSizeRange = (12, 30);

    public const double DefaultLineSpacing = 6;
    public static readonly (double Min, double Max) LineSpacingRange = (0, 20);

    public const double DefaultParagraphSpacing = 16;
    public static readonly (double Min, double Max) ParagraphSpacingRange = (2, 80);

    public const double DefaultKerning = 0.0;
    public static readonly (double Min, double Max) KerningRange = (-0.5, 3.0);

    // Named presets for the reader's quick (Aa) menu. Settings exposes the same
    // values as continuous sliders.
    public static readonly IReadOnlyList<(string Name, double Value)> FontSizePresets =
    [
        ("Extra Small", 13), ("Small", 15), ("Medium", 18),
        ("Large", 20), ("Extra Large", 23), ("Huge", 27),
    ];
    public static readonly IReadOnlyList<(string Name, double Value)> LineSpacingPresets =
    [
        ("Tight", 2), ("Normal", 6), ("Relaxed", 11), ("Loose", 16),
    ];
    public static readonly IReadOnlyList<(string Name, double Value)> ParagraphSpacingPresets =
    [
        ("Compact", 8), ("Normal", 16), ("Roomy", 26),
        ("Airy", 38), ("Spacious", 56), ("Expansive", 72),
    ];
    public static readonly IReadOnlyList<(string Name, double Value)> KerningPresets =
    [
        ("Tight", -0.2), ("Standard", 0.0), ("Medium", 0.5), ("Wide", 1.2), ("Extra Wide", 2.2),
    ];

    /// <summary>One-page margin presets (the Aa menu's "Margins").</summary>
    public static readonly IReadOnlyList<(string Name, double Value)> WidthPresets =
    [
        ("Narrow (50%)", 50.0), ("Medium (70%)", 70.0), ("Wide (85%)", 85.0), ("Full (100%)", 100.0),
    ];

    /// <summary>The preset a quick menu marks: only the single nearest one, and only
    /// when the value sits essentially on it — so closely-spaced presets never light
    /// up two checkmarks, and slider-tuned values read as "Custom" (null).</summary>
    public static string? CurrentPresetName(IReadOnlyList<(string Name, double Value)> presets, double value)
    {
        if (presets.Count == 0) return null;
        var nearest = presets.MinBy(p => Math.Abs(p.Value - value));
        return Math.Abs(nearest.Value - value) < 0.05 ? nearest.Name : null;
    }
}

/// <summary>Page-by-page's two-page spread: on a wide window (a landscape tablet,
/// a desktop window, a foldable unfolded) pages pair up side by side like an open
/// book, with the gutter on a fold when there is one. Pure, so it's unit-tested.</summary>
public static class ReaderSpread
{
    /// <summary>Narrower windows keep one page: two columns of ~300 pt read cramped.</summary>
    public const double MinimumWidth = 700;
    public const double MinimumAspect = 1.15;
    /// <summary>The gutter between pages, also used around a fold thinner than this.</summary>
    public const double MinimumGutter = 56;
    /// <summary>Two-page mode has its own text-width setting (<c>reader.spreadWidthPercent</c>):
    /// each page is half the window, where the one-page setting (70% by default)
    /// would leave wide empty margins on every page.</summary>
    public const double DefaultWidthPercent = 88;
    public static readonly (double Min, double Max) WidthPercentRange = (60, 100);
    public static readonly IReadOnlyList<(string Name, double Value)> WidthPresets =
    [
        ("Narrow (70%)", 70), ("Medium (80%)", 80), ("Wide (88%)", 88), ("Full (100%)", 100),
    ];

    /// <param name="PageWidth">Both pages share this width, so they paginate identically.</param>
    /// <param name="LeftX">Leading x of the left page; the right page starts at <paramref name="GutterEnd"/>.</param>
    public sealed record Layout(double PageWidth, double LeftX, double GutterStart, double GutterEnd);

    /// <summary>The spread for a container, or null when it's too narrow for two pages.
    /// <paramref name="fold"/> is a hardware fold / display division (in the
    /// container's space); a vertical one near the middle becomes the gutter,
    /// otherwise the gutter is centered.</summary>
    public static Layout? LayoutFor(ReaderSize containerSize, ReaderRect? fold)
    {
        var w = containerSize.Width;
        if (w < MinimumWidth || w < containerSize.Height * MinimumAspect) return null;
        var center = w / 2;
        var gutterWidth = MinimumGutter;
        if (fold is { } f && f.Height > f.Width && f.MidX > w * 0.3 && f.MidX < w * 0.7)
        {
            center = f.MidX;
            gutterWidth = Math.Max(f.Width, MinimumGutter);
        }
        var gutterStart = center - gutterWidth / 2;
        var gutterEnd = center + gutterWidth / 2;
        var pageWidth = Math.Floor(Math.Min(gutterStart, w - gutterEnd));
        if (pageWidth < 280) return null;
        return new Layout(pageWidth, gutterStart - pageWidth, gutterStart, gutterEnd);
    }

    public sealed record Spread(ChapterPage Left, ChapterPage? Right)
    {
        public string Id => Left.Id;
        public bool Contains(string pageId) => Left.Id == pageId || Right?.Id == pageId;
    }

    /// <summary>Pairs pages two by two within each chapter, so every chapter opens on
    /// a fresh spread (and the pairing doesn't shift as neighboring chapters load);
    /// a chapter with an odd page count ends on a lone left page. A page marked
    /// <see cref="ChapterPage.StartsSpread"/> opens a spread too: one a re-pagination
    /// kept in place that pairing would put on the right, so the spread on screen
    /// doesn't swap sides. The page before it then stands alone.</summary>
    public static IReadOnlyList<Spread> Spreads(IReadOnlyList<ChapterPage> pages)
    {
        var result = new List<Spread>();
        var i = 0;
        while (i < pages.Count)
        {
            var left = pages[i];
            var next = i + 1 < pages.Count ? pages[i + 1] : null;
            if (next is not null && next.ChapterIndex == left.ChapterIndex && !next.StartsSpread)
            {
                result.Add(new Spread(left, next));
                i += 2;
            }
            else
            {
                result.Add(new Spread(left, null));
                i += 1;
            }
        }
        return result;
    }
}

/// <summary>The height page-by-page measures its pages for: the page area on screen,
/// with the reader controls (nav bar, page footer, narration bar) showing or not,
/// so pages always fill it. Re-paginating keeps the page on screen in place (see
/// <see cref="PageStart"/>): showing or hiding the controls takes lines off the
/// foot of the page or adds them there.
///
/// Pages shrink as soon as the area does, so text never runs under the controls,
/// but grow only once it has held still (<see cref="Settle"/>): the area is briefly
/// smaller now and then (a navigation transition, a keyboard inset), and growing at
/// every in-between size would re-paginate for nothing. The app settles after the
/// area holds for 0.3 s, or 50 ms when the controls hide. Pure, so it's unit-tested.</summary>
public sealed class PageAreaTracker
{
    /// <summary>The height pages are measured for (0 = nothing seen yet).</summary>
    public double PageHeight { get; private set; }

    /// <summary>The page area with the controls up at this window size (0 = not seen
    /// yet). One page or two is decided on it: full screen's extra height makes the
    /// area squarer, and a landscape tablet beside the sidebar switched the two-page
    /// spread to one page when the controls hid.</summary>
    public double ControlsUpHeight { get; private set; }

    /// <summary>The height to decide one page or two on (see <see cref="ControlsUpHeight"/>).</summary>
    public double SpreadDecisionHeight => ControlsUpHeight > 0 ? ControlsUpHeight : PageHeight;

    /// <summary>A new window size (a resize, a snap layout change): start over from the area on screen.</summary>
    public void Reset(double area, bool controlsUp)
    {
        PageHeight = area;
        ControlsUpHeight = controlsUp ? area : 0;
    }

    /// <summary>The page area changed: shrink at once, so text never runs under the controls.</summary>
    public void Observe(double area, bool controlsUp)
    {
        if (controlsUp) ControlsUpHeight = area;
        if (area < PageHeight - 1) PageHeight = area;
    }

    /// <summary>The page area has held still at <paramref name="area"/>: grow to fill it.</summary>
    public void Settle(double area)
    {
        if (area > PageHeight + 1) PageHeight = area;
    }
}

/// <summary>Reader fonts. The raw values are the Swift ids (stored in settings and
/// profiles, shared with the Apple apps); each maps to the closest font Windows
/// ships (<see cref="ReaderFontFamilyExtensions.WindowsFontFamily"/>).</summary>
public enum ReaderFontFamily { NewYork, Serif, Sans, Rounded, Mono }

public static class ReaderFontFamilyExtensions
{
    public static IReadOnlyList<ReaderFontFamily> AllCases { get; } =
        [ReaderFontFamily.NewYork, ReaderFontFamily.Serif, ReaderFontFamily.Sans, ReaderFontFamily.Rounded, ReaderFontFamily.Mono];

    public static string RawValue(this ReaderFontFamily family) => family switch
    {
        ReaderFontFamily.NewYork => "newYork",
        ReaderFontFamily.Serif => "serif",
        ReaderFontFamily.Sans => "sans",
        ReaderFontFamily.Rounded => "rounded",
        ReaderFontFamily.Mono => "mono",
        _ => throw new ArgumentOutOfRangeException(nameof(family)),
    };

    /// <summary>The family for a stored raw value, or null when unknown (callers fall back to New York).</summary>
    public static ReaderFontFamily? FromRawValue(string? raw) =>
        AllCases.Cast<ReaderFontFamily?>().FirstOrDefault(f => f!.Value.RawValue() == raw);

    /// <summary>The name shown in menus (the Apple names, so profiles read the same everywhere).</summary>
    public static string DisplayName(this ReaderFontFamily family) => family switch
    {
        ReaderFontFamily.NewYork => "New York",
        ReaderFontFamily.Serif => "System Serif",
        ReaderFontFamily.Sans => "System Sans",
        ReaderFontFamily.Rounded => "Rounded",
        ReaderFontFamily.Mono => "Monospaced",
        _ => throw new ArgumentOutOfRangeException(nameof(family)),
    };

    /// <summary>The Windows font that stands in for the Apple one, as a XAML
    /// <c>FontFamily</c> string with fallbacks:
    /// New York (Apple's book serif) → Sitka Text (Windows' reading serif);
    /// System Serif → Georgia, then Cambria;
    /// System Sans (SF Pro) → Segoe UI Variable Text, then Segoe UI;
    /// Rounded (SF Rounded) → Windows ships no rounded sans, so Arial Rounded MT Bold
    /// when Office installed it, else Segoe UI Variable Text;
    /// Monospaced (SF Mono) → Cascadia Mono, then Consolas.</summary>
    public static string WindowsFontFamily(this ReaderFontFamily family) => family switch
    {
        ReaderFontFamily.NewYork => "Sitka Text, Georgia",
        ReaderFontFamily.Serif => "Georgia, Cambria",
        ReaderFontFamily.Sans => "Segoe UI Variable Text, Segoe UI",
        ReaderFontFamily.Rounded => "Arial Rounded MT Bold, Segoe UI Variable Text, Segoe UI",
        ReaderFontFamily.Mono => "Cascadia Mono, Consolas",
        _ => throw new ArgumentOutOfRangeException(nameof(family)),
    };
}

/// <summary>The legacy named column widths (profiles still carry <c>widthRaw</c>).</summary>
public enum ReaderWidth { Narrow, Medium, Wide, Full }

public static class ReaderWidthExtensions
{
    public static IReadOnlyList<ReaderWidth> AllCases { get; } =
        [ReaderWidth.Narrow, ReaderWidth.Medium, ReaderWidth.Wide, ReaderWidth.Full];

    public static string RawValue(this ReaderWidth width) => width switch
    {
        ReaderWidth.Narrow => "narrow",
        ReaderWidth.Medium => "medium",
        ReaderWidth.Wide => "wide",
        ReaderWidth.Full => "full",
        _ => throw new ArgumentOutOfRangeException(nameof(width)),
    };

    public static ReaderWidth? FromRawValue(string? raw) =>
        AllCases.Cast<ReaderWidth?>().FirstOrDefault(w => w!.Value.RawValue() == raw);

    public static string DisplayName(this ReaderWidth width) => width switch
    {
        ReaderWidth.Narrow => "Narrow",
        ReaderWidth.Medium => "Medium",
        ReaderWidth.Wide => "Wide",
        ReaderWidth.Full => "Full",
        _ => throw new ArgumentOutOfRangeException(nameof(width)),
    };

    /// <summary>Horizontal padding around the text column, so the text actually
    /// narrows on any device.</summary>
    public static double HorizontalPadding(this ReaderWidth width) => width switch
    {
        ReaderWidth.Narrow => 44,
        ReaderWidth.Medium => 24,
        ReaderWidth.Wide => 12,
        ReaderWidth.Full => 2,
        _ => throw new ArgumentOutOfRangeException(nameof(width)),
    };

    /// <summary>Maximum text-column width on large screens; null for <c>Full</c>
    /// (edge to edge).</summary>
    public static double? MaxColumnWidth(this ReaderWidth width) => width switch
    {
        ReaderWidth.Narrow => 540,
        ReaderWidth.Medium => 720,
        ReaderWidth.Wide => 900,
        ReaderWidth.Full => null,
        _ => throw new ArgumentOutOfRangeException(nameof(width)),
    };
}

public enum ReadingMode { Continuous, Paginated, PageByPage }

public static class ReadingModeExtensions
{
    public static IReadOnlyList<ReadingMode> AllCases { get; } =
        [ReadingMode.Continuous, ReadingMode.Paginated, ReadingMode.PageByPage];

    public static string RawValue(this ReadingMode mode) => mode switch
    {
        ReadingMode.Continuous => "continuous",
        ReadingMode.Paginated => "paginated",
        ReadingMode.PageByPage => "pageByPage",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    public static ReadingMode? FromRawValue(string? raw) =>
        AllCases.Cast<ReadingMode?>().FirstOrDefault(m => m!.Value.RawValue() == raw);

    public static string DisplayName(this ReadingMode mode) => mode switch
    {
        ReadingMode.Continuous => "Continuous scroll",
        ReadingMode.Paginated => "Swipe by chapter",
        ReadingMode.PageByPage => "Page-by-page",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    /// <summary>SF Symbol name (the app maps it to a Fluent glyph).</summary>
    public static string Symbol(this ReadingMode mode) => mode switch
    {
        ReadingMode.Continuous => "arrow.down",
        ReadingMode.Paginated => "rectangle.split.3x1",
        ReadingMode.PageByPage => "book.closed",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };
}

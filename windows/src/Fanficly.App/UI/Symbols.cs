using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Fanficly.App.UI;

/// <summary>
/// The Swift app names its icons with SF Symbols; Core keeps those names as
/// plain icon ids. This maps each one to its closest Segoe Fluent Icons glyph
/// (Windows 11's icon font; Windows 10 falls back to Segoe MDL2 Assets, which
/// shares these code points), so every screen draws the same icon in the same
/// place as on the Mac — in Windows' own style.
/// </summary>
public static class Symbols
{
    /// <summary>Created on first use: feature modules register icons from
    /// module initializers, which run before the XAML runtime is up.</summary>
    public static FontFamily Font => _font ??= new FontFamily("Segoe Fluent Icons,Segoe MDL2 Assets");
    private static FontFamily? _font;

    private static readonly Dictionary<string, string> Map = new()
    {
        // Sidebar
        ["magnifyingglass"] = "",      // Search
        ["rectangle.stack"] = "",      // ViewAll
        ["flame"] = "",                // LightningBolt (closest to "trending")
        ["books.vertical"] = "",       // Library
        ["chart.bar.xaxis"] = "",      // AreaChart
        ["clock.arrow.circlepath"] = "", // History
        ["person.2"] = "",             // People
        ["bell"] = "",                 // Ringer
        ["gearshape"] = "",            // Settings

        // Bookmarks / follow
        ["bookmark.circle"] = "",
        ["star"] = "",
        ["star.fill"] = "",
        ["star.slash"] = "",
        ["pin.fill"] = "",
        ["pin.slash"] = "",
        ["heart"] = "",
        ["flag"] = "",
        ["tag.fill"] = "",

        // Books, reading
        ["book"] = "",                 // ReadingMode
        ["book.fill"] = "",
        ["book.closed"] = "",          // Dictionary (a closed book)
        ["book.closed.fill"] = "",
        ["book.pages"] = "",           // Page
        ["doc.text"] = "",
        ["doc.richtext"] = "",         // PDF
        ["textformat"] = "",           // Font
        ["textformat.size"] = "",      // FontSize
        ["character"] = "",
        ["character.textbox"] = "",
        ["bold"] = "",
        ["text.alignleft"] = "",
        ["text.justify.left"] = "",
        ["list.bullet"] = "",
        ["rectangle.portrait"] = "",
        ["rectangle.split.3x1"] = "",
        ["arrow.left.and.right.square"] = "",
        ["arrow.up.and.down.text.horizontal"] = "",
        ["square.2.layers.3d"] = "",
        ["circle.lefthalf.striped.horizontal"] = "", // Contrast
        ["sun.max"] = "",              // Brightness
        ["paintpalette"] = "",         // Color
        ["photo"] = "",                // Picture
        ["arrow.up.left.and.arrow.down.right"] = "", // FullScreen
        ["globe"] = "",

        // Listen
        ["play.fill"] = "",
        ["pause.fill"] = "",
        ["stop.circle"] = "",
        ["backward.fill"] = "",        // Previous
        ["forward.fill"] = "",         // Next
        ["speedometer"] = "",
        ["music.note"] = "",

        // Fandom categories
        ["sparkles"] = "",
        ["gamecontroller"] = "",
        ["headphones"] = "",
        ["theatermasks"] = "",         // Emoji
        ["film"] = "",                 // Video
        ["paintbrush.pointed"] = "",  // Brush
        ["tv"] = "",                   // TVMonitor
        ["person.fill"] = "",          // Contact
        ["person"] = "",
        ["person.crop.circle"] = "",
        ["person.crop.circle.badge.questionmark"] = "",
        ["person.badge.plus"] = "",    // AddFriend
        ["person.fill.checkmark"] = "",
        ["person.slash"] = "",         // BlockContact
        ["person.wave.2"] = "",
        ["person.2.square.stack"] = "",

        // Actions
        ["square.and.arrow.up"] = "",  // Share
        ["arrow.down.circle"] = "",    // Download
        ["arrow.down.circle.fill"] = "",
        ["arrow.clockwise"] = "",      // Refresh
        ["arrow.triangle.merge"] = "",  // Merge
        ["arrow.up.arrow.down"] = "",  // Sort
        ["arrow.up"] = "",
        ["arrow.down"] = "",
        ["arrow.up.circle.fill"] = "",
        ["trash"] = "",
        ["xmark"] = "",
        ["xmark.circle.fill"] = "",
        ["checkmark"] = "",
        ["checkmark.circle"] = "",
        ["checkmark.circle.fill"] = "",
        ["plus.circle"] = "",
        ["minus.circle"] = "",
        ["ellipsis.circle"] = "",      // More
        ["slider.horizontal.3"] = "",  // Equalizer
        ["line.3.horizontal.decrease.circle"] = "", // Filter
        ["line.3.horizontal.decrease.circle.fill"] = "",
        ["folder"] = "",
        ["folder.badge.plus"] = "",
        ["folder.badge.minus"] = "",
        ["folder.badge.questionmark"] = "",
        ["eye"] = "",
        ["eye.slash"] = "",
        ["hand.tap"] = "",
        ["envelope"] = "",
        ["bubble.left"] = "",          // Comment
        ["bubble.left.and.bubble.right"] = "", // Message
        ["chevron.left"] = "",
        ["chevron.right"] = "",
        ["chevron.up"] = "",
        ["chevron.down"] = "",
        ["chevron.up.chevron.down"] = "",
        ["chevron.left.forwardslash.chevron.right"] = "", // Code
        ["clock"] = "",                // Recent
        ["bolt.fill"] = "",

        // Status
        ["exclamationmark.triangle"] = "",
        ["exclamationmark.triangle.fill"] = "",
        ["exclamationmark.circle.fill"] = "",
        ["exclamationmark.shield"] = "",
        ["questionmark.circle"] = "",
        ["wifi.exclamationmark"] = "",
        ["info.circle"] = "",
        ["lock"] = "",
        ["icloud"] = "",
        ["arrow.down.doc"] = "",
        ["keyboard"] = "",
        ["gamecontroller.fill"] = "",
        ["sidebar.left"] = "",
    };

    /// <summary>Adds (or overrides) a mapping. Features add the symbols only
    /// they use from a module initializer in their own folder.</summary>
    public static void Add(string sfSymbol, char glyph) => Map[sfSymbol] = glyph.ToString();

    public static bool Has(string sfSymbol) => Map.ContainsKey(sfSymbol);

    /// <summary>Every registered name and its glyph (the icon gallery).</summary>
    public static IReadOnlyDictionary<string, string> All => Map;

    /// <summary>The Fluent glyph for an SF Symbol name (a neutral page glyph when unknown).</summary>
    public static string Glyph(string sfSymbol) => Map.TryGetValue(sfSymbol, out var g) ? g : "";

    /// <summary>The icon at <paramref name="size"/>: a Fluent glyph, or a
    /// drawn path for the few icons the icon fonts lack.</summary>
    public static IconElement Icon(string sfSymbol, double size = 16)
    {
        if (Drawn.TryGetValue(sfSymbol, out var data))
            return new PathIcon { Data = Path(data, size), Width = size, Height = size };
        return new FontIcon { Glyph = Glyph(sfSymbol), FontFamily = Font, FontSize = size };
    }

    public static IconSource IconSource(string sfSymbol) =>
        Drawn.TryGetValue(sfSymbol, out var data)
            ? new PathIconSource { Data = Path(data, 16) }
            : new FontIconSource { Glyph = Glyph(sfSymbol), FontFamily = Font };

    // MARK: - Drawn icons

    /// <summary>Icons neither Segoe Fluent Icons nor Segoe MDL2 Assets has on
    /// every PC (a bookmark ribbon; a filled bell), as path markup on a 16-unit
    /// grid with Fluent's 1-unit stroke: outer contours clockwise, holes
    /// counter-clockwise (nonzero fill), so they sit beside the font's glyphs.</summary>
    private static readonly Dictionary<string, string> Drawn = new()
    {
        ["bookmark"] = Ribbon + " " + RibbonHole,
        ["bookmark.fill"] = Ribbon,
        ["bookmark.slash"] = Ribbon + " " + RibbonHole
            + " M2.88,1.18 L13.88,14.18 L13.12,14.82 L2.12,1.82 Z",
        ["bell.fill"] = "F1 M8,1.5 C10.5,1.5 12,3.5 12,6 L12,9.5 L13.5,11.5 L13.5,12.5 L2.5,12.5 L2.5,11.5 L4,9.5 L4,6 C4,3.5 5.5,1.5 8,1.5 Z"
            + " M6.25,13.5 L9.75,13.5 A1.75,1.75 0 0 1 6.25,13.5 Z",
    };

    private const string Ribbon = "F1 M5,1.5 L11,1.5 A1.5,1.5 0 0 1 12.5,3 L12.5,14.5 L8,11 L3.5,14.5 L3.5,3 A1.5,1.5 0 0 1 5,1.5 Z";
    private const string RibbonHole = "M5,2.5 A0.5,0.5 0 0 0 4.5,3 L4.5,12.45 L8,9.73 L11.5,12.45 L11.5,3 A0.5,0.5 0 0 0 11,2.5 Z";

    /// <summary>Whether the icon is drawn rather than a font glyph.</summary>
    public static bool IsDrawn(string sfSymbol) => Drawn.ContainsKey(sfSymbol);

    /// <summary>Every drawn icon's name (the icon gallery).</summary>
    public static IEnumerable<string> DrawnNames => Drawn.Keys;

    /// <summary>A new geometry each time, scaled from the 16-unit grid to
    /// <paramref name="size"/>. Built by hand rather than with
    /// XamlBindingHelper.ConvertValue, which hands back one shared geometry per
    /// string, so only the last icon drawn with it showed. Reads the subset of
    /// path markup used above: F, M, L, C, A and Z with absolute coordinates.</summary>
    private static Geometry Path(string data, double size)
    {
        var k = size / 16;
        var geometry = new PathGeometry { FillRule = FillRule.Nonzero };
        var tokens = PathTokens(data);
        var i = 0;
        double Num() => double.Parse(tokens[i++], System.Globalization.CultureInfo.InvariantCulture);
        Windows.Foundation.Point Pt() { var x = Num(); var y = Num(); return new(x * k, y * k); }
        PathFigure? figure = null;
        while (i < tokens.Count)
        {
            switch (tokens[i++])
            {
                case "F": geometry.FillRule = Num() == 0 ? FillRule.EvenOdd : FillRule.Nonzero; break;
                case "M":
                    figure = new PathFigure { StartPoint = Pt(), IsFilled = true };
                    geometry.Figures.Add(figure);
                    break;
                case "L": figure!.Segments.Add(new LineSegment { Point = Pt() }); break;
                case "C": figure!.Segments.Add(new BezierSegment { Point1 = Pt(), Point2 = Pt(), Point3 = Pt() }); break;
                case "A":
                    var radius = new Windows.Foundation.Size(Num() * k, Num() * k);
                    var rotation = Num();
                    var large = Num() != 0;
                    var clockwise = Num() != 0;
                    figure!.Segments.Add(new ArcSegment
                    {
                        Size = radius,
                        RotationAngle = rotation,
                        IsLargeArc = large,
                        SweepDirection = clockwise ? SweepDirection.Clockwise : SweepDirection.Counterclockwise,
                        Point = Pt(),
                    });
                    break;
                case "Z": figure!.IsClosed = true; break;
                default: throw new FormatException($"Unsupported path command in {data}");
            }
        }
        return geometry;
    }

    /// <summary>Splits path markup into command letters and numbers: a letter
    /// can sit right against its first number ("M5,1.5"), and commas and
    /// spaces both separate numbers.</summary>
    private static List<string> PathTokens(string data)
    {
        var tokens = new List<string>();
        var start = -1;
        for (var j = 0; j <= data.Length; j++)
        {
            var c = j < data.Length ? data[j] : ' ';
            var numeric = char.IsDigit(c) || c == '.' || (c == '-' && start < 0);
            if (numeric)
            {
                if (start < 0) start = j;
                continue;
            }
            if (start >= 0) { tokens.Add(data[start..j]); start = -1; }
            if (char.IsLetter(c)) tokens.Add(c.ToString());
            else if (c == '-') start = j; // a minus right after a number starts the next one
        }
        return tokens;
    }
}

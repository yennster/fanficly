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
    public static readonly FontFamily Font = new("Segoe Fluent Icons,Segoe MDL2 Assets");

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
        ["bookmark"] = "",             // Bookmarks
        ["bell"] = "",                 // Ringer
        ["gearshape"] = "",            // Settings

        // Bookmarks / follow
        ["bookmark.fill"] = "",
        ["bookmark.circle"] = "",
        ["bookmark.slash"] = "",
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
        ["paintbrush.pointed"] = "",   // Brush
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
        ["arrow.triangle.merge"] = "", // Merge
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

    /// <summary>The Fluent glyph for an SF Symbol name (a neutral page glyph when unknown).</summary>
    public static string Glyph(string sfSymbol) => Map.TryGetValue(sfSymbol, out var g) ? g : "";

    public static FontIcon Icon(string sfSymbol, double size = 16) => new()
    {
        Glyph = Glyph(sfSymbol),
        FontFamily = Font,
        FontSize = size,
    };

    public static FontIconSource IconSource(string sfSymbol) => new()
    {
        Glyph = Glyph(sfSymbol),
        FontFamily = Font,
    };
}

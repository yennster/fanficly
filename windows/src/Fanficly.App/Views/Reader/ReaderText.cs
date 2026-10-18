using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI.Text;

namespace Fanficly.App.Views.Reader;

/// <summary>How story text is laid out: the typography (already divided by the UI
/// zoom) plus what it resolves to in XAML. Built by <see cref="ReaderTextMeasurer.StyleFor"/>
/// so drawing and measuring use exactly the same values.</summary>
internal sealed record ReaderTextStyle(ReaderTypography Typography, FontFamily Font, double LineHeight, int CharacterSpacing);

/// <summary>
/// Builds the elements story text is drawn with — one paragraph
/// (ChapterContentView's paragraph <c>Text</c>, ReaderPageCell's block) and a
/// page's text column. Page-by-page measures pages with these same builders
/// (<see cref="ReaderTextMeasurer.MeasureDrawnPage"/>), so measured pages are the
/// pages on screen.
/// </summary>
internal static class ReaderText
{
    private static readonly Dictionary<string, FontFamily> Fonts = [];

    public static FontFamily Font(ReaderFontFamily family)
    {
        var name = family.WindowsFontFamily();
        if (!Fonts.TryGetValue(name, out var font)) Fonts[name] = font = new FontFamily(name);
        return font;
    }

    /// <summary>Applies the reader's text settings to a paragraph text block. Story
    /// text is never selectable (CLAUDE.md: no "Copy" callout on press-and-hold).</summary>
    public static void Apply(TextBlock tb, ReaderTextStyle style)
    {
        var t = style.Typography;
        tb.FontFamily = style.Font;
        tb.FontSize = t.FontSize;
        tb.FontWeight = t.BoldText ? FontWeights.Bold : FontWeights.Normal;
        tb.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        tb.LineHeight = style.LineHeight;
        tb.CharacterSpacing = style.CharacterSpacing;
        tb.TextWrapping = TextWrapping.Wrap;
        tb.TextTrimming = TextTrimming.None;
        tb.IsTextSelectionEnabled = false;
    }

    /// <summary>Story runs as inlines: bold, italic, underline, strikethrough.</summary>
    public static void Fill(InlineCollection inlines, ReaderRichText text)
    {
        inlines.Clear();
        foreach (var run in text.Runs)
        {
            if (run.Text.Length == 0) continue;
            var r = new Run { Text = run.Text };
            if (run.IsBold) r.FontWeight = FontWeights.Bold;
            if (run.IsItalic) r.FontStyle = FontStyle.Italic;
            var decorations = TextDecorations.None;
            if (run.IsUnderlined) decorations |= TextDecorations.Underline;
            if (run.IsStrikethrough) decorations |= TextDecorations.Strikethrough;
            if (decorations != TextDecorations.None) r.TextDecorations = decorations;
            inlines.Add(r);
        }
    }

    public static TextBlock Paragraph(ReaderRichText text, ReaderTextStyle style, Brush? foreground)
    {
        var tb = new TextBlock();
        Apply(tb, style);
        Fill(tb.Inlines, text);
        if (foreground is not null) tb.Foreground = foreground;
        return tb;
    }

    /// <summary>One rendered paragraph: an image slot, or the text in a rounded
    /// border that takes the karaoke highlight as a flush fill, so toggling it
    /// never reflows the text.</summary>
    public static FrameworkElement Block(ReaderRichText text, ReaderTextStyle style, Brush? foreground, bool loadImages = true)
    {
        if (text.ImageUrl is { } url) return ImageSlot(url, foreground, loadImages);
        return new Border
        {
            Child = Paragraph(text, style, foreground),
            CornerRadius = new CornerRadius(5),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
    }

    /// <summary>A page's (or a chapter's) paragraphs, stacked with the paragraph
    /// spacing between them (ReaderPageCell's inner VStack).</summary>
    public static StackPanel Column(IEnumerable<ReaderRichText> blocks, ReaderTextStyle style, Brush? foreground,
                                    List<FrameworkElement>? elements = null, bool loadImages = true)
    {
        var panel = new StackPanel { Spacing = style.Typography.ParagraphSpacing, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var block in blocks)
        {
            var element = Block(block, style, foreground, loadImages);
            panel.Children.Add(element);
            elements?.Add(element);
        }
        return panel;
    }

    /// <summary>Marks or clears the karaoke highlight on a block from <see cref="Block"/>.</summary>
    public static void SetHighlight(FrameworkElement block, Brush? highlight)
    {
        if (block is Border border) border.Background = highlight;
    }

    /// <summary>An embedded story image (ReaderInlineImage): always exactly
    /// <see cref="ReaderInlineImage.SlotHeight"/> tall, in every reading mode, so
    /// an image finishing loading never moves the text under a restored position.
    /// Loads straight from its (https, non-AO3) host; never saved with downloads.</summary>
    public static FrameworkElement ImageSlot(Uri url, Brush? foreground, bool load)
    {
        var slot = new Grid { Height = ReaderInlineImage.SlotHeight, HorizontalAlignment = HorizontalAlignment.Stretch };
        if (!load) return slot;

        var ring = new ProgressRing { IsActive = true, Width = 28, Height = 28, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(ring, "Story image, loading");
        var image = new Image { Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var frame = new Border { Child = image, CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var bitmap = new BitmapImage();
        bitmap.ImageOpened += (_, _) =>
        {
            ring.IsActive = false;
            ring.Visibility = Visibility.Collapsed;
            AutomationProperties.SetName(image, "Story image");
        };
        bitmap.ImageFailed += (_, _) =>
        {
            ring.IsActive = false;
            ring.Visibility = Visibility.Collapsed;
            frame.Visibility = Visibility.Collapsed;
            var label = UI.UI.Label("photo", "Image unavailable", Theme.Style.Caption, foreground);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            label.VerticalAlignment = VerticalAlignment.Center;
            label.Opacity = 0.6;
            slot.Children.Add(label);
        };
        image.Source = bitmap;
        slot.Children.Add(ring);
        slot.Children.Add(frame);
        try { bitmap.UriSource = url; }
        catch { ring.Visibility = Visibility.Collapsed; }
        return slot;
    }
}

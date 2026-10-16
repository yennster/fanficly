using Fanficly.App.Shell;
using Fanficly.App.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Shared;

/// <summary>Every icon name the app uses, drawn with its glyph — a check that
/// each one exists in the installed icon font (a missing glyph draws as an
/// empty box). Opened by launching with <c>-iconGallery</c>; the UI tests
/// photograph it.</summary>
internal sealed class IconGalleryScreen : Screen
{
    public IconGalleryScreen() => Title = "Icons";

    protected override FrameworkElement Build()
    {
        var flow = new FlowPanel { Spacing = 6, LineSpacing = 6 };
        // Font glyphs are captioned with their code point (the UI test checks
        // each against the installed font); drawn icons say so.
        foreach (var name in Symbols.All.Keys.Concat(Symbols.DrawnNames).Distinct().OrderBy(n => n, StringComparer.Ordinal))
        {
            var cell = new StackPanel { Width = 132, Padding = new Thickness(4), Spacing = 2 };
            var icon = Symbols.Icon(name, 20);
            icon.HorizontalAlignment = HorizontalAlignment.Left;
            cell.Children.Add(icon);
            var glyph = Symbols.Glyph(name);
            cell.Children.Add(UI.UI.Caption(Symbols.IsDrawn(name) ? $"{name}  (drawn)" : $"{name}  U+{char.ConvertToUtf32(glyph, 0):X4}"));
            flow.Children.Add(cell);
        }
        return UI.UI.Scroll(flow);
    }
}

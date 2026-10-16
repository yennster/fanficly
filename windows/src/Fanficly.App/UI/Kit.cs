using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Fanficly.App.UI;

/// <summary>
/// Small declarative helpers for building WinUI views in C# — the app's
/// equivalent of SwiftUI's view builders. Everything here returns ordinary
/// WinUI controls; there is no custom rendering.
/// </summary>
public static class UI
{
    public static StackPanel VStack(double spacing, params UIElement?[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Vertical, Spacing = spacing };
        foreach (var c in children) if (c is not null) panel.Children.Add(c);
        return panel;
    }

    public static StackPanel HStack(double spacing, params UIElement?[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var c in children) if (c is not null) panel.Children.Add(c);
        return panel;
    }

    /// <summary>A Grid from compact column/row specs: "Auto,*,2*,120".</summary>
    public static Grid Grid(string columns = "*", string rows = "Auto", double columnSpacing = 0, double rowSpacing = 0)
    {
        var g = new Grid { ColumnSpacing = columnSpacing, RowSpacing = rowSpacing };
        foreach (var c in columns.Split(',', StringSplitOptions.RemoveEmptyEntries))
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = Length(c) });
        foreach (var r in rows.Split(',', StringSplitOptions.RemoveEmptyEntries))
            g.RowDefinitions.Add(new RowDefinition { Height = Length(r) });
        return g;
    }

    public static GridLength Length(string spec)
    {
        spec = spec.Trim();
        if (spec.Equals("Auto", StringComparison.OrdinalIgnoreCase)) return GridLength.Auto;
        if (spec.EndsWith('*'))
        {
            var n = spec.Length == 1 ? 1 : double.Parse(spec[..^1], System.Globalization.CultureInfo.InvariantCulture);
            return new GridLength(n, GridUnitType.Star);
        }
        return new GridLength(double.Parse(spec, System.Globalization.CultureInfo.InvariantCulture));
    }

    public static TextBlock Text(string text, Theme.Style style = Theme.Style.Body, Brush? foreground = null,
                                 bool wrap = true, int maxLines = 0, bool selectable = false)
    {
        var (size, weight, family) = Theme.Metrics(style);
        var tb = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = weight,
            FontFamily = family,
            TextWrapping = wrap ? TextWrapping.WrapWholeWords : TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            IsTextSelectionEnabled = selectable,
        };
        if (maxLines > 0) tb.MaxLines = maxLines;
        if (foreground is not null) tb.Foreground = foreground;
        return tb;
    }

    public static TextBlock Secondary(string text, Theme.Style style = Theme.Style.Subheadline, int maxLines = 0) =>
        Text(text, style, Theme.TextSecondary, maxLines: maxLines);

    public static TextBlock Caption(string text) => Text(text, Theme.Style.Caption, Theme.TextSecondary);

    /// <summary>The small all-caps section label iOS uses above grouped lists.</summary>
    public static TextBlock SectionHeader(string text) => new TextBlock
    {
        Text = text.ToUpperInvariant(),
        FontSize = 11.5,
        FontWeight = FontWeights.SemiBold,
        CharacterSpacing = 40,
        Foreground = Theme.TextSecondary,
        Margin = new Thickness(4, 12, 0, 4),
    }.A11yHeading();

    public static FontIcon Icon(string sfSymbol, double size = 16, Brush? foreground = null)
    {
        var icon = Symbols.Icon(sfSymbol, size);
        if (foreground is not null) icon.Foreground = foreground;
        AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return icon;
    }

    /// <summary>Icon + text, like SwiftUI's Label.</summary>
    public static StackPanel Label(string sfSymbol, string text, Theme.Style style = Theme.Style.Body, Brush? foreground = null, double spacing = 8)
    {
        var (size, _, _) = Theme.Metrics(style);
        var icon = Icon(sfSymbol, size, foreground);
        icon.VerticalAlignment = VerticalAlignment.Center;
        var tb = Text(text, style, foreground, wrap: false);
        tb.VerticalAlignment = VerticalAlignment.Center;
        return HStack(spacing, icon, tb);
    }

    public enum ButtonKind { Standard, Accent, Subtle, Destructive }

    public static Button Button(string text, Action onClick, string? sfSymbol = null, ButtonKind kind = ButtonKind.Standard)
    {
        var button = new Button
        {
            Content = sfSymbol is null ? text : Label(sfSymbol, text, spacing: 6),
        };
        ApplyKind(button, kind);
        AutomationProperties.SetName(button, text);
        button.Click += (_, _) => onClick();
        return button;
    }

    public static void ApplyKind(Button button, ButtonKind kind)
    {
        switch (kind)
        {
            case ButtonKind.Accent:
                button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
                break;
            case ButtonKind.Subtle:
                button.Background = Theme.Transparent;
                button.BorderBrush = Theme.Transparent;
                break;
            case ButtonKind.Destructive:
                button.Foreground = Theme.Danger;
                break;
        }
    }

    /// <summary>An icon-only button. Its label is its tooltip and its Narrator name
    /// (VoiceOver parity: icon-only controls always get a label).</summary>
    public static Button IconButton(string sfSymbol, string label, Action onClick, double iconSize = 16)
    {
        var button = new Button
        {
            Content = Icon(sfSymbol, iconSize),
            Background = Theme.Transparent,
            BorderBrush = Theme.Transparent,
            Padding = new Thickness(8),
            MinWidth = 36,
            MinHeight = 36,
        };
        ToolTipService.SetToolTip(button, label);
        AutomationProperties.SetName(button, label);
        button.Click += (_, _) => onClick();
        return button;
    }

    public static AppBarButton ToolbarButton(string sfSymbol, string label, Action onClick, bool showLabel = false)
    {
        var b = new AppBarButton
        {
            Icon = new FontIcon { Glyph = Symbols.Glyph(sfSymbol), FontFamily = Symbols.Font },
            Label = label,
            LabelPosition = showLabel ? CommandBarLabelPosition.Default : CommandBarLabelPosition.Collapsed,
        };
        ToolTipService.SetToolTip(b, label);
        AutomationProperties.SetName(b, label);
        b.Click += (_, _) => onClick();
        return b;
    }

    public static Border Card(UIElement content, double padding = 16, double cornerRadius = 8)
    {
        return new Border
        {
            Child = content,
            Padding = new Thickness(padding),
            CornerRadius = new CornerRadius(cornerRadius),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
        };
    }

    public static Border Divider(double inset = 0) => new()
    {
        Height = 1,
        Background = Theme.Divider,
        Margin = new Thickness(inset, 0, 0, 0),
    };

    /// <summary>A rounded tag pill (the Mac app's chips).</summary>
    public static Border Chip(string text, Brush? background = null, Brush? foreground = null, Action? onRemove = null,
                              string? sfSymbol = null, double fontSize = 12)
    {
        var row = HStack(4);
        if (sfSymbol is not null)
        {
            var icon = Icon(sfSymbol, fontSize, foreground ?? Theme.Accent);
            icon.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(icon);
        }
        var label = new TextBlock
        {
            Text = text,
            FontSize = fontSize,
            Foreground = foreground ?? Theme.Accent,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        row.Children.Add(label);
        var chip = new Border
        {
            Child = row,
            Background = background ?? Theme.AccentSubtle,
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(9, 3, onRemove is null ? 9 : 4, 3),
        };
        if (onRemove is not null)
        {
            var remove = new Button
            {
                Content = Icon("xmark", 9, foreground ?? Theme.Accent),
                Padding = new Thickness(4),
                MinWidth = 0,
                MinHeight = 0,
                Background = Theme.Transparent,
                BorderBrush = Theme.Transparent,
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(remove, $"Remove {text}");
            ToolTipService.SetToolTip(remove, $"Remove {text}");
            remove.Click += (_, _) => onRemove();
            row.Children.Add(remove);
        }
        AutomationProperties.SetName(chip, text);
        return chip;
    }

    /// <summary>ContentUnavailableView: an icon, a title, a message and an optional action.</summary>
    public static FrameworkElement EmptyState(string sfSymbol, string title, string? message = null,
                                              string? actionTitle = null, Action? action = null)
    {
        var stack = VStack(10,
            Icon(sfSymbol, 44, Theme.TextTertiary).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center),
            Text(title, Theme.Style.Title3).Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; }),
            message is null ? null : Secondary(message, Theme.Style.Body).Also(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; t.MaxWidth = 420; }),
            actionTitle is null || action is null ? null : Button(actionTitle, action, kind: ButtonKind.Accent).Also(b => { b.HorizontalAlignment = HorizontalAlignment.Center; b.Margin = new Thickness(0, 6, 0, 0); }));
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        stack.Padding = new Thickness(24);
        return stack;
    }

    public static FrameworkElement Loading(string? message = null)
    {
        var stack = VStack(12,
            new ProgressRing { IsActive = true, Width = 32, Height = 32 },
            message is null ? null : Secondary(message, Theme.Style.Body).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center));
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        return stack;
    }

    /// <summary>A vertically scrolling page body with the standard page margins.</summary>
    public static ScrollViewer Scroll(UIElement content, double horizontalPadding = 24, double maxWidth = double.PositiveInfinity)
    {
        if (content is FrameworkElement fe)
        {
            fe.Margin = new Thickness(horizontalPadding, 8, horizontalPadding, 24);
            if (!double.IsPositiveInfinity(maxWidth)) { fe.MaxWidth = maxWidth; fe.HorizontalAlignment = HorizontalAlignment.Stretch; }
        }
        return new ScrollViewer
        {
            Content = content,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    /// <summary>A grouped settings-style section: caption header + a card of rows
    /// separated by dividers.</summary>
    public static StackPanel Section(string? header, IEnumerable<UIElement> rows, string? footer = null)
    {
        var card = new StackPanel();
        var first = true;
        foreach (var row in rows)
        {
            if (!first) card.Children.Add(Divider());
            first = false;
            card.Children.Add(row);
        }
        var section = new StackPanel { Spacing = 2 };
        if (header is not null) section.Children.Add(SectionHeader(header));
        section.Children.Add(new Border
        {
            Child = card,
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
        });
        if (footer is not null)
            section.Children.Add(Secondary(footer, Theme.Style.Footnote).Also(t => t.Margin = new Thickness(4, 4, 4, 0)));
        return section;
    }

    /// <summary>One row in a <see cref="Section"/>: label (and optional subtitle) on
    /// the left, a control on the right.</summary>
    public static Grid SettingsRow(string title, UIElement? trailing = null, string? subtitle = null, string? sfSymbol = null)
    {
        var grid = Grid("Auto,*,Auto", columnSpacing: 12);
        grid.Padding = new Thickness(14, 10, 14, 10);
        grid.MinHeight = 48;
        if (sfSymbol is not null)
            grid.Children.Add(Icon(sfSymbol, 16, Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(0));
        var labels = VStack(1, Text(title), subtitle is null ? null : Secondary(subtitle, Theme.Style.Footnote));
        labels.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(labels.Col(1));
        if (trailing is FrameworkElement t)
        {
            t.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(t.Col(2));
        }
        return grid;
    }

    /// <summary>A full-width tappable row (iOS NavigationLink row): content plus a chevron.</summary>
    public static Button NavRow(UIElement content, Action onClick, string? accessibleName = null, bool chevron = true)
    {
        var grid = Grid("*,Auto", columnSpacing: 8);
        grid.Children.Add(content.Col(0));
        if (chevron)
            grid.Children.Add(Icon("chevron.right", 12, Theme.TextTertiary).Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(1));
        var button = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Theme.Transparent,
            BorderBrush = Theme.Transparent,
            Padding = new Thickness(14, 10, 14, 10),
            CornerRadius = new CornerRadius(0),
        };
        if (accessibleName is not null) AutomationProperties.SetName(button, accessibleName);
        button.Click += (_, _) => onClick();
        return button;
    }

    public static ToggleSwitch Toggle(bool isOn, Action<bool> onChanged, string? accessibleName = null)
    {
        var t = new ToggleSwitch { IsOn = isOn, OnContent = "", OffContent = "", MinWidth = 0 };
        if (accessibleName is not null) AutomationProperties.SetName(t, accessibleName);
        t.Toggled += (_, _) => onChanged(t.IsOn);
        return t;
    }

    public static MenuFlyoutItem MenuItem(string text, Action onClick, string? sfSymbol = null, bool isDestructive = false)
    {
        var item = new MenuFlyoutItem { Text = text };
        if (sfSymbol is not null) item.Icon = new FontIcon { Glyph = Symbols.Glyph(sfSymbol), FontFamily = Symbols.Font };
        if (isDestructive) item.Foreground = Theme.Danger;
        item.Click += (_, _) => onClick();
        return item;
    }

    public static ToggleMenuFlyoutItem CheckItem(string text, bool isChecked, Action onClick)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = isChecked };
        item.Click += (_, _) => onClick();
        return item;
    }

    public static MenuFlyout Menu(params MenuFlyoutItemBase?[] items)
    {
        var flyout = new MenuFlyout();
        foreach (var i in items) if (i is not null) flyout.Items.Add(i);
        return flyout;
    }

    /// <summary>A wrap panel for chips (SwiftUI FlowLayout).</summary>
    public static FlowPanel Flow(double spacing = 6, double lineSpacing = 6, params UIElement?[] children)
    {
        var panel = new FlowPanel { Spacing = spacing, LineSpacing = lineSpacing };
        foreach (var c in children) if (c is not null) panel.Children.Add(c);
        return panel;
    }

    /// <summary>A short-lived in-app message (Windows' InfoBar).</summary>
    public static InfoBar Banner(string title, string? message = null, InfoBarSeverity severity = InfoBarSeverity.Informational, bool closable = true) => new()
    {
        Title = title,
        Message = message ?? "",
        Severity = severity,
        IsOpen = true,
        IsClosable = closable,
    };
}

/// <summary>Fluent property setters so views read top-down like SwiftUI.</summary>
public static class ElementExtensions
{
    public static T Also<T>(this T element, Action<T> configure)
    {
        configure(element);
        return element;
    }

    public static T Col<T>(this T e, int column, int span = 1) where T : UIElement
    {
        Microsoft.UI.Xaml.Controls.Grid.SetColumn((FrameworkElement)(object)e, column);
        if (span > 1) Microsoft.UI.Xaml.Controls.Grid.SetColumnSpan((FrameworkElement)(object)e, span);
        return e;
    }

    public static T Row<T>(this T e, int row, int span = 1) where T : UIElement
    {
        Microsoft.UI.Xaml.Controls.Grid.SetRow((FrameworkElement)(object)e, row);
        if (span > 1) Microsoft.UI.Xaml.Controls.Grid.SetRowSpan((FrameworkElement)(object)e, span);
        return e;
    }

    public static T Margin<T>(this T e, double uniform) where T : FrameworkElement { e.Margin = new Thickness(uniform); return e; }
    public static T Margin<T>(this T e, double horizontal, double vertical) where T : FrameworkElement { e.Margin = new Thickness(horizontal, vertical, horizontal, vertical); return e; }
    public static T Margin<T>(this T e, double l, double t, double r, double b) where T : FrameworkElement { e.Margin = new Thickness(l, t, r, b); return e; }

    public static T Center<T>(this T e) where T : FrameworkElement
    {
        e.HorizontalAlignment = HorizontalAlignment.Center;
        e.VerticalAlignment = VerticalAlignment.Center;
        return e;
    }

    public static T Tip<T>(this T e, string tooltip) where T : DependencyObject
    {
        ToolTipService.SetToolTip(e, tooltip);
        return e;
    }

    /// <summary>Narrator name (SwiftUI's accessibilityLabel).</summary>
    public static T A11y<T>(this T e, string name) where T : DependencyObject
    {
        AutomationProperties.SetName(e, name);
        return e;
    }

    public static T A11yHeading<T>(this T e) where T : DependencyObject
    {
        AutomationProperties.SetHeadingLevel(e, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        return e;
    }

    /// <summary>Hides decorative elements from Narrator (accessibilityHidden).</summary>
    public static T A11yHidden<T>(this T e) where T : DependencyObject
    {
        AutomationProperties.SetAccessibilityView(e, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return e;
    }

    public static T Visible<T>(this T e, bool visible) where T : UIElement
    {
        e.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        return e;
    }

    public static T OnTapped<T>(this T e, Action action) where T : UIElement
    {
        e.Tapped += (_, args) => { args.Handled = true; action(); };
        return e;
    }

    public static T Shortcut<T>(this T e, Windows.System.VirtualKey key, Windows.System.VirtualKeyModifiers modifiers = Windows.System.VirtualKeyModifiers.Control,
                                Action? action = null) where T : UIElement
    {
        var accel = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        if (action is not null) accel.Invoked += (_, a) => { a.Handled = true; action(); };
        e.KeyboardAccelerators.Add(accel);
        return e;
    }
}

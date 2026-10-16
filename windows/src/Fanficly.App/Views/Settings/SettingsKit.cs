using System.Globalization;
using Fanficly.App.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Fanficly.App.Views.Settings;

/// <summary>Building blocks shared by the Settings pages, in the Windows 11
/// Settings style: grouped cards of rows with a control on the trailing edge.</summary>
internal static class SettingsKit
{
    public const double PageMaxWidth = 1000;

    /// <summary>A scrolling page of sections, capped at a readable width.</summary>
    public static ScrollViewer Page(StackPanel content, string automationId)
    {
        content.Spacing = 18;
        var scroll = UI.UI.Scroll(content, maxWidth: PageMaxWidth);
        AutomationProperties.SetAutomationId(scroll, automationId);
        return scroll;
    }

    /// <summary>A row that acts like a NavigationLink: icon, title, optional
    /// subtitle, chevron. Pushes a sub-page.</summary>
    public static Button LinkRow(string title, Action onClick, string? sfSymbol = null, string? subtitle = null,
                                 string? automationId = null, bool chevron = true, string? trailingText = null)
    {
        var grid = UI.UI.Grid("Auto,*,Auto", columnSpacing: 12);
        if (sfSymbol is not null)
            grid.Children.Add(UI.UI.Icon(sfSymbol, 16, Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(0));
        var labels = UI.UI.VStack(1, UI.UI.Text(title),
            subtitle is null ? null : UI.UI.Secondary(subtitle, Theme.Style.Footnote));
        labels.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(labels.Col(1));
        if (trailingText is not null)
            grid.Children.Add(UI.UI.Secondary(trailingText, Theme.Style.Body).Also(t => t.VerticalAlignment = VerticalAlignment.Center).Col(2));
        var row = UI.UI.NavRow(grid, onClick, subtitle is null ? title : $"{title}, {subtitle}", chevron);
        row.MinHeight = 48;
        if (automationId is not null) AutomationProperties.SetAutomationId(row, automationId);
        return row;
    }

    /// <summary>A full-width action row (a Form button): accent text, or red when destructive.</summary>
    public static Button ActionRow(string title, Action onClick, string? sfSymbol = null, bool destructive = false,
                                   string? automationId = null, string? tooltip = null)
    {
        var brush = destructive ? Theme.Danger : Theme.Accent;
        UIElement content = sfSymbol is null
            ? UI.UI.Text(title, foreground: brush)
            : UI.UI.Label(sfSymbol, title, foreground: brush);
        var row = UI.UI.NavRow(content, onClick, title, chevron: false);
        row.MinHeight = 44;
        if (automationId is not null) AutomationProperties.SetAutomationId(row, automationId);
        if (tooltip is not null) ToolTipService.SetToolTip(row, tooltip);
        return row;
    }

    /// <summary>A settings row whose trailing control is a toggle switch.</summary>
    public static Grid ToggleRow(string title, bool isOn, Action<bool> onChanged, string? sfSymbol = null,
                                 string? subtitle = null, string? tooltip = null, string? automationId = null)
    {
        var toggle = UI.UI.Toggle(isOn, onChanged, title);
        if (automationId is not null) AutomationProperties.SetAutomationId(toggle, automationId);
        var row = UI.UI.SettingsRow(title, toggle, subtitle, sfSymbol);
        if (tooltip is not null) ToolTipService.SetToolTip(row, tooltip);
        return row;
    }

    /// <summary>A drop-down of (value, label) choices.</summary>
    public static ComboBox Choice(string accessibleName, IEnumerable<(string Value, string Label)> items, string selected,
                                  Action<string> onChanged, double minWidth = 200)
    {
        var combo = new ComboBox { MinWidth = minWidth };
        var values = new List<string>();
        foreach (var (value, label) in items)
        {
            values.Add(value);
            combo.Items.Add(new ComboBoxItem { Content = label, Tag = value });
        }
        combo.SelectedIndex = values.IndexOf(selected);
        AutomationProperties.SetName(combo, accessibleName);
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is ComboBoxItem { Tag: string v }) onChanged(v);
        };
        return combo;
    }

    /// <summary>A single-choice list (SwiftUI's inline Picker): radio buttons,
    /// optionally with an icon or a font per choice.</summary>
    public static RadioButtons Radios(string accessibleName, IEnumerable<(string Value, string Label)> items, string selected,
                                      Action<string> onChanged, Func<string, string?>? symbol = null,
                                      Func<string, Microsoft.UI.Xaml.Media.FontFamily?>? font = null, int columns = 1)
    {
        var radios = new RadioButtons { MaxColumns = columns, Margin = new Thickness(14, 6, 14, 10) };
        var values = new List<string>();
        foreach (var (value, label) in items)
        {
            values.Add(value);
            object content = label;
            if (symbol?.Invoke(value) is { } sf) content = UI.UI.Label(sf, label);
            else if (font?.Invoke(value) is { } ff) content = new TextBlock { Text = label, FontFamily = ff, FontSize = 15 };
            var rb = new RadioButton { Content = content, Tag = value };
            AutomationProperties.SetName(rb, label);
            radios.Items.Add(rb);
        }
        radios.SelectedIndex = values.IndexOf(selected);
        AutomationProperties.SetName(radios, accessibleName);
        radios.SelectionChanged += (_, _) =>
        {
            if (radios.SelectedItem is RadioButton { Tag: string v }) onChanged(v);
        };
        return radios;
    }

    /// <summary>
    /// A labelled slider with − / + buttons for fine steps (ReaderSettingsView's
    /// metricSlider): the title and current value above, the controls below.
    /// </summary>
    public static FrameworkElement MetricSlider(string title, string sfSymbol, double value, (double Min, double Max) range,
                                                double step, string unit, Action<double> onChanged, string? automationId = null)
    {
        string Format(double v) => step < 1.0
            ? v.ToString("0.0", CultureInfo.CurrentCulture)
            : Math.Round(v).ToString(CultureInfo.CurrentCulture);
        var stepText = step < 1.0 ? step.ToString("0.0", CultureInfo.CurrentCulture) : ((int)step).ToString(CultureInfo.CurrentCulture);

        var valueText = UI.UI.Secondary($"{Format(value)} {unit}", Theme.Style.Subheadline);
        valueText.HorizontalAlignment = HorizontalAlignment.Right;
        valueText.VerticalAlignment = VerticalAlignment.Center;
        var header = UI.UI.Grid("*,Auto");
        header.Children.Add(UI.UI.Label(sfSymbol, title, Theme.Style.Subheadline).Col(0));
        header.Children.Add(valueText.Col(1));

        var slider = new Slider
        {
            Minimum = range.Min,
            Maximum = range.Max,
            StepFrequency = step,
            SmallChange = step,
            LargeChange = step * 5,
            Value = Math.Clamp(value, range.Min, range.Max),
            IsThumbToolTipEnabled = false,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(slider, title);
        AutomationProperties.SetHelpText(slider, $"Adjusts the {title.ToLowerInvariant()} of the reader text, in {unit}.");
        if (automationId is not null) AutomationProperties.SetAutomationId(slider, automationId);
        ToolTipService.SetToolTip(slider, $"Adjust the {title.ToLowerInvariant()}");

        var minus = UI.UI.IconButton("minus.circle", $"Decrease {title}", () =>
            slider.Value = Math.Max(range.Min, Math.Round((slider.Value - step) / step) * step));
        AutomationProperties.SetHelpText(minus, $"Decreases {title.ToLowerInvariant()} by {stepText} {unit}");
        var plus = UI.UI.IconButton("plus.circle", $"Increase {title}", () =>
            slider.Value = Math.Min(range.Max, Math.Round((slider.Value + step) / step) * step));
        AutomationProperties.SetHelpText(plus, $"Increases {title.ToLowerInvariant()} by {stepText} {unit}");

        slider.ValueChanged += (_, e) =>
        {
            valueText.Text = $"{Format(e.NewValue)} {unit}";
            onChanged(e.NewValue);
        };

        var controls = UI.UI.Grid("Auto,*,Auto", columnSpacing: 8);
        controls.Children.Add(minus.Col(0));
        controls.Children.Add(slider.Col(1));
        controls.Children.Add(plus.Col(2));

        var stack = UI.UI.VStack(4, header, controls);
        stack.Padding = new Thickness(14, 10, 14, 6);
        return stack;
    }

    /// <summary>A two-choice segmented control (SwiftUI's .segmented picker) as a
    /// pair of radio-behaving toggle buttons.</summary>
    public static StackPanel Segmented(string accessibleName, IReadOnlyList<(string Value, string Label)> items, string selected,
                                       Action<string> onChanged)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        AutomationProperties.SetName(row, accessibleName);
        var buttons = new List<ToggleButton>();
        foreach (var (value, label) in items)
        {
            var b = new ToggleButton { Content = label, IsChecked = value == selected, MinWidth = 96, Tag = value };
            AutomationProperties.SetName(b, $"{accessibleName}: {label}");
            b.Click += (_, _) =>
            {
                foreach (var other in buttons) other.IsChecked = other == b;
                onChanged(value);
            };
            buttons.Add(b);
            row.Children.Add(b);
        }
        return row;
    }

    /// <summary>A plain paragraph block inside a section card.</summary>
    public static FrameworkElement Note(string text, string? sfSymbol = null, Microsoft.UI.Xaml.Media.Brush? iconBrush = null)
    {
        var body = UI.UI.Secondary(text, Theme.Style.Footnote);
        if (sfSymbol is null)
        {
            body.Margin = new Thickness(14, 10, 14, 10);
            return body;
        }
        var grid = UI.UI.Grid("Auto,*", columnSpacing: 10);
        grid.Padding = new Thickness(14, 10, 14, 10);
        grid.Children.Add(UI.UI.Icon(sfSymbol, 16, iconBrush ?? Theme.Accent).Also(i => i.VerticalAlignment = VerticalAlignment.Top).Col(0));
        grid.Children.Add(body.Col(1));
        return grid;
    }

    public static async Task OpenUriAsync(string uri)
    {
        try { await Windows.System.Launcher.LaunchUriAsync(new Uri(uri)); }
        catch (Exception e) { AppHost.Log($"Opening {uri} failed: {e.Message}"); }
    }
}

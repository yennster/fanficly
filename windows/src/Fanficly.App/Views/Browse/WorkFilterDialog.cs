using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Fanficly.App.Views.Browse;

/// <summary>
/// The AO3-style filter panel over a works list (WorkFilterSheet): saved
/// filters, sort, rating, archive warnings, category, status, word count, tags
/// and language. It edits a copy; <b>Apply</b> hands it back, <b>Reset</b>
/// clears everything but the fandom, and <b>Cancel</b> (Esc) leaves the list
/// as it was. Saving a filter happens inline — a second dialog can't open over
/// this one.
/// </summary>
internal sealed class WorkFilterDialog
{
    private AO3SearchFilters _filters;
    private readonly ContentDialog _dialog;
    private readonly ScrollViewer _scroll;

    // Editable text mirrors for the comma-separated tag fields and word count.
    private TextBox _relationships = null!, _characters = null!, _freeforms = null!, _exclude = null!;
    private TextBox _wordsFrom = null!, _wordsTo = null!;
    private StackPanel _savePanel = null!;
    private TextBox _saveName = null!;

    private WorkFilterDialog(AO3SearchFilters filters)
    {
        _filters = filters;
        _scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            Padding = new Thickness(0, 0, 12, 0),
        };
        _dialog = new ContentDialog
        {
            Title = "Filters",
            Content = _scroll,
            PrimaryButtonText = "Apply",
            SecondaryButtonText = "Reset",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        _dialog.Resources["ContentDialogMaxWidth"] = 600.0;
        _dialog.Resources["ContentDialogMinWidth"] = 320.0;
        _dialog.Resources["ContentDialogMaxHeight"] = 900.0;
        var resetStyle = new Style(typeof(Button));
        resetStyle.Setters.Add(new Setter(Control.ForegroundProperty, Theme.Danger));
        _dialog.SecondaryButtonStyle = resetStyle;
        AutomationProperties.SetAutomationId(_dialog, "filters.sheet");
        // Reset keeps the panel open, like the sheet's toolbar button.
        _dialog.SecondaryButtonClick += (_, e) =>
        {
            e.Cancel = true;
            Reset();
        };
        BuildForm();
    }

    /// <summary>Shows the panel over <paramref name="filters"/>; the edited
    /// filters on Apply, null when cancelled.</summary>
    public static async Task<AO3SearchFilters?> ShowAsync(AO3SearchFilters filters)
    {
        var sheet = new WorkFilterDialog(filters.Clone());
        var result = await Dialogs.ShowAsync(sheet._dialog);
        if (result != ContentDialogResult.Primary) return null;
        sheet.CommitText();
        return sheet._filters;
    }

    // MARK: - Form

    private void BuildForm()
    {
        var form = UI.UI.VStack(6,
            SavedFiltersSection(),
            SortSection(),
            ToggleSection("Rating", SearchEnums.AllRatings, r => r.DisplayName(), _filters.Ratings),
            ToggleSection("Archive warnings", SearchEnums.AllWarnings, w => w.DisplayName(), _filters.Warnings),
            ToggleSection("Category", SearchEnums.AllCategories, c => c.DisplayName(), _filters.Categories),
            StatusSection(),
            WordCountSection(),
            TagsSection(),
            LanguageSection());
        form.Padding = new Thickness(0, 0, 0, 8);
        _scroll.Content = form;
    }

    private static FrameworkElement Group(string header, params UIElement?[] rows) =>
        UI.UI.VStack(6, UI.UI.SectionHeader(header), UI.UI.VStack(8, rows).Also(s => s.Margin = new Thickness(4, 0, 0, 4)));

    private FrameworkElement SavedFiltersSection()
    {
        var saved = AppHost.Library.All<SavedFilter>().OrderByDescending(f => f.SavedAt).ToList();
        var rows = new List<UIElement>();
        foreach (var filter in saved)
        {
            var row = new Button
            {
                Content = UI.UI.Label("line.3.horizontal.decrease.circle", filter.Name),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            UI.UI.ApplyKind(row, UI.UI.ButtonKind.Subtle);
            AutomationProperties.SetName(row, $"Apply saved filter {filter.Name}");
            AutomationProperties.SetHelpText(row, "Press Delete to remove this saved filter.");
            row.Click += (_, _) => ApplySaved(filter);
            row.ContextFlyout = UI.UI.Menu(UI.UI.MenuItem("Delete", () => DeleteSaved(filter), "trash", isDestructive: true));
            row.KeyDown += (_, e) =>
            {
                if (e.Key == VirtualKey.Delete) { e.Handled = true; DeleteSaved(filter); }
            };
            rows.Add(row);
        }

        var saveButton = UI.UI.Button("Save current filters…", ShowSavePanel, "plus.circle", UI.UI.ButtonKind.Subtle);
        saveButton.HorizontalAlignment = HorizontalAlignment.Left;
        AutomationProperties.SetAutomationId(saveButton, "filters.save");
        rows.Add(saveButton);

        _saveName = new TextBox { PlaceholderText = "Name", MinWidth = 260 };
        AutomationProperties.SetName(_saveName, "Filter name");
        _saveName.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter) { e.Handled = true; SaveCurrentFilter(); }
            else if (e.Key == VirtualKey.Escape) { e.Handled = true; _savePanel.Visibility = Visibility.Collapsed; }
        };
        var save = UI.UI.Button("Save", SaveCurrentFilter, kind: UI.UI.ButtonKind.Accent);
        var cancel = UI.UI.Button("Cancel", () => _savePanel.Visibility = Visibility.Collapsed);
        _saveName.TextChanged += (_, _) => save.IsEnabled = _saveName.Text.Trim().Length > 0;
        _savePanel = UI.UI.VStack(8,
            UI.UI.Text("Save filter", Theme.Style.Headline),
            UI.UI.Secondary("Saves these filters (rating, tags, status, etc.) so you can apply them to any fandom later. The fandom itself isn't saved.", Theme.Style.Footnote),
            _saveName,
            UI.UI.HStack(8, save, cancel));
        _savePanel.Visibility = Visibility.Collapsed;
        rows.Add(UI.UI.Card(_savePanel, padding: 12));

        return Group("Saved filters", rows.ToArray());
    }

    private void ShowSavePanel()
    {
        CommitText();
        _saveName.Text = _filters.SuggestedName();
        _savePanel.Visibility = Visibility.Visible;
        _saveName.Focus(FocusState.Programmatic);
        _saveName.SelectAll();
    }

    private void SaveCurrentFilter()
    {
        var name = _saveName.Text.Trim();
        if (name.Length == 0) return;
        CommitText();
        var json = _filters.SavedJson();
        var store = AppHost.Library;
        if (store.GetSavedFilter(name) is { } existing)
        {
            existing.FiltersJson = json;
            existing.SavedAt = DateTimeOffset.Now;
        }
        else
        {
            store.Insert(new SavedFilter(name, json));
        }
        store.TrySave();
        LibrarySyncManager.QueueBackupShared(store);
        Shell.MainWindow.Current.Announce($"Saved filter {name}");
        BuildForm();
    }

    private void ApplySaved(SavedFilter saved)
    {
        if (AO3SearchFilters.FromSavedJson(saved.FiltersJson) is not { } loaded) return;
        loaded.FandomNames = _filters.FandomNames; // keep the current fandom
        _filters = loaded;
        BuildForm();
        Shell.MainWindow.Current.Announce($"Applied {saved.Name}");
    }

    private void DeleteSaved(SavedFilter saved)
    {
        CommitText();
        AppHost.Library.Delete(saved);
        AppHost.Library.TrySave();
        LibrarySyncManager.QueueBackupShared(AppHost.Library);
        BuildForm();
        Shell.MainWindow.Current.Announce($"Deleted {saved.Name}");
    }

    private FrameworkElement SortSection()
    {
        var sortBy = Picker("Sort by", SearchEnums.AllSortColumns.Select(c => c.DisplayName()),
            IndexOf(SearchEnums.AllSortColumns, _filters.SortColumn),
            i => _filters.SortColumn = SearchEnums.AllSortColumns[i]);
        AutomationProperties.SetAutomationId(sortBy, "filters.sortBy");
        SortDirection[] directions = [SortDirection.Asc, SortDirection.Desc];
        var direction = Picker("Direction", directions.Select(d => d.DisplayName()),
            Array.IndexOf(directions, _filters.SortDirection),
            i => _filters.SortDirection = directions[i]);
        AutomationProperties.SetAutomationId(direction, "filters.sortDirection");
        return Group("Sort", sortBy, direction);
    }

    private static FrameworkElement ToggleSection<T>(string header, IReadOnlyList<T> all, Func<T, string> name, HashSet<T> selected)
    {
        var rows = all.Select(value =>
        {
            var box = new CheckBox { Content = name(value), IsChecked = selected.Contains(value) };
            box.Checked += (_, _) => selected.Add(value);
            box.Unchecked += (_, _) => selected.Remove(value);
            return (UIElement)box;
        }).ToArray();
        var panel = UI.UI.Flow(16, 0, rows);
        return Group(header, panel);
    }

    private FrameworkElement StatusSection()
    {
        TriState[] states = [TriState.Any, TriState.Yes, TriState.No];
        var completion = Picker("Completion", ["Any", "Complete only", "Work in progress"],
            Array.IndexOf(states, _filters.Complete), i => _filters.Complete = states[i]);
        var crossovers = Picker("Crossovers", ["Include", "Only crossovers", "Exclude crossovers"],
            Array.IndexOf(states, _filters.Crossover), i => _filters.Crossover = states[i]);
        var oneshot = new ToggleSwitch { Header = "Single chapter / oneshot", IsOn = _filters.SingleChapter };
        oneshot.Toggled += (_, _) => _filters.SingleChapter = oneshot.IsOn;
        return Group("Status", completion, crossovers, oneshot);
    }

    private FrameworkElement WordCountSection()
    {
        var (from, to) = BrowseModels.ParseWordCount(_filters.WordCount);
        _wordsFrom = NumberField("From", from);
        _wordsTo = NumberField("To", to);
        var row = UI.UI.Grid("*,Auto,*", columnSpacing: 8);
        row.Children.Add(_wordsFrom.Col(0));
        row.Children.Add(UI.UI.Secondary("–", Theme.Style.Body).Also(t => t.VerticalAlignment = VerticalAlignment.Center).A11yHidden().Col(1));
        row.Children.Add(_wordsTo.Col(2));
        return Group("Word count", row);
    }

    private static TextBox NumberField(string placeholder, string text)
    {
        var box = new TextBox { PlaceholderText = placeholder, Text = text };
        box.InputScope = new Microsoft.UI.Xaml.Input.InputScope
        {
            Names = { new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number) },
        };
        AutomationProperties.SetName(box, $"Word count {placeholder.ToLowerInvariant()}");
        // Digits only (the sheet's number pad).
        box.BeforeTextChanging += (_, e) => e.Cancel = e.NewText.Any(c => !char.IsAsciiDigit(c));
        return box;
    }

    private FrameworkElement TagsSection()
    {
        _relationships = TagField("Relationships", _filters.RelationshipNames, "Hermione Granger/Draco Malfoy");
        _characters = TagField("Characters", _filters.CharacterNames, "Hermione Granger");
        _freeforms = TagField("Additional tags", _filters.FreeformNames, "Slow Burn, Fluff");
        _exclude = TagField("Exclude tags", _filters.ExcludedFreeforms, "Angst, Major Character Death");
        return Group("Tags", _relationships, _characters, _freeforms, _exclude,
            UI.UI.Secondary("Separate multiple tags with commas. Use the AO3 canonical name for best results.", Theme.Style.Footnote));
    }

    private static TextBox TagField(string label, List<string> tags, string example)
    {
        var box = new TextBox
        {
            Header = label,
            PlaceholderText = example,
            Text = string.Join(", ", tags),
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetName(box, label);
        return box;
    }

    private FrameworkElement LanguageSection()
    {
        var languages = BrowseModels.Languages;
        var index = Math.Max(0, languages.ToList().FindIndex(l => l.Id == _filters.LanguageId));
        var picker = Picker("Language", languages.Select(l => l.Name), index, i => _filters.LanguageId = languages[i].Id);
        return Group("Language", picker);
    }

    private static ComboBox Picker(string header, IEnumerable<string> options, int selected, Action<int> onChange)
    {
        var box = new ComboBox { Header = header, MinWidth = 240 };
        foreach (var option in options) box.Items.Add(option);
        box.SelectedIndex = Math.Max(0, selected);
        AutomationProperties.SetName(box, header);
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) onChange(box.SelectedIndex); };
        return box;
    }

    private static int IndexOf<T>(IReadOnlyList<T> list, T value)
    {
        for (var i = 0; i < list.Count; i++)
            if (EqualityComparer<T>.Default.Equals(list[i], value)) return i;
        return 0;
    }

    // MARK: - Text fields ⇄ filters

    private void CommitText()
    {
        _filters.RelationshipNames = BrowseModels.SplitTags(_relationships.Text);
        _filters.CharacterNames = BrowseModels.SplitTags(_characters.Text);
        _filters.FreeformNames = BrowseModels.SplitTags(_freeforms.Text);
        _filters.ExcludedFreeforms = BrowseModels.SplitTags(_exclude.Text);
        _filters.WordCount = BrowseModels.BuildWordCount(_wordsFrom.Text, _wordsTo.Text);
    }

    private void Reset()
    {
        var fresh = new AO3SearchFilters { FandomNames = _filters.FandomNames };
        _filters = fresh;
        BuildForm();
        Shell.MainWindow.Current.Announce("Filters reset");
    }
}

using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Fanficly.App.Views.Search;

/// <summary>
/// The AO3-style filter panel (WorkFilterSheet): edits a copy of an
/// <see cref="AO3SearchFilters"/> — saved filters, sort, ratings, warnings,
/// categories, status, word count, tags, language and AO3's other search
/// fields. The fandom (or any other field the caller fixed) is preserved:
/// Reset and applying a saved filter keep it. Returns the edited filters on
/// Apply, or null when cancelled (Esc / Cancel).
/// </summary>
/// <remarks>Browse's filtered works can reuse it: <c>await WorkFilterSheet.ShowAsync(filters)</c>.</remarks>
public static class WorkFilterSheet
{
    public static async Task<AO3SearchFilters?> ShowAsync(AO3SearchFilters filters)
    {
        var editor = new FilterEditor(filters.Clone());
        var dialog = new ContentDialog
        {
            Title = "Filters",
            Content = editor.Root,
            PrimaryButtonText = "Apply",
            SecondaryButtonText = "Reset",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var reset = new Style(typeof(Button));
        reset.Setters.Add(new Setter(Control.ForegroundProperty, Theme.Danger));
        dialog.SecondaryButtonStyle = reset;
        // Reset clears the panel and keeps it open.
        dialog.SecondaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            editor.Reset();
            Shell.MainWindow.Current.Announce("Filters reset");
        };
        dialog.Resources["ContentDialogMaxWidth"] = 640.0;
        dialog.Resources["ContentDialogMinWidth"] = 320.0;
        dialog.Resources["ContentDialogMaxHeight"] = 900.0;
        AutomationProperties.SetAutomationId(dialog, "filters.sheet");
        var result = await Dialogs.ShowAsync(dialog);
        if (result != ContentDialogResult.Primary) return null;
        editor.CommitText();
        return editor.Filters;
    }

    /// <summary>The sheet's state and controls.</summary>
    private sealed class FilterEditor
    {
        public AO3SearchFilters Filters { get; private set; }
        public ScrollViewer Root { get; }
        private readonly Border _host = new();

        // Editable text mirrors for the comma-separated tag fields.
        private string _relationships = "", _characters = "", _freeforms = "", _exclude = "";
        private string _wordsFrom = "", _wordsTo = "";

        private static readonly (string Code, string Name)[] Languages =
        [
            ("", "Any"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
            ("zh", "Chinese"), ("ru", "Russian"), ("pt", "Portuguese"), ("it", "Italian"),
            ("ja", "Japanese"), ("ko", "Korean"),
        ];

        public FilterEditor(AO3SearchFilters filters)
        {
            Filters = filters;
            SeedText();
            Root = new ScrollViewer
            {
                Content = _host,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollMode = ScrollMode.Disabled,
                Padding = new Thickness(0, 0, 12, 0),
            };
            _host.Child = Build();
        }

        private void Rebuild() => _host.Child = Build();

        private StackPanel Build()
        {
            var stack = UI.UI.VStack(14,
                SavedFiltersSection(),
                SortSection(),
                UI.UI.Section("Rating", SearchEnums.AllRatings.Select(r => (UIElement)Check(r.DisplayName(), Filters.Ratings, r))),
                UI.UI.Section("Archive warnings", SearchEnums.AllWarnings.Select(w => (UIElement)Check(w.DisplayName(), Filters.Warnings, w))),
                UI.UI.Section("Category", SearchEnums.AllCategories.Select(c => (UIElement)Check(c.DisplayName(), Filters.Categories, c))),
                StatusSection(),
                WordCountSection(),
                TagsSection(),
                LanguageSection(),
                MoreSection());
            stack.Padding = new Thickness(0, 0, 0, 8);
            XYFocus(stack);
            return stack;
        }

        private static void XYFocus(UIElement e) => e.XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Enabled;

        // MARK: - Saved filters

        private StackPanel SavedFiltersSection()
        {
            var store = AppHost.Library;
            var rows = new List<UIElement>();
            foreach (var saved in store.All<SavedFilter>().OrderByDescending(s => s.SavedAt))
            {
                var open = new Button
                {
                    Content = UI.UI.Label("line.3.horizontal.decrease.circle", saved.Name, maxLines: UI.UI.LineLimit(1)),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Background = Theme.Transparent,
                    BorderBrush = Theme.Transparent,
                    Padding = new Thickness(14, 10, 8, 10),
                    CornerRadius = new CornerRadius(0),
                };
                AutomationProperties.SetName(open, saved.Name);
                AutomationProperties.SetHelpText(open, "Applies this saved filter");
                open.Click += (_, _) => ApplySaved(saved);
                void Delete()
                {
                    LibrarySyncManager.RecordDeletionShared(DeletionKind.Filter, saved.Name);
                    store.Delete(saved);
                    store.TrySave();
                    Shell.MainWindow.Current.Announce($"Deleted {saved.Name}");
                    Rebuild();
                }
                var delete = UI.UI.IconButton("trash", $"Delete {saved.Name}", Delete, 14);
                var row = UI.UI.Grid("*,Auto");
                row.Children.Add(open.Col(0));
                row.Children.Add(delete.Margin(0, 0, 6, 0).Also(d => d.VerticalAlignment = VerticalAlignment.Center).Col(1));
                row.ContextFlyout = UI.UI.Menu(UI.UI.MenuItem("Delete", Delete, "trash", isDestructive: true));
                open.KeyDown += (_, e) => { if (e.Key == VirtualKey.Delete) { e.Handled = true; Delete(); } };
                rows.Add(row);
            }

            var save = new Button
            {
                Content = UI.UI.Label("plus.circle", "Save current filters…", foreground: Theme.Accent, maxLines: UI.UI.LineLimit(1)),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = Theme.Transparent,
                BorderBrush = Theme.Transparent,
                Padding = new Thickness(14, 10, 14, 10),
                CornerRadius = new CornerRadius(0),
            };
            AutomationProperties.SetName(save, "Save current filters");
            AutomationProperties.SetAutomationId(save, "filters.save");
            save.Click += (_, _) => ShowSaveFlyout(save);
            rows.Add(save);
            return UI.UI.Section("Saved filters", rows);
        }

        private void ApplySaved(SavedFilter saved)
        {
            if (AO3SearchFilters.FromSavedJson(saved.FiltersJson) is not { } loaded) return;
            Filters = Filters.ApplyingSaved(loaded); // keeps the fandom and search tags
            SeedText();
            Rebuild();
            Shell.MainWindow.Current.Announce($"Applied {saved.Name}");
        }

        /// <summary>Names what the saved filter leaves out, so a fandom picked as
        /// a search tag isn't saved by surprise (#157).</summary>
        private static string SaveFlyoutMessage(AO3SearchFilters filters)
        {
            const string intro = "Saves these filters (rating, tags, status, etc.) so you can apply them to any fandom later.";
            var unsaved = filters.UnsavedTagNames;
            return unsaved.Count == 0
                ? intro + " The fandom itself isn't saved."
                : intro + $" The fandom and the tags picked in Search aren't saved: {string.Join(", ", unsaved)}.";
        }

        /// <summary>The "Save filter" alert, as a flyout on the button (a dialog
        /// can't open over this one).</summary>
        private void ShowSaveFlyout(Button anchor)
        {
            CommitText();
            var name = new TextBox { PlaceholderText = "Name", Text = Filters.SuggestedName(), MinWidth = 280 };
            AutomationProperties.SetName(name, "Name");
            var flyout = new Flyout();
            var saveButton = UI.UI.Button("Save", () => { }, kind: UI.UI.ButtonKind.Accent);
            void Save()
            {
                var trimmed = name.Text.Trim();
                if (trimmed.Length == 0) return;
                var json = Filters.SavedJson();
                var store = AppHost.Library;
                if (store.GetSavedFilter(trimmed) is { } existing)
                {
                    existing.FiltersJson = json;
                    existing.SavedAt = DateTimeOffset.Now;
                }
                else
                {
                    store.Insert(new SavedFilter(trimmed, json));
                }
                store.TrySave();
                flyout.Hide();
                Shell.MainWindow.Current.Announce($"Saved filter {trimmed}");
                Rebuild();
            }
            saveButton.Click += (_, _) => Save();
            saveButton.IsEnabled = name.Text.Trim().Length > 0;
            name.TextChanged += (_, _) => saveButton.IsEnabled = name.Text.Trim().Length > 0;
            name.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; Save(); } };
            var buttons = UI.UI.HStack(8, saveButton, UI.UI.Button("Cancel", () => flyout.Hide()));
            buttons.HorizontalAlignment = HorizontalAlignment.Right;
            flyout.Content = UI.UI.VStack(10,
                UI.UI.Text("Save filter", Theme.Style.Headline),
                UI.UI.Secondary(SaveFlyoutMessage(Filters), Theme.Style.Footnote)
                    .Also(t => t.MaxWidth = 320),
                name,
                buttons);
            flyout.Opened += (_, _) => { name.Focus(FocusState.Programmatic); name.SelectAll(); };
            flyout.ShowAt(anchor);
        }

        // MARK: - Sections

        private StackPanel SortSection() => UI.UI.Section("Sort",
        [
            Picker("Sort by", SearchEnums.AllSortColumns.Select(c => (c, c.DisplayName())).ToList(), Filters.SortColumn, v => Filters.SortColumn = v),
            Picker("Direction", new[] { SortDirection.Asc, SortDirection.Desc }.Select(d => (d, d.DisplayName())).ToList(), Filters.SortDirection, v => Filters.SortDirection = v),
        ]);

        private StackPanel StatusSection()
        {
            var oneShot = UI.UI.Toggle(Filters.SingleChapter, on => Filters.SingleChapter = on, "Single chapter / oneshot");
            return UI.UI.Section("Status",
            [
                Picker("Completion", [(TriState.Any, "Any"), (TriState.Yes, "Complete only"), (TriState.No, "Work in progress")],
                    Filters.Complete, v => Filters.Complete = v),
                Picker("Crossovers", [(TriState.Any, "Include"), (TriState.Yes, "Only crossovers"), (TriState.No, "Exclude crossovers")],
                    Filters.Crossover, v => Filters.Crossover = v),
                UI.UI.SettingsRow("Single chapter / oneshot", oneShot),
            ]);
        }

        private StackPanel WordCountSection()
        {
            var from = NumberField("From", _wordsFrom, v => _wordsFrom = v);
            var to = NumberField("To", _wordsTo, v => _wordsTo = v);
            var row = UI.UI.Grid("*,Auto,*", columnSpacing: 10);
            row.Padding = new Thickness(14, 10, 14, 10);
            row.Children.Add(from.Col(0));
            row.Children.Add(UI.UI.Secondary("–", Theme.Style.Body).Also(t => t.VerticalAlignment = VerticalAlignment.Center).A11yHidden().Col(1));
            row.Children.Add(to.Col(2));
            return UI.UI.Section("Word count", [row]);
        }

        private StackPanel TagsSection() => UI.UI.Section("Tags",
        [
            TagField("Relationships", "Hermione Granger/Draco Malfoy", _relationships, v => _relationships = v),
            TagField("Characters", "Hermione Granger", _characters, v => _characters = v),
            TagField("Additional tags", "Slow Burn, Fluff", _freeforms, v => _freeforms = v),
            TagField("Exclude tags", "Angst, Major Character Death", _exclude, v => _exclude = v),
        ], footer: "Separate multiple tags with commas. Use the AO3 canonical name for best results.");

        private StackPanel LanguageSection()
        {
            var options = Languages.Select(l => (l.Code, l.Name)).ToList();
            // A language set some other way (a lang: token) stays selectable.
            if (Filters.LanguageId.Length > 0 && !options.Any(o => o.Code == Filters.LanguageId))
                options.Add((Filters.LanguageId,
                    SearchSyntax.LanguageNames.TryGetValue(Filters.LanguageId, out var n) ? n : Filters.LanguageId));
            return UI.UI.Section("Language", [Picker("Language", options, Filters.LanguageId, v => Filters.LanguageId = v)]);
        }

        /// <summary>AO3's remaining search-form fields (title, creator, date
        /// updated and the stat ranges), which the search box's <c>key:value</c>
        /// tokens and chips also cover.</summary>
        private StackPanel MoreSection() => UI.UI.Section("More",
        [
            TextField("Title", "The Long Way Home", Filters.Title, v => Filters.Title = v),
            TextField("Creator", "astolat", Filters.Creators, v => Filters.Creators = v),
            TextField("Date updated", "< 2 weeks", Filters.RevisedAt, v => Filters.RevisedAt = v),
            TextField("Kudos", "> 100", Filters.KudosCount, v => Filters.KudosCount = v),
            TextField("Hits", "1000-5000", Filters.Hits, v => Filters.Hits = v),
            TextField("Comments", "> 10", Filters.CommentsCount, v => Filters.CommentsCount = v),
            TextField("Bookmarks", "> 50", Filters.BookmarksCount, v => Filters.BookmarksCount = v),
        ], footer: "Counts take AO3's ranges: \"> 100\", \"< 50\" or \"100-500\". Date updated takes ranges like \"< 2 weeks\" or \"> 1 year\".");

        // MARK: - Controls

        private static CheckBox Check<T>(string title, HashSet<T> set, T element) where T : struct
        {
            var box = new CheckBox
            {
                Content = title,
                IsChecked = set.Contains(element),
                Margin = new Thickness(14, 4, 14, 4),
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            box.Checked += (_, _) => set.Add(element);
            box.Unchecked += (_, _) => set.Remove(element);
            return box;
        }

        private static Grid Picker<T>(string label, IReadOnlyList<(T Value, string Title)> options, T current, Action<T> set)
        {
            var combo = new ComboBox { MinWidth = 200 };
            foreach (var (_, title) in options) combo.Items.Add(new ComboBoxItem { Content = title });
            var index = -1;
            for (var i = 0; i < options.Count; i++)
                if (EqualityComparer<T>.Default.Equals(options[i].Value, current)) { index = i; break; }
            combo.SelectedIndex = index;
            AutomationProperties.SetName(combo, label);
            combo.SelectionChanged += (_, _) =>
            {
                if (combo.SelectedIndex >= 0 && combo.SelectedIndex < options.Count) set(options[combo.SelectedIndex].Value);
            };
            return UI.UI.SettingsRow(label, combo);
        }

        private static TextBox NumberField(string placeholder, string text, Action<string> changed)
        {
            var box = new TextBox
            {
                PlaceholderText = placeholder,
                Text = text,
                InputScope = new Microsoft.UI.Xaml.Input.InputScope { Names = { new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number) } },
            };
            AutomationProperties.SetName(box, $"Word count {placeholder.ToLowerInvariant()}");
            box.BeforeTextChanging += (_, a) => { if (a.NewText.Any(c => !char.IsAsciiDigit(c))) a.Cancel = true; };
            box.TextChanged += (_, _) => changed(box.Text);
            return box;
        }

        private static StackPanel TagField(string label, string example, string text, Action<string> changed)
        {
            var box = new TextBox
            {
                PlaceholderText = example,
                Text = text,
                TextWrapping = TextWrapping.Wrap,
                AcceptsReturn = false,
                IsSpellCheckEnabled = false,
            };
            AutomationProperties.SetName(box, label);
            box.TextChanged += (_, _) => changed(box.Text);
            var stack = UI.UI.VStack(4, UI.UI.Caption(label).A11yHidden(), box);
            stack.Padding = new Thickness(14, 8, 14, 10);
            return stack;
        }

        private static StackPanel TextField(string label, string example, string text, Action<string> changed)
        {
            var box = new TextBox { PlaceholderText = example, Text = text, IsSpellCheckEnabled = false };
            AutomationProperties.SetName(box, label);
            box.TextChanged += (_, _) => changed(box.Text.Trim());
            var stack = UI.UI.VStack(4, UI.UI.Caption(label).A11yHidden(), box);
            stack.Padding = new Thickness(14, 8, 14, 10);
            return stack;
        }

        // MARK: - Text fields ⇄ filters

        private void SeedText()
        {
            _relationships = string.Join(", ", Filters.RelationshipNames);
            _characters = string.Join(", ", Filters.CharacterNames);
            _freeforms = string.Join(", ", Filters.FreeformNames);
            _exclude = string.Join(", ", Filters.ExcludedFreeforms);
            // Parse an existing "from-to" / ">n" / "<n" word count back into fields.
            var wc = Filters.WordCount;
            _wordsFrom = "";
            _wordsTo = "";
            if (wc.Contains('-'))
            {
                var parts = wc.Split('-', StringSplitOptions.RemoveEmptyEntries);
                _wordsFrom = parts.Length > 0 ? parts[0] : "";
                _wordsTo = parts.Length > 1 ? parts[1] : "";
            }
            else if (wc.StartsWith('>')) _wordsFrom = wc[1..];
            else if (wc.StartsWith('<')) _wordsTo = wc[1..];
            else if (wc.Length > 0 && wc.All(char.IsAsciiDigit)) { _wordsFrom = wc; _wordsTo = wc; } // an exact count
        }

        public void CommitText()
        {
            Filters.RelationshipNames = SplitTags(_relationships);
            Filters.CharacterNames = SplitTags(_characters);
            Filters.FreeformNames = SplitTags(_freeforms);
            Filters.ExcludedFreeforms = SplitTags(_exclude);
            Filters.WordCount = BuildWordCount();
        }

        private static List<string> SplitTags(string s) =>
            s.Split(',').Select(t => t.Trim()).Where(t => t.Length > 0).ToList();

        private string BuildWordCount()
        {
            var from = _wordsFrom.Trim();
            var to = _wordsTo.Trim();
            return (from.Length == 0, to.Length == 0) switch
            {
                (false, false) => $"{from}-{to}",
                (false, true) => $">{from}",
                (true, false) => $"<{to}",
                _ => "",
            };
        }

        public void Reset()
        {
            var fresh = new AO3SearchFilters { FandomNames = [.. Filters.FandomNames] };
            Filters = fresh;
            SeedText();
            Rebuild();
        }
    }
}

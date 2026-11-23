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
/// fields. Browse fixes the fandom, so the sheet keeps it (Reset and applying a
/// saved filter too); Search passes <c>editsFandom</c> and gets a Fandom section
/// to pick fandoms from AO3's list (the Swift <c>FandomPickerSection</c>), which
/// Reset clears. Returns the edited filters on Apply, or null when cancelled
/// (Esc / Cancel).
/// </summary>
/// <remarks>Browse's filtered works can reuse it: <c>await WorkFilterSheet.ShowAsync(filters)</c>.</remarks>
public static class WorkFilterSheet
{
    public static async Task<AO3SearchFilters?> ShowAsync(AO3SearchFilters filters, bool editsFandom = false)
    {
        var editor = new FilterEditor(filters.Clone(), editsFandom);
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
        editor.StopLookups();
        if (result != ContentDialogResult.Primary) return null;
        editor.CommitText();
        editor.CommitPendingFandom();
        return editor.Filters;
    }

    /// <summary>The sheet's state and controls.</summary>
    private sealed class FilterEditor
    {
        public AO3SearchFilters Filters { get; private set; }
        public ScrollViewer Root { get; }
        private readonly Border _host = new();
        private readonly bool _editsFandom;
        private FandomPicker? _fandomPicker;
        /// <summary>The fandom box's text, owned here (Swift's <c>fandomTerm</c>) so a
        /// rebuild (applying or saving a filter) keeps it; only Reset clears it.</summary>
        private string _fandomTerm = "";

        // Editable text mirrors for the comma-separated tag fields.
        private string _relationships = "", _characters = "", _freeforms = "", _exclude = "";
        private string _wordsFrom = "", _wordsTo = "";

        private static readonly (string Code, string Name)[] Languages =
        [
            ("", "Any"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
            ("zh", "Chinese"), ("ru", "Russian"), ("pt", "Portuguese"), ("it", "Italian"),
            ("ja", "Japanese"), ("ko", "Korean"),
        ];

        public FilterEditor(AO3SearchFilters filters, bool editsFandom)
        {
            Filters = filters;
            _editsFandom = editsFandom;
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
            _fandomPicker?.Stop();
            _fandomPicker = _editsFandom ? new FandomPicker(Filters, _fandomTerm, t => _fandomTerm = t) : null;
            var stack = UI.UI.VStack(14,
                _fandomPicker?.Root,
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
            return filters.OtherTagNames.Count == 0
                ? intro + " The fandom itself isn't saved."
                : intro + $" The fandom and the tags picked in Search aren't saved: {string.Join(", ", filters.OtherTagNames)}.";
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

        /// <summary>Apply adds words left in the fandom box, as Enter would, so a
        /// typed fandom isn't silently dropped (Swift's <c>committedDraft</c>).
        /// Only on Apply: saving a filter doesn't store the fandom.</summary>
        public void CommitPendingFandom() =>
            Filters.FandomNames = SearchSuggestions.AddingFandom(_fandomTerm, Filters.FandomNames);

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

        public void StopLookups() => _fandomPicker?.Stop();

        public void Reset()
        {
            var fresh = _editsFandom ? new AO3SearchFilters() : new AO3SearchFilters { FandomNames = [.. Filters.FandomNames] };
            _fandomTerm = "";
            Filters = fresh;
            SeedText();
            Rebuild();
        }
    }

    /// <summary>The Fandom section (Search only; Swift's <c>FandomPickerSection</c>):
    /// pick fandoms from AO3's own list instead of having to know a fandom's exact
    /// name. Typing asks AO3's fandom autocomplete (debounced 350 ms, one throttled
    /// request, memoized in <see cref="TagSuggestionCache"/> under
    /// <c>fandom:&lt;term&gt;</c>); an empty field offers the popular fandoms. Only a
    /// clicked row, Enter, or Apply with words left in the box adds a fandom (typed
    /// words go through <see cref="TagResolver"/> on search): nothing is guessed
    /// from the search box. Picked fandoms go in <c>work_search[fandom_names]</c>, so a work
    /// must be in every one. Rows update in place, so the box keeps focus.</summary>
    private sealed class FandomPicker
    {
        private readonly AO3SearchFilters _filters;
        private readonly StackPanel _picked = new() { Spacing = 0 };
        private readonly StackPanel _rows = new() { Spacing = 0 };
        private readonly TextBox _box;
        private readonly ProgressRing _ring = new() { IsActive = false, Width = 16, Height = 16, Visibility = Visibility.Collapsed };
        private readonly TextBlock _footer;
        private IReadOnlyList<string> _matches = [];
        private bool _looking, _lookupFailed;
        private CancellationTokenSource? _lookup;
        /// <summary>Read once: the live Popular snapshot, else the curated seed.</summary>
        private readonly IReadOnlyList<string> _popular =
            PopularStore.Cached()?.Fandoms is { Count: > 0 } live ? live : PopularTags.Fandoms;
        public StackPanel Root { get; }

        public FandomPicker(AO3SearchFilters filters, string term, Action<string> termChanged)
        {
            _filters = filters;
            _box = new TextBox { IsSpellCheckEnabled = false, MinWidth = 200, Text = term };
            AutomationProperties.SetName(_box, "Fandom");
            AutomationProperties.SetAutomationId(_box, "filters.fandom.field");
            _box.TextChanged += (_, _) => { termChanged(_box.Text); StartLookup(); };
            _box.KeyDown += (_, e) =>
            {
                // An empty box leaves Enter to the dialog's default button (Apply).
                if (e.Key != VirtualKey.Enter || Term.Length == 0) return;
                e.Handled = true;
                Pick(_box.Text, fromAO3: false);
            };
            var field = UI.UI.Grid("Auto,*,Auto", columnSpacing: 8);
            field.Padding = new Thickness(14, 8, 14, 8);
            field.Children.Add(UI.UI.Icon("magnifyingglass", 14, Theme.TextSecondary).A11yHidden()
                .Also(i => i.VerticalAlignment = VerticalAlignment.Center).Col(0));
            field.Children.Add(_box.Col(1));
            field.Children.Add(_ring.Also(r => r.VerticalAlignment = VerticalAlignment.Center).Col(2));
            var body = UI.UI.VStack(0, _picked, field, _rows);
            Root = UI.UI.Section("Fandom", [body]);
            _footer = UI.UI.Secondary("", Theme.Style.Footnote).Also(t => t.Margin = new Thickness(4, 4, 4, 0));
            Root.Children.Add(_footer);
            // A term kept across a rebuild looks its matches up again (cached).
            if (Term.Length > 0) StartLookup(); else Render();
        }

        private string Term => _box.Text.Trim();

        public void Stop() => _lookup?.Cancel();



        private void Render()
        {
            _box.PlaceholderText = _filters.FandomNames.Count == 0 ? "Search for a fandom" : "Add another fandom";
            _picked.Children.Clear();
            foreach (var name in _filters.FandomNames.ToList())
            {
                var row = UI.UI.Grid("*,Auto", columnSpacing: 8);
                row.Padding = new Thickness(14, 6, 6, 6);
                row.Children.Add(UI.UI.Label("checkmark.circle.fill", name, foreground: Theme.Accent, maxLines: UI.UI.LineLimit(2))
                    .Also(l => l.VerticalAlignment = VerticalAlignment.Center).Col(0));
                var remove = UI.UI.IconButton("xmark.circle.fill", $"Remove {name}", () => Remove(name), 14);
                row.Children.Add(remove.Also(b => b.VerticalAlignment = VerticalAlignment.Center).Col(1));
                _picked.Children.Add(row);
            }
            // A row with keyboard focus is about to go: keep focus in the section.
            var rowHadFocus = _box.XamlRoot is { } root
                && FocusManager.GetFocusedElement(root) is DependencyObject focused
                && _rows.Children.Contains(focused as UIElement);
            _rows.Children.Clear();
            foreach (var name in Rows())
            {
                var add = new Button
                {
                    Content = UI.UI.Label("plus.circle", name, maxLines: UI.UI.LineLimit(2)),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Background = Theme.Transparent,
                    BorderBrush = Theme.Transparent,
                    Padding = new Thickness(14, 8, 14, 8),
                    CornerRadius = new CornerRadius(0),
                };
                AutomationProperties.SetName(add, $"Add fandom: {name}");
                var picked = name;
                // Only AO3's own answers are known canonical; the curated names
                // still go through TagResolver.
                add.Click += (_, _) => Pick(picked, fromAO3: _matches.Contains(picked));
                _rows.Children.Add(add);
            }
            _footer.Text = Footer();
            if (rowHadFocus) _box.Focus(FocusState.Keyboard);
        }

        /// <summary>Matches while typing; popular fandoms when the box is empty.</summary>
        private IReadOnlyList<string> Rows()
        {
            if (Term.Length == 0)
            {
                return SearchSuggestions.PopularFandomPicks(_popular, _filters.FandomNames, _filters.FandomNames.Count == 0 ? 6 : 0);
            }
            return SearchSuggestions.FandomPicks(Term, _matches, _filters.FandomNames);
        }

        private string Footer()
        {
            if (_filters.FandomNames.Count == 0 && Term.Length == 0)
                return "Popular fandoms are shown. Type to search AO3's list of fandoms.";
            if (Term.Length > 0 && _rows.Children.Count == 0)
            {
                if (_lookupFailed) return "Couldn't reach AO3's fandom list. Press Enter to use what you typed.";
                if (_looking) return "Looking up fandoms on AO3…";
                return new System.Globalization.StringInfo(Term).LengthInTextElements < 2
                    ? "Keep typing to search AO3's list of fandoms."
                    : "No AO3 fandom matches. Press Enter to use what you typed.";
            }
            return "Works must be tagged with every fandom you pick.";
        }

        /// <param name="fromAO3">A row from AO3's list (or the curated popular names),
        /// so already canonical; typed words still go through <see cref="TagResolver"/>.</param>
        private void Pick(string name, bool fromAO3)
        {
            var updated = SearchSuggestions.AddingFandom(name, _filters.FandomNames);
            if (updated.Count == _filters.FandomNames.Count) return;
            if (fromAO3) TagResolver.NoteCanonical(name.Trim(), AO3AutocompleteField.Fandom);
            _filters.FandomNames = updated;
            _matches = [];
            _box.Text = ""; // raises TextChanged → StartLookup → Render
            Render();
            Shell.MainWindow.Current.Announce($"Added fandom: {name.Trim()}");
            _box.Focus(FocusState.Programmatic);
        }

        private void Remove(string name)
        {
            _filters.FandomNames = _filters.FandomNames.Where(f => f != name).ToList();
            Render();
            Shell.MainWindow.Current.Announce($"Removed fandom: {name}");
            _box.Focus(FocusState.Programmatic);
        }

        /// <summary>Debounced lookup; restarts (cancelling the last) on every edit.</summary>
        private void StartLookup()
        {
            _lookup?.Cancel();
            _lookup = new CancellationTokenSource();
            _matches = [];
            _lookupFailed = false;
            var phrase = Term;
            SetLooking(new System.Globalization.StringInfo(phrase).LengthInTextElements >= 2);
            Render();
            if (_looking) _ = LookUpAsync(phrase, _lookup.Token);
        }

        private async Task LookUpAsync(string phrase, CancellationToken ct)
        {
            // Wait for a pause in typing: every lookup is a throttled AO3 request.
            try { await Task.Delay(350, ct); }
            catch (OperationCanceledException) { return; }
            var key = "fandom:" + phrase;
            IReadOnlyList<string> names;
            if (TagSuggestionCache.Shared.Value(key) is { } cached)
            {
                names = cached;
            }
            else
            {
                try { names = await AppHost.Client.AutocompleteAsync(AO3AutocompleteField.Fandom, phrase, ct); }
                catch
                {
                    if (!ct.IsCancellationRequested)
                    {
                        _lookupFailed = true;
                        SetLooking(false);
                        Render();
                        Shell.MainWindow.Current.Announce("Couldn't reach AO3's fandom list");
                    }
                    return;
                }
                TagSuggestionCache.Shared.Set(names, key);
            }
            if (ct.IsCancellationRequested) return;
            _matches = names;
            SetLooking(false);
            Render();
        }

        private void SetLooking(bool on)
        {
            _looking = on;
            _ring.IsActive = on;
            _ring.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        }
    }
}

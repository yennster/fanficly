using System.Globalization;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Fanficly.App.Views.Reader;

/// <summary>The reader's controls: its top bar (the Mac reader's toolbar, painted
/// with the page background), the floating chapter indicator, the page footer,
/// the Listen bar, and the chapters and Aa menus with reader profiles.</summary>
internal sealed partial class ReaderView
{
    private Grid _header = null!;
    private TextBlock _headerTitle = null!;
    private TextBlock _headerChapter = null!;
    private Button _backButton = null!;
    private Button _chaptersButton = null!;
    private Button _aaButton = null!;
    private Button _fullScreenButton = null!;
    private readonly StackPanel _trailing = new() { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };

    private Border _indicator = null!;
    private TextBlock _indicatorLabel = null!;
    private TextBlock _indicatorCount = null!;

    private RegionGrid? _footer;
    private TextBlock? _footerLabel;
    private TextBlock? _footerPages;

    private RegionGrid? _narrationBar;
    private FontIcon? _playIcon;
    private Button? _playButton;
    private Button? _narrationStatus;
    private TextBlock? _narrationChapter;
    private TextBlock? _narrationPosition;
    private Button? _rateButton;
    private TextBlock? _rateText;

    private static readonly double[] SpeakingRates = [0.5, 0.8, 1.0, 1.2, 1.5, 1.8, 2.0];

    /// <summary>The parent screen's toolbar items, after the reader's own (Swift:
    /// the parent's <c>.toolbar</c>). Kept to two, like the Swift parents.</summary>
    public void SetTrailingItems(params UIElement[] items)
    {
        _trailing.Children.Clear();
        foreach (var item in items) _trailing.Children.Add(item);
    }

    /// <summary>A bar button in the reader's colours, for the parent's toolbar items.</summary>
    public Button ToolbarButton(string sfSymbol, string label, Action? onClick = null) => _brushes.IconButton(sfSymbol, label, onClick);

    /// <summary>Styles a parent's button like the reader's own.</summary>
    public void StyleToolbarButton(Button button) => _brushes.StyleFlat(button);

    // MARK: - Top bar

    private void BuildHeader()
    {
        _backButton = _brushes.IconButton("chevron.left", "Back", () => MainWindow.Current.GoBack());
        AutomationProperties.SetAutomationId(_backButton, "reader.back");

        _headerTitle = new TextBlock
        {
            Text = _title,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            Foreground = _brushes.Foreground,
        };
        AutomationProperties.SetHeadingLevel(_headerTitle, AutomationHeadingLevel.Level1);
        _headerChapter = new TextBlock
        {
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            Foreground = _brushes.Fg60,
        };
        AutomationProperties.SetAutomationId(_headerChapter, "reader.chapterTitle");
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0), Children = { _headerTitle, _headerChapter } };

        _chaptersButton = _brushes.IconButton("list.bullet", "Chapters");
        AutomationProperties.SetAutomationId(_chaptersButton, "reader.chapters");
        _chaptersButton.Flyout = BuildChaptersMenu();

        _aaButton = _brushes.IconButton("textformat", "Reader settings");
        AutomationProperties.SetAutomationId(_aaButton, "reader.aa");
        _aaButton.Flyout = BuildTypographyMenu();

        _fullScreenButton = _brushes.IconButton("arrow.up.left.and.arrow.down.right", "Full screen", ToggleFullScreen);
        AutomationProperties.SetAutomationId(_fullScreenButton, "reader.fullscreen");
        // Full screen hides every visible way back; Esc, F11, the middle of the
        // page and the reading area's context menu bring the controls back.
        AutomationProperties.SetHelpText(_fullScreenButton,
            "Hides the toolbar and the window's sidebar. To bring them back, press Escape or use Show Reader Controls in the story's context menu.");

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _chaptersButton, _aaButton, _fullScreenButton, _trailing },
        };

        _header = UI.UI.Grid("Auto,*,Auto");
        _header.Padding = new Thickness(8, 4, 8, 4);
        _header.MinHeight = 48;
        _header.Background = _brushes.Background;
        _header.BorderBrush = _brushes.Fg10;
        _header.BorderThickness = new Thickness(0, 0, 0, 1);
        _header.Children.Add(_backButton.Col(0));
        _header.Children.Add(titles.Col(1));
        _header.Children.Add(buttons.Col(2));
    }

    /// <summary>Shows or hides the reader's bars for the current state. Called
    /// whenever the mode, the controls, full screen or Listen change.</summary>
    private void RefreshChrome()
    {
        var controlsUp = !_isUIMinimized;
        _header.Visibility = controlsUp ? Visibility.Visible : Visibility.Collapsed;
        _backButton.Visibility = _immersive && MainWindow.Current.Navigator.CanGoBack ? Visibility.Visible : Visibility.Collapsed;
        _chaptersButton.Visibility = _chapters.Count > 1 ? Visibility.Visible : Visibility.Collapsed;

        var fullScreen = MainWindow.Current.IsFullScreen;
        var label = fullScreen ? "Exit full screen" : "Full screen";
        _fullScreenButton.Content = Symbols.Icon(fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", 16).A11yHidden();
        AutomationProperties.SetName(_fullScreenButton, label);
        ToolTipService.SetToolTip(_fullScreenButton, $"{label} (F11)");

        _indicator.Visibility = _bodyBuilt && _builtMode == ReadingMode.Continuous && _chapters.Count > 1 && controlsUp
            ? Visibility.Visible : Visibility.Collapsed;

        // The bottom bar: the Listen controls while narrating, else page-by-page's
        // footer (which goes with the other controls in full screen).
        UIElement? bottom = null;
        if (_speech.IsActive) bottom = NarrationBar();
        else if (_bodyBuilt && _builtMode == ReadingMode.PageByPage && controlsUp) bottom = Footer();
        if (_bottomHost.Children.Count != (bottom is null ? 0 : 1) || (bottom is not null && _bottomHost.Children[0] != bottom))
        {
            _bottomHost.Children.Clear();
            if (bottom is not null) _bottomHost.Children.Add(bottom);
        }
        UpdatePaginatedPips();
        UpdateHeaderChapter();
        UpdateNarrationBar();
    }

    private static string ChapterIndicatorLabel(AO3ChapterPayload? chapter, int index, int count) =>
        chapter is { Title.Length: > 0 } ? $"Chapter {index} · {chapter.Title}" : $"Chapter {index} of {count}";

    /// <summary>The chapter being read, in the top bar, the indicator and the footer.</summary>
    private void UpdateHeaderChapter()
    {
        var index = EffectiveChapter;
        var chapter = ChapterAt(index);
        string subtitle;
        if (_chapters.Count > 1) subtitle = ChapterIndicatorLabel(chapter, index, _chapters.Count);
        else subtitle = chapter?.Title ?? "";
        _headerChapter.Text = subtitle;
        _headerChapter.Visibility = subtitle.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        UpdateIndicator();
        UpdateFooter();
    }

    // MARK: - Chapter indicator (continuous scroll)

    private void BuildIndicator()
    {
        _indicatorLabel = new TextBlock
        {
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            Foreground = _brushes.Fg85,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _indicatorCount = new TextBlock { FontSize = 11, FontWeight = FontWeights.Medium, Foreground = _brushes.Fg50, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(_indicatorCount, AccessibilityView.Raw);
        AutomationProperties.SetAutomationId(_indicatorLabel, "reader.chapterIndicator");
        var row = UI.UI.Grid("*,Auto", columnSpacing: 12);
        row.Children.Add(_indicatorLabel.Col(0));
        row.Children.Add(_indicatorCount.Col(1));
        _indicator = new Border
        {
            Child = row,
            Padding = new Thickness(16, 7, 16, 7),
            Background = _brushes.Background,
            BorderBrush = _brushes.Fg10,
            BorderThickness = new Thickness(0, 0, 0, 1),
            Visibility = Visibility.Collapsed,
        };
    }

    private void UpdateIndicator()
    {
        if (_indicatorLabel is null) return;
        var index = _visibleChapter;
        var label = ChapterIndicatorLabel(ChapterAt(index), index, _chapters.Count);
        _indicatorLabel.Text = label;
        _indicatorCount.Text = $"{index}/{_chapters.Count}";
        AutomationProperties.SetName(_indicatorLabel, $"{label}, chapter {index} of {_chapters.Count}");
    }

    // MARK: - Page footer (page-by-page)

    private RegionGrid Footer()
    {
        if (_footer is not null) return _footer;
        _footerLabel = new TextBlock
        {
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            Foreground = _brushes.Fg85,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _footerPages = new TextBlock { FontSize = 11, FontWeight = FontWeights.Medium, Foreground = _brushes.Fg50, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(_footerLabel, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_footerPages, AccessibilityView.Raw);
        _footer = new RegionGrid("reader.pageFooter")
        {
            Padding = new Thickness(16, 7, 16, 7),
            ColumnSpacing = 12,
            Background = _brushes.Background,
            BorderBrush = _brushes.Fg10,
            BorderThickness = new Thickness(0, 1, 0, 0),
        };
        _footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _footer.Children.Add(_footerLabel.Col(0));
        _footer.Children.Add(_footerPages.Col(1));
        UpdateFooter();
        return _footer;
    }

    private void UpdateFooter()
    {
        if (_footer is null || _footerLabel is null || _footerPages is null) return;
        var current = _pages.FirstOrDefault(p => p.Id == _selectedPageId);
        if (current is null)
        {
            // Keep the bar's height while pages are laid out, or its arrival
            // would change the page area and lay them out again.
            _footerLabel.Text = " ";
            _footerPages.Text = "";
            AutomationProperties.SetName(_footer, "Laying out pages");
            return;
        }
        var total = _pages.Count(p => p.ChapterIndex == current.ChapterIndex);
        // A spread shows two pages: "Pages 3–4 of 12".
        var onScreen = _spreadLayout is null ? null : ReaderSpread.Spreads(_pages).FirstOrDefault(s => s.Contains(_selectedPageId));
        var first = (onScreen?.Left ?? current).PageIndex + 1;
        var pageLabel = onScreen?.Right is { } right
            ? $"Pages {first}–{right.PageIndex + 1} of {total}"
            : $"Page {first} of {total}";
        var label = ChapterIndicatorLabel(ChapterAt(current.ChapterIndex), current.ChapterIndex, _chapters.Count);
        _footerLabel.Text = label;
        _footerPages.Text = pageLabel;
        AutomationProperties.SetName(_footer, $"{label}, {pageLabel.ToLower(CultureInfo.CurrentCulture)}");
    }

    // MARK: - Listen bar

    private RegionGrid NarrationBar()
    {
        if (_narrationBar is not null) return _narrationBar;

        var back = _brushes.IconButton("backward.fill", "Previous paragraph", () => _speech.SkipBackward(), 14);
        _playIcon = (FontIcon)Symbols.Icon("pause.fill", 18).A11yHidden();
        _playButton = _brushes.BarButton(_playIcon, "Pause", () => _speech.TogglePlayPause());
        AutomationProperties.SetAutomationId(_playButton, "speech.playPause");
        var forward = _brushes.IconButton("forward.fill", "Next paragraph", () => _speech.SkipForward(), 14);

        _narrationChapter = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, Foreground = _brushes.Foreground };
        _narrationPosition = new TextBlock { FontSize = 11, Foreground = _brushes.Fg60 };
        // A grid, not a horizontal stack, so a long chapter title trims to the
        // room left in a narrow window instead of pushing the bar's end off.
        var chapterLine = UI.UI.Grid("*,Auto", "Auto", columnSpacing: 4);
        chapterLine.Children.Add(_narrationChapter.Col(0));
        if (_chapters.Count > 1)
        {
            var chevron = Symbols.Icon("chevron.up.chevron.down", 8).A11yHidden();
            chevron.Foreground = _brushes.Fg60;
            chevron.VerticalAlignment = VerticalAlignment.Center;
            chapterLine.Children.Add(chevron.Col(1));
        }
        var status = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center, Children = { chapterLine, _narrationPosition } };
        _narrationStatus = _brushes.BarButton(status, "Now reading");
        _narrationStatus.HorizontalContentAlignment = HorizontalAlignment.Left;
        _narrationStatus.MaxWidth = 360;
        AutomationProperties.SetAutomationId(_narrationStatus, "speech.chapter");
        if (_chapters.Count > 1)
        {
            AutomationProperties.SetHelpText(_narrationStatus, "Choose a chapter to listen to.");
            var menu = new MenuFlyout();
            menu.Opening += (_, _) =>
            {
                menu.Items.Clear();
                var current = _listeningChapter ?? EffectiveChapter;
                foreach (var chapter in _chapters)
                {
                    var index = chapter.Index;
                    var item = new RadioMenuFlyoutItem { Text = ChapterLabel(chapter), GroupName = "narrationChapter", IsChecked = index == current };
                    item.Click += (_, _) => NarrateToChapter(index);
                    menu.Items.Add(item);
                }
            };
            _narrationStatus.Flyout = menu;
        }
        else
        {
            _narrationStatus.IsTabStop = false;
            _narrationStatus.IsHitTestVisible = false;
        }

        _rateText = new TextBlock { FontSize = 11, FontWeight = FontWeights.Bold, Foreground = _brushes.Foreground };
        var rateChip = new Border { Child = _rateText, Background = _brushes.Fg12, CornerRadius = new CornerRadius(5), Padding = new Thickness(7, 3, 7, 3) };
        _rateButton = _brushes.BarButton(rateChip, "Speaking rate");
        AutomationProperties.SetAutomationId(_rateButton, "speech.rate");
        var rateMenu = new MenuFlyout();
        rateMenu.Opening += (_, _) =>
        {
            rateMenu.Items.Clear();
            foreach (var rate in SpeakingRates)
            {
                var value = rate;
                var item = new RadioMenuFlyoutItem
                {
                    Text = $"{value.ToString("0.0", CultureInfo.CurrentCulture)}×",
                    GroupName = "speakingRate",
                    IsChecked = Math.Abs(_speech.RateMultiplier - value) < 0.05,
                };
                item.Click += (_, _) => { _speech.RateMultiplier = value; UpdateNarrationBar(); };
                rateMenu.Items.Add(item);
            }
        };
        _rateButton.Flyout = rateMenu;

        var stopIcon = Symbols.Icon("xmark.circle.fill", 18).A11yHidden();
        stopIcon.Foreground = _brushes.Fg45;
        var stop = _brushes.BarButton(stopIcon, "Stop listening", () =>
        {
            _speech.Stop();
            _listeningChapter = null;
            MainWindow.Current.Announce("Stopped listening");
        });
        AutomationProperties.SetAutomationId(stop, "speech.stop");

        var bar = new RegionGrid("reader.narrationBar", "Narration controls")
        {
            Padding = new Thickness(14, 6, 14, 6),
            ColumnSpacing = 8,
            Background = _brushes.Background,
            BorderBrush = _brushes.Fg12,
            BorderThickness = new Thickness(0, 1, 0, 0),
        };
        // The status takes the room between the transport buttons and the rate
        // and stop buttons (left-aligned, up to its MaxWidth), so all of them
        // fit at phone width.
        foreach (var width in new[] { "Auto", "Auto", "Auto", "*", "Auto", "Auto" })
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = UI.UI.Length(width) });
        _narrationStatus.HorizontalAlignment = HorizontalAlignment.Left;
        bar.Children.Add(back.Col(0));
        bar.Children.Add(_playButton.Col(1));
        bar.Children.Add(forward.Col(2));
        bar.Children.Add(_narrationStatus.Col(3));
        bar.Children.Add(_rateButton.Col(4));
        bar.Children.Add(stop.Col(5));
        _narrationBar = bar;
        UpdateNarrationBar();
        return bar;
    }

    private void UpdateNarrationBar()
    {
        if (_narrationBar is null || !_speech.IsActive) return;
        var playing = _speech.IsPlaying;
        _playIcon!.Glyph = Symbols.Glyph(playing ? "pause.fill" : "play.fill");
        AutomationProperties.SetName(_playButton!, playing ? "Pause" : "Play");
        ToolTipService.SetToolTip(_playButton!, playing ? "Pause" : "Play");
        _narrationChapter!.Text = _speech.ChapterLabel;
        // "¶ 3 / 40" reads as "pilcrow sign": speak it properly.
        _narrationPosition!.Text = $"¶ {_speech.SpokenPosition} / {_speech.SpokenCount}";
        AutomationProperties.SetName(_narrationStatus!,
            $"Now reading: {_speech.ChapterLabel}, paragraph {_speech.SpokenPosition} of {_speech.SpokenCount}");
        var rate = _speech.RateMultiplier;
        _rateText!.Text = $"{rate.ToString("0.0", CultureInfo.CurrentCulture)}×";
        AutomationProperties.SetName(_rateButton!, $"Speaking rate, {rate.ToString("0.0", CultureInfo.CurrentCulture)} times normal speed");
    }

    // MARK: - Chapters menu

    private MenuFlyout BuildChaptersMenu()
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            var current = EffectiveChapter;
            foreach (var chapter in _chapters)
            {
                var index = chapter.Index;
                var item = new RadioMenuFlyoutItem { Text = ChapterLabel(chapter), GroupName = "readerChapters", IsChecked = index == current };
                item.Click += (_, _) => SelectChapter(index);
                menu.Items.Add(item);
            }
        };
        return menu;
    }

    // MARK: - Aa menu

    private MenuFlyout BuildTypographyMenu()
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Opening += (_, _) => FillTypographyMenu(menu);
        return menu;
    }

    private void FillTypographyMenu(MenuFlyout menu)
    {
        menu.Items.Clear();

        var listen = UI.UI.MenuItem(_speech.IsActive ? "Stop listening" : "Listen to chapter", ToggleListening,
                                    _speech.IsActive ? "stop.circle" : "headphones");
        listen.KeyboardAcceleratorTextOverride = "Ctrl+L";
        AutomationProperties.SetAutomationId(listen, "reader.listen");
        menu.Items.Add(listen);
        menu.Items.Add(new MenuFlyoutSeparator());

        menu.Items.Add(ProfilesMenu());
        menu.Items.Add(new MenuFlyoutSeparator());

        var mode = ReaderPrefs.Mode;
        menu.Items.Add(Picker($"Reading mode · {mode.DisplayName()}", "book.pages", "readingMode",
            ReadingModeExtensions.AllCases.Select(m => (m.DisplayName(), m.RawValue(), (string?)m.Symbol())),
            ReaderPrefs.ModeRaw, raw => ReaderPrefs.ModeRaw = raw));

        if (mode == ReadingMode.PageByPage)
        {
            // One or two pages side by side (two only on a wide window).
            var two = ReaderPrefs.TwoPageSpread;
            menu.Items.Add(Picker($"Pages on screen · {(two ? "Two" : "One")}", "book.pages", "pagesOnScreen",
                [("One page", "one", "rectangle.portrait"), ("Two pages", "two", "book.pages")],
                two ? "two" : "one", raw => ReaderPrefs.TwoPageSpread = raw == "two"));
        }

        menu.Items.Add(Picker($"Theme · {ReaderPrefs.Theme.DisplayName()}", "paintpalette", "readerTheme",
            ReaderThemeExtensions.AllCases.Select(t => (t.DisplayName(), t.RawValue(), (string?)null)),
            ReaderPrefs.ThemeRaw, raw => ReaderPrefs.ThemeRaw = raw));
        menu.Items.Add(Picker($"Font · {ReaderPrefs.FontFamily.DisplayName()}", "character", "readerFont",
            ReaderFontFamilyExtensions.AllCases.Select(f => (f.DisplayName(), f.RawValue(), (string?)null)),
            ReaderPrefs.FontFamilyRaw, raw => ReaderPrefs.FontFamilyRaw = raw));

        var bold = new ToggleMenuFlyoutItem
        {
            Text = "Bold text",
            IsChecked = ReaderPrefs.BoldText,
            Icon = Symbols.Icon("bold"),
        };
        bold.Click += (_, _) => ReaderPrefs.BoldText = bold.IsChecked;
        menu.Items.Add(bold);

        menu.Items.Add(PresetMenu("Text size", ReaderPrefs.FontSizePt, ReaderMetrics.FontSizePresets, "textformat.size", v => ReaderPrefs.FontSizePt = v));
        menu.Items.Add(PresetMenu("Line spacing", ReaderPrefs.LineSpacingPt, ReaderMetrics.LineSpacingPresets, "arrow.up.and.down.text.horizontal", v => ReaderPrefs.LineSpacingPt = v));
        menu.Items.Add(PresetMenu("Paragraph spacing", ReaderPrefs.ParagraphSpacingPt, ReaderMetrics.ParagraphSpacingPresets, "text.justify.left", v => ReaderPrefs.ParagraphSpacingPt = v));
        menu.Items.Add(PresetMenu("Character spacing", ReaderPrefs.KerningPt, ReaderMetrics.KerningPresets, "character.textbox", v => ReaderPrefs.KerningPt = v));

        // Margins adjust whichever layout is on screen: a two-page spread has its
        // own width, so tuning one never disturbs the other.
        if (_builtMode == ReadingMode.PageByPage && _spreadLayout is not null)
            menu.Items.Add(PresetMenu("Page margins", ReaderPrefs.SpreadWidthPercent, ReaderSpread.WidthPresets, "arrow.left.and.right.square", v => ReaderPrefs.SpreadWidthPercent = v));
        else
            menu.Items.Add(PresetMenu("Margins", ReaderPrefs.WidthPercent, ReaderMetrics.WidthPresets, "arrow.left.and.right.square", v => ReaderPrefs.WidthPercent = v));
    }

    /// <summary>A submenu of radio items (SwiftUI's Picker in a Menu).</summary>
    private static MenuFlyoutSubItem Picker(string title, string icon, string group,
                                            IEnumerable<(string Name, string Raw, string? Icon)> options,
                                            string current, Action<string> select)
    {
        var sub = new MenuFlyoutSubItem { Text = title, Icon = Symbols.Icon(icon) };
        foreach (var (name, raw, optionIcon) in options)
        {
            var item = new RadioMenuFlyoutItem { Text = name, GroupName = group, IsChecked = raw == current };
            if (optionIcon is not null) item.Icon = Symbols.Icon(optionIcon);
            item.Click += (_, _) => { if (raw != current) select(raw); };
            sub.Items.Add(item);
        }
        return sub;
    }

    /// <summary>Quick-pick presets for a numeric setting; only the single nearest
    /// preset is marked, and only when the value sits on it ("Custom" otherwise).</summary>
    private static MenuFlyoutSubItem PresetMenu(string title, double value, IReadOnlyList<(string Name, double Value)> presets,
                                                string icon, Action<double> set)
    {
        var current = ReaderMetrics.CurrentPresetName(presets, value);
        var sub = new MenuFlyoutSubItem
        {
            Text = $"{title} · {current ?? "Custom"}",
            Icon = Symbols.Icon(icon),
        };
        foreach (var preset in presets)
        {
            var target = preset.Value;
            var item = new RadioMenuFlyoutItem { Text = preset.Name, GroupName = title, IsChecked = preset.Name == current };
            item.Click += (_, _) => set(target);
            sub.Items.Add(item);
        }
        return sub;
    }

    // MARK: - Profiles

    private static IReadOnlyList<ReaderProfile> Profiles => ReaderProfile.LoadProfiles(ReaderPrefs.ProfilesJSON);

    private MenuFlyoutSubItem ProfilesMenu()
    {
        var active = ReaderPrefs.ActiveProfileName;
        var sub = new MenuFlyoutSubItem
        {
            Text = $"Profile · {active}",
            Icon = Symbols.Icon("person.crop.circle"),
        };
        foreach (var profile in Profiles)
        {
            var p = profile;
            var item = new MenuFlyoutSubItem { Text = p.Name };
            if (p.Name == active) item.Icon = Symbols.Icon("checkmark");
            AutomationProperties.SetName(item, p.Name == active ? $"{p.Name}, active" : p.Name);
            item.Items.Add(UI.UI.MenuItem("Select Profile", () => SelectProfile(p)));
            if (p.Name != DefaultProfileName)
            {
                item.Items.Add(UI.UI.MenuItem("Save Current Settings Here", () => OverwriteProfile(p.Name), "square.and.arrow.down"));
                item.Items.Add(UI.UI.MenuItem("Rename…", () => PresentLater(() => RenameProfileAsync(p.Name)), "pencil"));
                item.Items.Add(UI.UI.MenuItem("Delete", () => DeleteProfile(p.Name), "trash", isDestructive: true));
            }
            sub.Items.Add(item);
        }
        sub.Items.Add(new MenuFlyoutSeparator());
        sub.Items.Add(UI.UI.MenuItem("Save Current as New Profile…", () => PresentLater(NewProfileAsync), "plus"));
        return sub;
    }

    private const string DefaultProfileName = "Default";

    /// <summary>Presents a prompt from the reader once the menu has closed — never
    /// from the menu's own content (CLAUDE.md: it has no live anchor by then).</summary>
    private void PresentLater(Func<Task> present) =>
        _dispatcher.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (_removed) return;
            _ = present();
        });

    private static ReaderProfile CurrentSettings(string name, ReaderProfile? existing)
    {
        if (existing is not null)
        {
            return existing with
            {
                ThemeRaw = ReaderPrefs.ThemeRaw,
                FontFamilyRaw = ReaderPrefs.FontFamilyRaw,
                WidthPercent = ReaderPrefs.WidthPercent,
                ModeRaw = ReaderPrefs.ModeRaw,
                FontSizePt = ReaderPrefs.FontSizePt,
                LineSpacingPt = ReaderPrefs.LineSpacingPt,
                ParagraphSpacingPt = ReaderPrefs.ParagraphSpacingPt,
                PageTurnHaptics = ReaderPrefs.PageTurnHaptics,
                PageTurnAnimations = ReaderPrefs.PageTurnAnimations,
                KerningPt = ReaderPrefs.KerningPt,
                BoldText = ReaderPrefs.BoldText,
            };
        }
        return new ReaderProfile
        {
            Name = name,
            ThemeRaw = ReaderPrefs.ThemeRaw,
            FontFamilyRaw = ReaderPrefs.FontFamilyRaw,
            WidthRaw = null,
            WidthPercent = ReaderPrefs.WidthPercent,
            ModeRaw = ReaderPrefs.ModeRaw,
            FontSizePt = ReaderPrefs.FontSizePt,
            LineSpacingPt = ReaderPrefs.LineSpacingPt,
            ParagraphSpacingPt = ReaderPrefs.ParagraphSpacingPt,
            PageTurnHaptics = ReaderPrefs.PageTurnHaptics,
            PageTurnAnimations = ReaderPrefs.PageTurnAnimations,
            KerningPt = ReaderPrefs.KerningPt,
            BoldText = ReaderPrefs.BoldText,
        };
    }

    private static void SaveCurrentToActiveProfile()
    {
        var name = ReaderPrefs.ActiveProfileName;
        var list = Profiles.ToList();
        var index = list.FindIndex(p => p.Name == name);
        if (index >= 0) list[index] = CurrentSettings(name, list[index]);
        else list.Add(CurrentSettings(name, null));
        SaveProfiles(list);
        QueueBackup();
    }

    private static void SelectProfile(ReaderProfile profile)
    {
        ReaderPrefs.ActiveProfileName = profile.Name;
        ReaderPrefs.ThemeRaw = profile.ThemeRaw;
        ReaderPrefs.FontFamilyRaw = profile.FontFamilyRaw;
        ReaderPrefs.WidthPercent = profile.WidthPercent ?? 70.0;
        ReaderPrefs.ModeRaw = profile.ModeRaw;
        ReaderPrefs.FontSizePt = profile.FontSizePt;
        ReaderPrefs.LineSpacingPt = profile.LineSpacingPt;
        ReaderPrefs.ParagraphSpacingPt = profile.ParagraphSpacingPt;
        ReaderPrefs.PageTurnHaptics = profile.PageTurnHaptics;
        ReaderPrefs.PageTurnAnimations = profile.PageTurnAnimations;
        ReaderPrefs.KerningPt = profile.KerningPt ?? ReaderMetrics.DefaultKerning;
        ReaderPrefs.BoldText = profile.BoldText ?? false;
        QueueBackup();
        MainWindow.Current.Announce($"Profile {profile.Name} applied");
    }

    private static void DeleteProfile(string name)
    {
        var list = Profiles.ToList();
        list.RemoveAll(p => p.Name == name);
        if (ReaderPrefs.ActiveProfileName == name)
        {
            ReaderPrefs.ActiveProfileName = DefaultProfileName;
            SelectProfile(list.FirstOrDefault(p => p.Name == DefaultProfileName) ?? ReaderProfile.DefaultProfiles[0]);
        }
        SaveProfiles(list);
        QueueBackup();
        MainWindow.Current.Announce($"Deleted profile {name}");
    }

    private static void OverwriteProfile(string name)
    {
        var list = Profiles.ToList();
        var index = list.FindIndex(p => p.Name == name);
        if (index < 0) return;
        list[index] = CurrentSettings(name, list[index]);
        SaveProfiles(list);
        QueueBackup();
        MainWindow.Current.Announce($"Saved settings to {name}");
    }

    private static bool NameTaken(string name, string? except = null) =>
        Profiles.Any(p => p.Name != except && string.Compare(p.Name, name, CultureInfo.CurrentCulture, CompareOptions.IgnoreCase) == 0);

    private static async Task NewProfileAsync()
    {
        var name = await Dialogs.PromptAsync("New Profile", "Profile Name", "Save",
            message: "Enter a name for this reader settings configuration profile.");
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return;
        if (NameTaken(trimmed))
        {
            await Dialogs.AlertAsync($"A profile named \"{trimmed}\" already exists.");
            return;
        }
        ReaderPrefs.ActiveProfileName = trimmed;
        SaveCurrentToActiveProfile();
        MainWindow.Current.Announce($"Saved profile {trimmed}");
    }

    private static async Task RenameProfileAsync(string current)
    {
        var name = await Dialogs.PromptAsync("Rename Profile", "Profile Name", "Rename", initial: current,
            message: $"Enter a new name for \"{current}\".");
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed == current) return;
        if (trimmed.Equals(DefaultProfileName, StringComparison.OrdinalIgnoreCase) || NameTaken(trimmed, except: current))
        {
            await Dialogs.AlertAsync($"A profile named \"{trimmed}\" already exists.");
            return;
        }
        var list = Profiles.ToList();
        var index = list.FindIndex(p => p.Name == current);
        if (index < 0) return;
        // The old name becomes a tombstone (SaveProfiles diffs against the stored
        // JSON), so the rename reaches other devices instead of leaving a copy.
        list[index] = list[index] with { Name = trimmed };
        if (ReaderPrefs.ActiveProfileName == current) ReaderPrefs.ActiveProfileName = trimmed;
        SaveProfiles(list);
        QueueBackup();
        MainWindow.Current.Announce($"Renamed to {trimmed}");
    }

    /// <summary>Diffing against the stored JSON stamps edits and tombstones removed
    /// names, so deletions survive the cloud merge in PublishLocalProfiles.</summary>
    private static void SaveProfiles(IEnumerable<ReaderProfile> list)
    {
        var json = ReaderProfile.SaveProfiles(list, ReaderPrefs.ProfilesJSON);
        ReaderPrefs.ProfilesJSON = json;
        ReaderProfileSyncStore.PublishLocalProfiles(json);
    }

    private static void QueueBackup() => LibrarySyncManager.QueueBackupShared(AppHost.Library);
}

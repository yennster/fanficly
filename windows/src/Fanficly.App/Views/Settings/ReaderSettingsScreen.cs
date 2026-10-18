using System.Globalization;
using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Fanficly.App.Views.Settings;

/// <summary>
/// Settings → Theme &amp; typography (ReaderSettingsView): reader profiles
/// (switch, save as new, save, rename, delete), a live preview, text size and
/// spacing, reading mode with pages on screen and two-page margins, page-turn
/// animation, keep screen awake, story images, the Listen voice and rate (with
/// a spoken sample), the page theme, the font, bold text and margins.
///
/// Every typography key is per-device (<see cref="ReaderProfile.DeviceKey(string)"/>,
/// <c>.windows</c>); changes are written at once and the reader reads them when
/// it appears, so they apply live. Changes queue a library backup, like Swift.
///
/// Page-turn haptics: Windows PCs have no general haptic output (only a few
/// pens and touchpads, and only while drawing or clicking), so the toggle is
/// hidden here. Its key is still kept and saved into profiles, so a profile
/// synced from an iPhone keeps its haptics choice.
/// </summary>
public sealed class ReaderSettingsScreen : Screen
{
    private static string K(string baseKey) => ReaderProfile.DeviceKey(baseKey);

    private static readonly string ThemeKey = K("reader.theme");
    private static readonly string FontKey = K("reader.fontFamily");
    private static readonly string WidthKey = K("reader.widthPercent");
    private static readonly string ModeKey = K("reader.mode");
    private static readonly string FontSizeKey = K("reader.fontSizePt");
    private static readonly string LineSpacingKey = K("reader.lineSpacingPt");
    private static readonly string ParagraphSpacingKey = K("reader.paragraphSpacingPt");
    private static readonly string HapticsKey = K("reader.pageTurnHaptics");
    private static readonly string AnimationsKey = K("reader.pageTurnAnimations");
    private static readonly string TwoPageKey = K("reader.twoPageSpread");
    private static readonly string SpreadWidthKey = K("reader.spreadWidthPercent");
    private static readonly string KerningKey = K("reader.kerningPt");
    private static readonly string BoldKey = K("reader.boldText");
    private const string KeepAwakeKey = "reader.keepScreenAwake";
    /// <summary>Global, not per device: a content and privacy choice, not typography.</summary>
    private const string ShowImagesKey = "reader.showImages";
    private const string DefaultProfileName = "Default";

    private static IKeyValueStore Store => KeyValueStores.Default;

    // Current values (the @AppStorage properties).
    private static string ThemeRaw { get => Store.GetString(ThemeKey) ?? ReaderTheme.System.RawValue(); set => Store.SetString(ThemeKey, value); }
    private static string FontFamilyRaw { get => Store.GetString(FontKey) ?? ReaderFontFamily.NewYork.RawValue(); set => Store.SetString(FontKey, value); }
    private static double WidthPercent { get => Store.GetDouble(WidthKey, 70); set => Store.SetDouble(WidthKey, value); }
    private static string ModeRaw { get => Store.GetString(ModeKey) ?? ReadingMode.Continuous.RawValue(); set => Store.SetString(ModeKey, value); }
    private static double FontSizePt { get => Store.GetDouble(FontSizeKey, ReaderMetrics.DefaultFontSize); set => Store.SetDouble(FontSizeKey, value); }
    private static double LineSpacingPt { get => Store.GetDouble(LineSpacingKey, ReaderMetrics.DefaultLineSpacing); set => Store.SetDouble(LineSpacingKey, value); }
    private static double ParagraphSpacingPt { get => Store.GetDouble(ParagraphSpacingKey, ReaderMetrics.DefaultParagraphSpacing); set => Store.SetDouble(ParagraphSpacingKey, value); }
    private static bool PageTurnHaptics { get => Store.GetBool(HapticsKey, false); set => Store.SetBool(HapticsKey, value); }
    private static bool PageTurnAnimations { get => Store.GetBool(AnimationsKey, true); set => Store.SetBool(AnimationsKey, value); }
    private static bool TwoPageSpread { get => Store.GetBool(TwoPageKey, true); set => Store.SetBool(TwoPageKey, value); }
    private static double SpreadWidthPercent { get => Store.GetDouble(SpreadWidthKey, ReaderSpread.DefaultWidthPercent); set => Store.SetDouble(SpreadWidthKey, value); }
    private static double KerningPt { get => Store.GetDouble(KerningKey, ReaderMetrics.DefaultKerning); set => Store.SetDouble(KerningKey, value); }
    private static bool BoldText { get => Store.GetBool(BoldKey, false); set => Store.SetBool(BoldKey, value); }
    private static string ActiveProfileName { get => Store.GetString(ReaderProfile.DeviceActiveProfileKey) ?? DefaultProfileName; set => Store.SetString(ReaderProfile.DeviceActiveProfileKey, value); }
    private static string ProfilesJson { get => Store.GetString(ReaderProfileSyncStore.ProfilesKey) ?? ""; set => Store.SetString(ReaderProfileSyncStore.ProfilesKey, value); }
    private static double TtsRate { get => Store.GetDouble(SpeechSample.RateKey, SpeechSample.DefaultRate); set => Store.SetDouble(SpeechSample.RateKey, value); }
    private static string TtsVoiceId { get => Store.GetString(SpeechSample.VoiceKey) ?? ""; set => Store.SetString(SpeechSample.VoiceKey, value); }

    private static IReadOnlyList<ReaderProfile> Profiles => ReaderProfile.LoadProfiles(ProfilesJson);

    private readonly Grid _host = new();
    private bool _appearedOnce;

    // Live preview.
    private Border? _preview;
    private StackPanel? _previewStack;
    private TextBlock? _previewTitle;
    private TextBlock[] _previewBody = [];

    // Reading mode extras that show only for page-by-page / two pages.
    private FrameworkElement? _pagesOnScreenRow;
    private FrameworkElement? _spreadMarginsRow;

    private Button? _sampleButton;

    public ReaderSettingsScreen()
    {
        Title = "Reader";
        ReaderProfile.MigrateLegacySettingsIfNeeded();
    }

    protected override FrameworkElement Build()
    {
        Rebuild(restoreOffset: false);
        return _host;
    }

    public override void OnAppearing()
    {
        Theme.Changed += UpdatePreview;
        // The reader's Aa menu edits the same keys; show its latest values.
        if (_appearedOnce && IsBuilt) Rebuild(restoreOffset: true);
        _appearedOnce = true;
    }

    public override void OnDisappearing()
    {
        Theme.Changed -= UpdatePreview;
        SpeechSample.Stop();
    }

    /// <summary>Builds the page from the stored values (after a profile switch,
    /// every control changes at once), keeping the scroll position.</summary>
    private void Rebuild(bool restoreOffset)
    {
        var offset = _host.Children.Count > 0 && _host.Children[0] is ScrollViewer old ? old.VerticalOffset : 0;
        var page = SettingsKit.Page(BuildContent(), "settings.reader.page");
        if (restoreOffset && offset > 0)
            page.Loaded += (_, _) => page.ChangeView(null, offset, null, disableAnimation: true);
        _host.Children.Clear();
        _host.Children.Add(page);
        UpdatePreview();
        UpdateModeExtras();
    }

    private void RebuildSoon() =>
        MainWindow.Current.DispatcherQueue.TryEnqueue(() => Rebuild(restoreOffset: true));

    private static void QueueBackup() => LibrarySyncManager.QueueBackupShared(AppHost.Library);

    private StackPanel BuildContent()
    {
        var content = new StackPanel();
        if (Theme.IsHighContrast)
        {
            content.Children.Add(UI.UI.Section(null,
            [
                SettingsKit.Note("High contrast is on in Windows settings. We recommend the “Match System” or “Dracula Navy” theme to keep story text readable.",
                    "circle.lefthalf.striped.horizontal", Theme.Warning),
            ]));
        }
        content.Children.Add(ProfileSection());
        content.Children.Add(PreviewSection());
        content.Children.Add(SpacingSection());
        content.Children.Add(ReadingModeSection());
        content.Children.Add(ImagesSection());
        content.Children.Add(ListenSection());
        content.Children.Add(ThemeSection());
        content.Children.Add(FontSection());
        content.Children.Add(MarginsSection());
        return content;
    }

    // MARK: - Profiles

    private StackPanel ProfileSection()
    {
        var active = ActiveProfileName;
        var combo = SettingsKit.Choice("Active Profile", Profiles.Select(p => (p.Name, p.Name)), active, name =>
        {
            if (name == ActiveProfileName) return;
            if (Profiles.FirstOrDefault(p => p.Name == name) is { } profile)
            {
                SelectProfile(profile);
                MainWindow.Current.Announce($"Profile {profile.Name} applied");
                RebuildSoon();
            }
        });
        AutomationProperties.SetAutomationId(combo, "settings.reader.profile");
        ToolTipService.SetToolTip(combo, "Select a reader settings profile to apply or edit.");

        var rows = new List<UIElement>
        {
            UI.UI.SettingsRow("Active Profile", combo, null, "person.crop.circle"),
            SettingsKit.ActionRow("Save Current Settings as New Profile…", () => _ = NewProfileAsync(), "plus",
                automationId: "settings.reader.newProfile", tooltip: "Save these settings as a reusable configuration profile."),
        };
        if (active != DefaultProfileName)
        {
            rows.Add(SettingsKit.ActionRow($"Save Current Settings to “{active}”", () =>
            {
                SaveCurrentToActiveProfile();
                MainWindow.Current.Announce($"Saved to {active}");
            }, "square.and.arrow.down", tooltip: "Overwrite the selected profile with your current settings."));
            rows.Add(SettingsKit.ActionRow($"Rename Profile “{active}”…", () => _ = RenameProfileAsync(active), "pencil",
                tooltip: "Give the selected profile a new name."));
            rows.Add(SettingsKit.ActionRow($"Delete Profile “{active}”", () =>
            {
                DeleteProfile(active);
                MainWindow.Current.Announce($"Deleted profile {active}");
                RebuildSoon();
            }, "trash", destructive: true, automationId: "settings.reader.deleteProfile", tooltip: "Delete the selected profile."));
        }
        return UI.UI.Section("Reader Profile", rows);
    }

    /// <summary>The current settings as a profile named <paramref name="name"/>,
    /// keeping <paramref name="existing"/>'s other fields (widthRaw, stamps).</summary>
    private static ReaderProfile CurrentSettings(string name, ReaderProfile? existing)
    {
        if (existing is not null)
        {
            return existing with
            {
                ThemeRaw = ThemeRaw, FontFamilyRaw = FontFamilyRaw, WidthPercent = WidthPercent, ModeRaw = ModeRaw,
                FontSizePt = FontSizePt, LineSpacingPt = LineSpacingPt, ParagraphSpacingPt = ParagraphSpacingPt,
                PageTurnHaptics = PageTurnHaptics, PageTurnAnimations = PageTurnAnimations,
                KerningPt = KerningPt, BoldText = BoldText,
            };
        }
        return new ReaderProfile
        {
            Name = name, ThemeRaw = ThemeRaw, FontFamilyRaw = FontFamilyRaw, WidthRaw = null, WidthPercent = WidthPercent,
            ModeRaw = ModeRaw, FontSizePt = FontSizePt, LineSpacingPt = LineSpacingPt, ParagraphSpacingPt = ParagraphSpacingPt,
            PageTurnHaptics = PageTurnHaptics, PageTurnAnimations = PageTurnAnimations, KerningPt = KerningPt, BoldText = BoldText,
        };
    }

    private static void SaveCurrentToActiveProfile()
    {
        var name = ActiveProfileName;
        var list = Profiles.ToList();
        var index = list.FindIndex(p => p.Name == name);
        if (index >= 0) list[index] = CurrentSettings(name, list[index]);
        else list.Add(CurrentSettings(name, null));
        SaveProfiles(list);
        QueueBackup();
    }

    private static void SelectProfile(ReaderProfile profile)
    {
        ActiveProfileName = profile.Name;
        ThemeRaw = profile.ThemeRaw;
        FontFamilyRaw = profile.FontFamilyRaw;
        WidthPercent = profile.WidthPercent ?? 70.0;
        ModeRaw = profile.ModeRaw;
        FontSizePt = profile.FontSizePt;
        LineSpacingPt = profile.LineSpacingPt;
        ParagraphSpacingPt = profile.ParagraphSpacingPt;
        PageTurnHaptics = profile.PageTurnHaptics;
        PageTurnAnimations = profile.PageTurnAnimations;
        KerningPt = profile.KerningPt ?? ReaderMetrics.DefaultKerning;
        BoldText = profile.BoldText ?? false;
        QueueBackup();
    }

    private static void DeleteProfile(string name)
    {
        var list = Profiles.ToList();
        list.RemoveAll(p => p.Name == name);
        if (ActiveProfileName == name)
        {
            ActiveProfileName = DefaultProfileName;
            SelectProfile(list.FirstOrDefault(p => p.Name == DefaultProfileName) ?? ReaderProfile.DefaultProfiles[0]);
        }
        SaveProfiles(list);
        QueueBackup();
    }

    private static bool NameTaken(string name, string? except = null) =>
        Profiles.Any(p => p.Name != except && string.Compare(p.Name, name, CultureInfo.CurrentCulture, CompareOptions.IgnoreCase) == 0);

    private async Task NewProfileAsync()
    {
        var name = await Dialogs.PromptAsync("New Profile", "Profile Name", "Save",
            message: "Enter a name for this reader settings configuration profile.");
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return;
        if (NameTaken(trimmed))
        {
            await Dialogs.AlertAsync($"A profile named “{trimmed}” already exists.");
            return;
        }
        ActiveProfileName = trimmed;
        SaveCurrentToActiveProfile();
        MainWindow.Current.Announce($"Saved profile {trimmed}");
        Rebuild(restoreOffset: true);
    }

    private async Task RenameProfileAsync(string current)
    {
        var name = await Dialogs.PromptAsync("Rename Profile", "Profile Name", "Rename", initial: current,
            message: $"Enter a new name for “{current}”.");
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed == current) return;
        if (trimmed.Equals(DefaultProfileName, StringComparison.OrdinalIgnoreCase) || NameTaken(trimmed, except: current))
        {
            await Dialogs.AlertAsync($"A profile named “{trimmed}” already exists.");
            return;
        }
        var list = Profiles.ToList();
        var index = list.FindIndex(p => p.Name == current);
        if (index < 0) return;
        // The old name becomes a tombstone (SaveProfiles diffs against the stored
        // JSON), so the rename reaches other devices instead of leaving a copy.
        list[index] = list[index] with { Name = trimmed };
        if (ActiveProfileName == current) ActiveProfileName = trimmed;
        SaveProfiles(list);
        QueueBackup();
        MainWindow.Current.Announce($"Renamed to {trimmed}");
        Rebuild(restoreOffset: true);
    }

    /// <summary>Diffing against the stored JSON stamps edits and tombstones removed
    /// names, so deletions survive the cloud merge in PublishLocalProfiles.</summary>
    private static void SaveProfiles(IEnumerable<ReaderProfile> list)
    {
        var json = ReaderProfile.SaveProfiles(list, ProfilesJson);
        ProfilesJson = json;
        ReaderProfileSyncStore.PublishLocalProfiles(json);
    }

    // MARK: - Preview

    private StackPanel PreviewSection()
    {
        _previewTitle = new TextBlock { Text = "A Coffee Shop Tale", TextWrapping = TextWrapping.WrapWholeWords };
        _previewBody =
        [
            new TextBlock { Text = "Bella poured the latte. It was hot.", TextWrapping = TextWrapping.WrapWholeWords },
            new TextBlock { Text = "Edward looked up from the corner table and met her eyes. The cafe felt suddenly quieter.", TextWrapping = TextWrapping.WrapWholeWords },
        ];
        _previewStack = new StackPanel();
        _previewStack.Children.Add(_previewTitle);
        foreach (var t in _previewBody) _previewStack.Children.Add(t);
        _preview = new Border
        {
            Child = _previewStack,
            Padding = new Thickness(16),
            CornerRadius = new CornerRadius(8),
            Margin = new Thickness(12, 8, 12, 8),
        };
        AutomationProperties.SetAutomationId(_preview, "settings.reader.preview");
        ToolTipService.SetToolTip(_preview, "Visual preview of current font size, spacing, font, and theme.");
        return UI.UI.Section("Preview", [_preview]);
    }

    private static Brush BrushFor(ReaderColor c) => new SolidColorBrush(Windows.UI.Color.FromArgb(c.A, c.R, c.G, c.B));

    private void UpdatePreview()
    {
        if (_preview is null || _previewStack is null || _previewTitle is null) return;
        var theme = ReaderThemeExtensions.FromRawValue(ThemeRaw) ?? ReaderTheme.System;
        var family = ReaderFontFamilyExtensions.FromRawValue(FontFamilyRaw) ?? ReaderFontFamily.NewYork;
        var scheme = theme.PreferredColorScheme()
                     ?? (Theme.Current == ElementTheme.Dark ? ReaderColorScheme.Dark : ReaderColorScheme.Light);
        var size = FontSizePt;
        var font = new FontFamily(family.WindowsFontFamily());
        var foreground = BrushFor(theme.Foreground(scheme));
        // The reader sits inside the window's zoom like this preview, so the
        // preview uses the reader's own sizes (no zoom compensation needed).
        int Tracking(double fontSize) => (int)Math.Round(KerningPt / fontSize * 1000);

        _preview.Background = BrushFor(theme.Background(scheme));
        _previewStack.Spacing = ParagraphSpacingPt;
        _previewTitle.FontFamily = font;
        _previewTitle.FontSize = size + 6;
        _previewTitle.FontWeight = FontWeights.Bold;
        _previewTitle.CharacterSpacing = Tracking(size + 6);
        _previewTitle.Foreground = foreground;
        foreach (var body in _previewBody)
        {
            body.FontFamily = font;
            body.FontSize = size;
            body.FontWeight = BoldText ? FontWeights.Bold : FontWeights.Normal;
            body.CharacterSpacing = Tracking(size);
            body.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
            body.LineHeight = Math.Round(size * 1.3) + LineSpacingPt;
            body.Foreground = foreground;
        }
    }

    // MARK: - Text size & spacing

    private StackPanel SpacingSection() => UI.UI.Section("Text size & spacing",
    [
        SettingsKit.MetricSlider("Text size", "textformat.size", FontSizePt, ReaderMetrics.FontSizeRange, 1, "pt",
            v => { FontSizePt = v; Changed(); }, "settings.reader.fontSize"),
        SettingsKit.MetricSlider("Line spacing", "arrow.up.and.down.text.horizontal", LineSpacingPt, ReaderMetrics.LineSpacingRange, 1, "pt",
            v => { LineSpacingPt = v; Changed(); }, "settings.reader.lineSpacing"),
        SettingsKit.MetricSlider("Paragraph spacing", "text.justify.left", ParagraphSpacingPt, ReaderMetrics.ParagraphSpacingRange, 2, "pt",
            v => { ParagraphSpacingPt = v; Changed(); }, "settings.reader.paragraphSpacing"),
        SettingsKit.MetricSlider("Character spacing", "character.textbox", KerningPt, ReaderMetrics.KerningRange, 0.1, "pt",
            v => { KerningPt = v; Changed(); }, "settings.reader.kerning"),
    ], footer: "Drag the sliders, or use − / + to fine-tune.");

    private void Changed()
    {
        UpdatePreview();
        QueueBackup();
    }

    // MARK: - Reading mode

    private StackPanel ReadingModeSection()
    {
        var modes = SettingsKit.Radios("Reading mode",
            ReadingModeExtensions.AllCases.Select(m => (m.RawValue(), m.DisplayName())), ModeRaw,
            raw => { ModeRaw = raw; UpdateModeExtras(); QueueBackup(); },
            symbol: raw => ReadingModeExtensions.FromRawValue(raw)?.Symbol());
        AutomationProperties.SetAutomationId(modes, "settings.reader.mode");
        ToolTipService.SetToolTip(modes, "Choose how stories are paginated and scrolled.");

        var pages = SettingsKit.Segmented("Pages on screen", [("one", "One page"), ("two", "Two pages")],
            TwoPageSpread ? "two" : "one", v => { TwoPageSpread = v == "two"; UpdateModeExtras(); });
        AutomationProperties.SetAutomationId(pages, "settings.reader.pagesOnScreen");
        _pagesOnScreenRow = UI.UI.SettingsRow("Pages on screen", pages, null, "book.pages")
            .Also(r => ToolTipService.SetToolTip(r, "On wide windows, show two pages side by side like an open book."));
        _spreadMarginsRow = SettingsKit.MetricSlider("Two-page margins", "arrow.left.and.right.square", SpreadWidthPercent,
            ReaderSpread.WidthPercentRange, 2.0, "%", v => SpreadWidthPercent = v, "settings.reader.spreadMargins");

        return UI.UI.Section("Reading mode",
        [
            modes,
            _pagesOnScreenRow,
            _spreadMarginsRow,
            SettingsKit.ToggleRow("Page-turn animation", PageTurnAnimations, on => { PageTurnAnimations = on; QueueBackup(); },
                "square.2.layers.3d", tooltip: "Slide pages across as they turn.", automationId: "settings.reader.animations"),
            SettingsKit.ToggleRow("Keep screen awake while reading", Store.GetBool(KeepAwakeKey, true), on => Store.SetBool(KeepAwakeKey, on),
                "sun.max", tooltip: "Stop the display from dimming or sleeping while a story is open, like a video player.",
                automationId: "settings.reader.keepAwake"),
        ], footer: "Continuous scrolls the whole work in one column. Swipe by chapter shows one chapter per page — scroll vertically inside it. Page-by-page formats the work into horizontal pages you turn with the arrow keys, a click or tap at the page's edge, a swipe, or a controller's triggers; with “Pages on screen” set to two, a wide window — maximized, full screen, or a tablet in landscape — shows two pages side by side like an open book, with its own text width (“Two-page margins”). “Page-turn animation” slides pages as they turn. “Keep screen awake” holds the display on while you read and releases it as soon as you leave the reader.");
    }

    private void UpdateModeExtras()
    {
        var pageByPage = ModeRaw == ReadingMode.PageByPage.RawValue();
        _pagesOnScreenRow?.Visible(pageByPage);
        _spreadMarginsRow?.Visible(pageByPage && TwoPageSpread);
        HideDividerBefore(_pagesOnScreenRow);
        HideDividerBefore(_spreadMarginsRow);
    }

    /// <summary>Hides the section divider above a hidden row so no double line shows.</summary>
    private static void HideDividerBefore(FrameworkElement? row)
    {
        if (row?.Parent is not Panel panel) return;
        var index = panel.Children.IndexOf(row);
        if (index > 0 && panel.Children[index - 1] is Border divider && divider.Height == 1)
            divider.Visibility = row.Visibility;
    }

    // MARK: - Story images

    private static StackPanel ImagesSection() => UI.UI.Section("Story images",
    [
        SettingsKit.ToggleRow("Show images in stories", Store.GetBool(ShowImagesKey, false), on => Store.SetBool(ShowImagesKey, on),
            "photo", tooltip: "Render images that authors embed in chapters of General and Teen rated works.", automationId: "settings.reader.showImages"),
    ], footer: "Off by default: chapters render as text only. When on, images embedded in a story are fetched from the author's original image host as you read — like opening that site in a browser, it can see your IP address. Images aren't saved with downloaded works, so offline reading stays text-only, though Windows may keep a temporary cache of recently viewed images on this PC.");

    // MARK: - Listen

    private StackPanel ListenSection()
    {
        var voices = SpeechSample.Voices();
        var items = new List<(string, string)> { ("", "System default") };
        items.AddRange(voices.Select(v => (v.Id, $"{v.DisplayName} ({v.Language})")));
        var stored = TtsVoiceId;
        // A voice id from another device (an Apple voice) or an uninstalled voice
        // shows as the default, which is what the reader falls back to.
        var selected = items.Any(i => i.Item1 == stored) ? stored : "";
        var voiceCombo = SettingsKit.Choice("Voice", items, selected, id => { TtsVoiceId = id; QueueBackup(); }, minWidth: 240);
        AutomationProperties.SetAutomationId(voiceCombo, "settings.reader.voice");
        ToolTipService.SetToolTip(voiceCombo, "Select a voice for reading aloud.");

        // Speaking rate: stored on the Apple scale, shown as a multiplier.
        static string Times(double raw) => SpeechSample.Multiplier(raw).ToString("0.0", CultureInfo.CurrentCulture) + "×";
        var rateValue = UI.UI.Secondary(Times(TtsRate), Theme.Style.Subheadline);
        rateValue.VerticalAlignment = VerticalAlignment.Center;
        var rateHeader = UI.UI.Grid("*,Auto");
        rateHeader.Children.Add(UI.UI.Label("speedometer", "Speaking rate", Theme.Style.Subheadline).Col(0));
        rateHeader.Children.Add(rateValue.Col(1));
        var rate = new Slider
        {
            Minimum = SpeechSample.RateRange.Min,
            Maximum = SpeechSample.RateRange.Max,
            StepFrequency = 0.025,
            SmallChange = 0.025,
            LargeChange = 0.125,
            Value = Math.Clamp(TtsRate, SpeechSample.RateRange.Min, SpeechSample.RateRange.Max),
            IsThumbToolTipEnabled = false,
        };
        AutomationProperties.SetName(rate, "Speaking rate");
        AutomationProperties.SetHelpText(rate, "Adjusts the voice reading speed.");
        AutomationProperties.SetItemStatus(rate, $"{Times(TtsRate)} standard speed");
        AutomationProperties.SetAutomationId(rate, "settings.reader.rate");
        ToolTipService.SetToolTip(rate, "Drag to adjust the speech speed.");
        rate.ValueChanged += (_, e) =>
        {
            TtsRate = e.NewValue;
            rateValue.Text = Times(e.NewValue);
            AutomationProperties.SetItemStatus(rate, $"{Times(e.NewValue)} standard speed");
            QueueBackup();
        };

        _sampleButton = UI.UI.Button("Play Sample", ToggleSample, "play.fill");
        AutomationProperties.SetAutomationId(_sampleButton, "settings.reader.playSample");
        ToolTipService.SetToolTip(_sampleButton, "Hear the selected voice at this speed.");
        _sampleButton.IsEnabled = voices.Count > 0;

        var rateControls = UI.UI.Grid("*,Auto", columnSpacing: 12);
        rateControls.Children.Add(rate.Col(0));
        rateControls.Children.Add(_sampleButton.Col(1));
        var rateRow = UI.UI.VStack(4, rateHeader, rateControls);
        rateRow.Padding = new Thickness(14, 10, 14, 10);

        var rows = new List<UIElement>
        {
            UI.UI.SettingsRow("Voice", voiceCombo, null, "person.wave.2"),
            rateRow,
            SettingsKit.ActionRow("Add voices in Windows Settings", () => _ = SettingsKit.OpenUriAsync("ms-settings:speech"),
                "arrow.up.right.square", tooltip: "Windows Settings → Time & language → Speech"),
        };
        if (voices.Count == 0)
            rows.Insert(0, SettingsKit.Note("No speech voices are installed. Add one in Windows Settings → Time & language → Speech.",
                "exclamationmark.triangle", Theme.Warning));

        return UI.UI.Section("Listen", rows,
            footer: "Choose Listen to Chapter in the reader's Aa menu (or press Ctrl+L) to have a chapter read aloud. For more natural-sounding voices, add them in Windows Settings → Time & language → Speech → Manage voices. Voices run entirely on this PC and are free.");
    }

    private void ToggleSample()
    {
        if (_sampleButton is null) return;
        if (_sampleButton.Tag is "playing")
        {
            SpeechSample.Stop();
            return;
        }
        SetSampleButton(playing: true);
        _ = SpeechSample.PlayAsync(TtsVoiceId, TtsRate, () => SetSampleButton(playing: false));
    }

    private void SetSampleButton(bool playing)
    {
        if (_sampleButton is null) return;
        _sampleButton.Tag = playing ? "playing" : null;
        var label = playing ? "Stop" : "Play Sample";
        _sampleButton.Content = UI.UI.Label(playing ? "stop.fill" : "play.fill", label, spacing: 6);
        AutomationProperties.SetName(_sampleButton, label);
    }

    // MARK: - Theme, font, margins

    private StackPanel ThemeSection()
    {
        var radios = SettingsKit.Radios("Theme", ReaderThemeExtensions.AllCases.Select(t => (t.RawValue(), t.DisplayName())), ThemeRaw,
            raw => { ThemeRaw = raw; Changed(); }, columns: 2);
        AutomationProperties.SetAutomationId(radios, "settings.reader.theme");
        ToolTipService.SetToolTip(radios, "Choose the color scheme for the reader.");
        return UI.UI.Section("Theme", [radios]);
    }

    private StackPanel FontSection()
    {
        var radios = SettingsKit.Radios("Font", ReaderFontFamilyExtensions.AllCases.Select(f => (f.RawValue(), f.DisplayName())), FontFamilyRaw,
            raw => { FontFamilyRaw = raw; Changed(); },
            font: raw => ReaderFontFamilyExtensions.FromRawValue(raw) is { } f ? new FontFamily(f.WindowsFontFamily()) : null);
        AutomationProperties.SetAutomationId(radios, "settings.reader.font");
        ToolTipService.SetToolTip(radios, "Choose the typography for the reader.");
        return UI.UI.Section("Font",
        [
            radios,
            SettingsKit.ToggleRow("Bold text", BoldText, on => { BoldText = on; Changed(); }, "bold",
                tooltip: "Make all reader text bold for easier reading.", automationId: "settings.reader.bold"),
        ]);
    }

    private StackPanel MarginsSection() => UI.UI.Section("Margins",
    [
        SettingsKit.MetricSlider("Margins", "arrow.left.and.right.square", WidthPercent, (30.0, 100.0), 5.0, "%",
            v => { WidthPercent = v; QueueBackup(); }, "settings.reader.margins"),
    ], footer: "Adjust the width of the text column as a percentage of the window.");
}

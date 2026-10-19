using Fanficly.Core;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// The reader's settings (ReaderView's <c>@AppStorage</c> properties), under the
/// Swift keys. Typography keys are per device (<see cref="ReaderProfile.DeviceKey(string)"/>),
/// computed on each access because the device is chosen at launch, after module
/// initializers run.
/// </summary>
internal static class ReaderPrefs
{
    private static IKeyValueStore Store => KeyValueStores.Default;
    private static string K(string baseKey) => ReaderProfile.DeviceKey(baseKey);

    public const string ThemeBase = "reader.theme";
    public const string FontFamilyBase = "reader.fontFamily";
    public const string WidthPercentBase = "reader.widthPercent";
    public const string ModeBase = "reader.mode";
    public const string FontSizeBase = "reader.fontSizePt";
    public const string LineSpacingBase = "reader.lineSpacingPt";
    public const string ParagraphSpacingBase = "reader.paragraphSpacingPt";
    public const string HapticsBase = "reader.pageTurnHaptics";
    public const string AnimationsBase = "reader.pageTurnAnimations";
    public const string KerningBase = "reader.kerningPt";
    public const string BoldTextBase = "reader.boldText";
    public const string TwoPageSpreadBase = "reader.twoPageSpread";
    public const string SpreadWidthBase = "reader.spreadWidthPercent";
    public const string KeepScreenAwakeKey = "reader.keepScreenAwake";
    public const string ShowImagesKey = "reader.showImages";
    public const string ZoomKey = "app.zoomScale";

    /// <summary>The per-device keys a profile carries (a change queues a library backup).</summary>
    public static readonly string[] ProfileBaseKeys =
    [
        ThemeBase, FontFamilyBase, WidthPercentBase, ModeBase, FontSizeBase, LineSpacingBase,
        ParagraphSpacingBase, HapticsBase, AnimationsBase, KerningBase, BoldTextBase,
    ];

    public static string ThemeRaw
    {
        get => Store.GetString(K(ThemeBase)) ?? ReaderTheme.System.RawValue();
        set => Store.SetString(K(ThemeBase), value);
    }

    public static ReaderTheme Theme => ReaderThemeExtensions.FromRawValue(ThemeRaw) ?? ReaderTheme.System;

    public static string FontFamilyRaw
    {
        get => Store.GetString(K(FontFamilyBase)) ?? ReaderFontFamily.NewYork.RawValue();
        set => Store.SetString(K(FontFamilyBase), value);
    }

    public static ReaderFontFamily FontFamily => ReaderFontFamilyExtensions.FromRawValue(FontFamilyRaw) ?? ReaderFontFamily.NewYork;

    public static double WidthPercent
    {
        get => Store.GetDouble(K(WidthPercentBase), 70.0);
        set => Store.SetDouble(K(WidthPercentBase), value);
    }

    public static string ModeRaw
    {
        get => Store.GetString(K(ModeBase)) ?? ReadingMode.Continuous.RawValue();
        set => Store.SetString(K(ModeBase), value);
    }

    public static ReadingMode Mode => ReadingModeExtensions.FromRawValue(ModeRaw) ?? ReadingMode.Continuous;

    public static double FontSizePt
    {
        get => Store.GetDouble(K(FontSizeBase), ReaderMetrics.DefaultFontSize);
        set => Store.SetDouble(K(FontSizeBase), value);
    }

    public static double LineSpacingPt
    {
        get => Store.GetDouble(K(LineSpacingBase), ReaderMetrics.DefaultLineSpacing);
        set => Store.SetDouble(K(LineSpacingBase), value);
    }

    public static double ParagraphSpacingPt
    {
        get => Store.GetDouble(K(ParagraphSpacingBase), ReaderMetrics.DefaultParagraphSpacing);
        set => Store.SetDouble(K(ParagraphSpacingBase), value);
    }

    public static bool PageTurnHaptics
    {
        get => Store.GetBool(K(HapticsBase), false);
        set => Store.SetBool(K(HapticsBase), value);
    }

    public static bool PageTurnAnimations
    {
        get => Store.GetBool(K(AnimationsBase), true);
        set => Store.SetBool(K(AnimationsBase), value);
    }

    public static double KerningPt
    {
        get => Store.GetDouble(K(KerningBase), ReaderMetrics.DefaultKerning);
        set => Store.SetDouble(K(KerningBase), value);
    }

    public static bool BoldText
    {
        get => Store.GetBool(K(BoldTextBase), false);
        set => Store.SetBool(K(BoldTextBase), value);
    }

    public static bool TwoPageSpread
    {
        get => Store.GetBool(K(TwoPageSpreadBase), true);
        set => Store.SetBool(K(TwoPageSpreadBase), value);
    }

    public static double SpreadWidthPercent
    {
        get => Store.GetDouble(K(SpreadWidthBase), ReaderSpread.DefaultWidthPercent);
        set => Store.SetDouble(K(SpreadWidthBase), value);
    }

    public static bool KeepScreenAwake => Store.GetBool(KeepScreenAwakeKey, true);

    public static bool ShowImages => Store.GetBool(ShowImagesKey, false);

    /// <summary>The window's zoom as <c>MainWindow</c> draws it (clamped the same way),
    /// so the reader's text compensation matches.</summary>
    public static double ZoomScale => UiZoom.Clamped(Store.GetDouble(ZoomKey, UiZoom.ActualSize));

    public static string ActiveProfileName
    {
        get => Store.GetString(ReaderProfile.DeviceActiveProfileKey) ?? "Default";
        set => Store.SetString(ReaderProfile.DeviceActiveProfileKey, value);
    }

    public static string ProfilesJSON
    {
        get => Store.GetString(ReaderProfileSyncStore.ProfilesKey) ?? "";
        set => Store.SetString(ReaderProfileSyncStore.ProfilesKey, value);
    }

    /// <summary>Whether a changed settings key is one the reader reacts to.</summary>
    public static bool IsReaderKey(string key) =>
        key.StartsWith("reader.", StringComparison.Ordinal) || key == ZoomKey;

    /// <summary>Whether <paramref name="key"/> is this device's copy of <paramref name="baseKey"/>.</summary>
    public static bool Is(string key, string baseKey) => key == K(baseKey);

    /// <summary>Whether <paramref name="key"/> is one of the per-device typography keys.</summary>
    public static bool IsProfileKey(string key) => ProfileBaseKeys.Any(b => key == K(b));
}

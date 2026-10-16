using System.Runtime.InteropServices;

namespace Fanficly.UITests;

/// <summary>Which icon-font code points this PC's fonts can draw (GDI's
/// GetGlyphIndices), so the icon gallery test can name the ones that would
/// show as an empty box.</summary>
internal static partial class IconFont
{
    /// <summary>The app draws icons with "Segoe Fluent Icons,Segoe MDL2 Assets".</summary>
    public static readonly string[] Families = ["Segoe Fluent Icons", "Segoe MDL2 Assets"];

    /// <summary>The app's own font (Assets/FanficlyIcons.ttf), last in the app's
    /// list, for the icons the system fonts lack, at code points they don't use.</summary>
    public const string BundledFamily = "Fanficly Icons";

    /// <summary>True when the first installed family has a glyph for it (XAML
    /// uses the first family in the list that's installed). Code points in the
    /// Supplementary Private Use Area come from the bundled font.</summary>
    public static bool CanDraw(int codePoint, out string family)
    {
        if (codePoint >= 0xF0000)
        {
            family = BundledFamily;
            return LoadBundled() && HasGlyph(BundledFamily, codePoint) == true;
        }
        foreach (var name in Families)
        {
            var has = HasGlyph(name, codePoint);
            if (has is null) continue; // not installed
            family = name;
            return has.Value;
        }
        family = "none";
        return false;
    }

    private static bool? _bundledLoaded;

    /// <summary>Loads the app's bundled icon font for this process only.</summary>
    private static bool LoadBundled()
    {
        if (_bundledLoaded is { } loaded) return loaded;
        var path = Path.Combine(Path.GetDirectoryName(AppSession.ExePath)!, "Assets", "FanficlyIcons.ttf");
        _bundledLoaded = File.Exists(path) && AddFontResourceExW(path, 0x10 /* FR_PRIVATE */, IntPtr.Zero) > 0;
        return _bundledLoaded.Value;
    }

    /// <summary>Null when the family isn't installed.</summary>
    private static bool? HasGlyph(string family, int codePoint)
    {
        var dc = CreateCompatibleDC(IntPtr.Zero);
        var font = CreateFontW(-32, 0, 0, 0, 400, 0, 0, 0, 1 /* DEFAULT_CHARSET */, 0, 0, 0, 0, family);
        try
        {
            var old = SelectObject(dc, font);
            var face = new ushort[64];
            var len = GetTextFaceW(dc, face.Length, face);
            var name = new string(face.Take(Math.Max(0, len - 1)).Select(c => (char)c).ToArray());
            if (!name.Equals(family, StringComparison.OrdinalIgnoreCase)) return null;
            var indices = new ushort[1];
            var text = char.ConvertFromUtf32(codePoint);
            var n = GetGlyphIndicesW(dc, text, text.Length, indices, 1 /* GGI_MARK_NONEXISTING_GLYPHS */);
            SelectObject(dc, old);
            return n != unchecked((int)0xFFFFFFFF) && indices[0] != 0xFFFF;
        }
        finally
        {
            DeleteObject(font);
            DeleteDC(dc);
        }
    }

    [LibraryImport("gdi32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int AddFontResourceExW(string name, uint flags, IntPtr reserved);
    [LibraryImport("gdi32.dll")] private static partial IntPtr CreateCompatibleDC(IntPtr hdc);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool DeleteDC(IntPtr hdc);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool DeleteObject(IntPtr obj);
    [LibraryImport("gdi32.dll")] private static partial IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [LibraryImport("gdi32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr CreateFontW(int height, int width, int escapement, int orientation, int weight,
        uint italic, uint underline, uint strikeOut, uint charSet, uint outPrecision, uint clipPrecision,
        uint quality, uint pitchAndFamily, string face);
    [LibraryImport("gdi32.dll")] private static partial int GetTextFaceW(IntPtr hdc, int count, [Out] ushort[] face);
    [LibraryImport("gdi32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int GetGlyphIndicesW(IntPtr hdc, string text, int count, [Out] ushort[] indices, uint flags);
}

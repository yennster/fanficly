using System.Globalization;
using System.Text.RegularExpressions;

namespace Fanficly.Core;

/// <summary>
/// Which installed voice reads a work when no voice is picked in Settings: one
/// for the work's language, so a Spanish work isn't read by an English voice
/// (#184). Port of the Swift <c>SpeechLanguage</c> (in SpeechController.swift):
/// the same table and rules.
/// </summary>
public static partial class SpeechLanguage
{
    /// <summary>AO3's language names as a work shows them (<c>dd.language</c>), plus
    /// their English names and AO3's short codes, lowercased → a BCP-47 tag. Chinese
    /// is handled in <see cref="Tag"/>: AO3 has several.</summary>
    public static readonly IReadOnlyDictionary<string, string> Names = new Dictionary<string, string>
    {
        ["english"] = "en",
        ["español"] = "es", ["spanish"] = "es",
        ["français"] = "fr", ["french"] = "fr",
        ["deutsch"] = "de", ["german"] = "de",
        ["русский"] = "ru", ["russian"] = "ru",
        ["日本語"] = "ja", ["japanese"] = "ja",
        ["한국어"] = "ko", ["korean"] = "ko",
        ["português brasileiro"] = "pt-BR", ["ptbr"] = "pt-BR",
        ["português europeu"] = "pt-PT", ["ptpt"] = "pt-PT",
        ["português"] = "pt", ["portuguese"] = "pt",
        ["italiano"] = "it", ["italian"] = "it",
        ["polski"] = "pl", ["polish"] = "pl",
        ["nederlands"] = "nl", ["dutch"] = "nl",
        ["türkçe"] = "tr", ["turkish"] = "tr",
        ["tiếng việt"] = "vi", ["vietnamese"] = "vi",
        ["bahasa indonesia"] = "id", ["indonesian"] = "id",
        ["bahasa malaysia"] = "ms", ["malay"] = "ms",
        ["català"] = "ca", ["catalan"] = "ca",
        ["čeština"] = "cs", ["czech"] = "cs",
        ["dansk"] = "da", ["danish"] = "da",
        ["eesti keel"] = "et", ["eesti"] = "et", ["estonian"] = "et",
        ["suomi"] = "fi", ["finnish"] = "fi",
        ["ελληνικά"] = "el", ["greek"] = "el",
        ["עברית"] = "he", ["hebrew"] = "he",
        ["हिन्दी"] = "hi", ["hindi"] = "hi",
        ["magyar"] = "hu", ["hungarian"] = "hu",
        ["íslenska"] = "is", ["icelandic"] = "is",
        ["latviešu valoda"] = "lv", ["latviešu"] = "lv", ["latvian"] = "lv",
        ["lietuvių kalba"] = "lt", ["lietuvių"] = "lt", ["lithuanian"] = "lt",
        ["norsk"] = "nb", ["norwegian"] = "nb", ["no"] = "nb",
        ["română"] = "ro", ["romanian"] = "ro",
        ["slovenčina"] = "sk", ["slovak"] = "sk",
        ["slovenščina"] = "sl", ["slovenian"] = "sl", ["slv"] = "sl",
        ["svenska"] = "sv", ["swedish"] = "sv",
        ["ไทย"] = "th", ["thai"] = "th",
        ["українська"] = "uk", ["ukrainian"] = "uk",
        ["العربية"] = "ar", ["arabic"] = "ar",
        ["فارسی"] = "fa", ["persian"] = "fa",
        ["filipino"] = "fil",
        ["hrvatski"] = "hr", ["croatian"] = "hr",
        ["српски"] = "sr", ["serbian"] = "sr",
        ["български"] = "bg", ["bulgarian"] = "bg",
        ["gaeilge"] = "ga", ["irish"] = "ga",
        ["cymraeg"] = "cy", ["welsh"] = "cy",
        ["galego"] = "gl", ["galician"] = "gl",
        ["euskara"] = "eu", ["basque"] = "eu",
        ["esperanto"] = "eo",
        ["lingua latina"] = "la", ["latin"] = "la",
        ["kiswahili"] = "sw", ["swahili"] = "sw",
        ["বাংলা"] = "bn", ["bengali"] = "bn",
        ["தமிழ்"] = "ta", ["tamil"] = "ta",
        ["తెలుగు"] = "te", ["telugu"] = "te",
        ["ಕನ್ನಡ"] = "kn", ["kannada"] = "kn",
        ["മലയാളം"] = "ml", ["malayalam"] = "ml",
        ["मराठी"] = "mr", ["marathi"] = "mr",
        ["ગુજરાતી"] = "gu", ["gujarati"] = "gu",
        ["ਪੰਜਾਬੀ"] = "pa", ["punjabi"] = "pa",
        ["اردو"] = "ur", ["urdu"] = "ur",
        ["afrikaans"] = "af",
        ["shqip"] = "sq", ["albanian"] = "sq",
        ["bosanski"] = "bs", ["bosnian"] = "bs", ["bos"] = "bs",
        ["македонски"] = "mk", ["macedonian"] = "mk",
        ["zh"] = "zh-CN", ["yue"] = "zh-HK",
    };

    [GeneratedRegex(@"^[a-z]{2,3}(?:[-_][a-z0-9]{2,8})*$")]
    private static partial Regex CodePattern();

    /// <summary>The BCP-47 tag for a work's language: an AO3 name ("Español"), an
    /// English one, or a code already (an imported EPUB's <c>dc:language</c>).
    /// Null when it's empty or unknown, which leaves the system's voice.</summary>
    public static string? Tag(string? raw)
    {
        var v = (raw ?? "").Trim().ToLowerInvariant();
        if (v.Length == 0) return null;
        // AO3's Chinese languages: 中文-普通话 國語 (Mandarin), 中文-广东话 粵語
        // (Cantonese) and a few more, all written in Chinese characters.
        if (v.StartsWith("中文", StringComparison.Ordinal) || v.StartsWith("chinese", StringComparison.Ordinal)
            || v is "mandarin" or "cantonese")
            return v.Contains("广东") || v.Contains('粵') || v.Contains("cantonese") ? "zh-HK" : "zh-CN";
        if (Names.TryGetValue(v, out var tag)) return tag;
        if (CodePattern().IsMatch(v)) return v.Replace('_', '-');
        return null;
    }

    /// <summary>An installed voice, as the pure picker sees it. <c>Quality</c> ranks
    /// higher for better voices (Windows has no ranking, so its voices are all 0).</summary>
    public readonly record struct Voice(string Id, string Language, int Quality = 0);

    /// <summary>The language part of a tag ("pt" for "pt-BR"), with Norwegian's two
    /// codes as one.</summary>
    public static string Base(string tag)
    {
        var b = tag.ToLowerInvariant().Split('-', '_')[0];
        return b == "no" ? "nb" : b;
    }

    /// <summary>The voice to read a work in <paramref name="tag"/>'s language with, or
    /// null for the system's own voice: when the work is in the system voice's
    /// language (<paramref name="defaultLanguage"/>), or no installed voice speaks it.
    /// Prefers the exact dialect (pt-BR over pt-PT), then the better voice, then
    /// <paramref name="preferredId"/> (the system's pick for that language), then the
    /// id. A Mandarin work only falls back to a Cantonese voice when nothing else
    /// speaks Chinese.</summary>
    public static string? VoiceId(string? tag, IEnumerable<Voice> voices, string defaultLanguage, string? preferredId = null)
    {
        if (string.IsNullOrEmpty(tag)) return null;
        var want = tag.ToLowerInvariant();
        var wantBase = Base(want);
        if (wantBase == Base(defaultLanguage)) return null;
        int Dialect(Voice v)
        {
            var lang = v.Language.ToLowerInvariant().Replace('_', '-');
            if (lang == want) return 2;
            if (wantBase == "zh" && want != "zh-hk" && lang == "zh-hk") return 0;
            return 1;
        }
        return voices
            .Where(v => Base(v.Language) == wantBase)
            .OrderByDescending(Dialect)
            .ThenByDescending(v => v.Quality)
            .ThenByDescending(v => v.Id == preferredId)
            .ThenBy(v => v.Id, StringComparer.Ordinal)
            .Select(v => v.Id)
            .FirstOrDefault();
    }

    /// <summary>Settings' voice list order: the system language's voices first, then
    /// the rest by their languages' names (then the tag).</summary>
    public static IReadOnlyList<T> SortGroups<T>(IEnumerable<T> groups, Func<T, string> tag, Func<T, string> name, string systemLanguage) =>
        groups
            .OrderByDescending(g => Base(tag(g)) == Base(systemLanguage))
            .ThenBy(name, StringComparer.Create(CultureInfo.CurrentCulture, CompareOptions.IgnoreCase))
            .ThenBy(tag, StringComparer.Ordinal)
            .ToList();
}

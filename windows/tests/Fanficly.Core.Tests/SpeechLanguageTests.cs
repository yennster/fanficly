using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Listen reads a work with a voice for its language when no voice is
/// picked (#184). The Swift <c>SpeechLanguageTests</c> checks the same cases.</summary>
public class SpeechLanguageTests
{
    private static SpeechLanguage.Voice V(string id, string language, int quality = 0) => new(id, language, quality);

    [Theory]
    [InlineData("English", "en")]
    [InlineData("Español", "es")]
    [InlineData(" Français ", "fr")]
    [InlineData("Русский", "ru")]
    [InlineData("日本語", "ja")]
    [InlineData("Português brasileiro", "pt-BR")]
    [InlineData("Português europeu", "pt-PT")]
    [InlineData("Norsk", "nb")]
    [InlineData("中文-普通话 國語", "zh-CN")]
    [InlineData("中文-广东话 粵語", "zh-HK")]
    public void Ao3LanguageNamesMapToTags(string name, string tag) => Assert.Equal(tag, SpeechLanguage.Tag(name));

    [Theory]
    [InlineData("Spanish", "es")]
    [InlineData("en", "en")]
    [InlineData("pt_BR", "pt-br")]
    [InlineData("ptBR", "pt-BR")]
    [InlineData("zh", "zh-CN")]
    public void EnglishNamesAndCodesMapToTags(string name, string tag) => Assert.Equal(tag, SpeechLanguage.Tag(name));

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    [InlineData("Klingon (tlhIngan Hol)")]
    public void EmptyOrUnknownLanguageHasNoTag(string? name) => Assert.Null(SpeechLanguage.Tag(name));

    private static readonly SpeechLanguage.Voice[] Voices =
    [
        V("en-us", "en-US", 1),
        V("es-es", "es-ES", 1),
        V("es-mx-enhanced", "es-MX", 2),
        V("pt-pt", "pt-PT", 2),
        V("pt-br", "pt-BR", 1),
        V("zh-hk", "zh-HK", 3),
        V("zh-tw", "zh-TW", 1),
        V("nb-no", "nb-NO", 1),
    ];

    [Fact]
    public void AWorkInTheSystemLanguageKeepsTheSystemVoice()
    {
        Assert.Null(SpeechLanguage.VoiceId("en", Voices, "en-US"));
        Assert.Null(SpeechLanguage.VoiceId("es", Voices, "es-MX"));
    }

    [Fact]
    public void MandarinAndCantoneseAreDifferentLanguages()
    {
        Assert.Equal("zh-tw", SpeechLanguage.VoiceId("zh-CN", Voices, "zh-HK"));
        Assert.Equal("zh-hk", SpeechLanguage.VoiceId("zh-HK", Voices, "zh-CN"));
        Assert.Null(SpeechLanguage.VoiceId("zh-CN", Voices, "zh-TW"));
    }

    [Fact]
    public void AnotherLanguageGetsItsBestVoice()
    {
        Assert.Equal("es-mx-enhanced", SpeechLanguage.VoiceId("es", Voices, "en-US"));
        Assert.Equal("en-us", SpeechLanguage.VoiceId("en", Voices, "fr-FR"));
        Assert.Equal("nb-no", SpeechLanguage.VoiceId("nb", Voices, "en-US"));
    }

    [Fact]
    public void TheSystemsPickBreaksATie() =>
        Assert.Equal("b", SpeechLanguage.VoiceId("es", [V("a", "es-ES", 1), V("b", "es-MX", 1)], "en-US", preferredId: "b"));

    [Fact]
    public void TheExactDialectWinsOverABetterVoice() =>
        Assert.Equal("pt-br", SpeechLanguage.VoiceId("pt-BR", Voices, "en-US"));

    [Fact]
    public void MandarinAvoidsCantonese()
    {
        Assert.Equal("zh-tw", SpeechLanguage.VoiceId("zh-CN", Voices, "en-US"));
        Assert.Equal("zh-hk", SpeechLanguage.VoiceId("zh-HK", Voices, "en-US"));
        Assert.Equal("zh-hk", SpeechLanguage.VoiceId("zh-CN", [V("zh-hk", "zh-HK", 1)], "en-US"));
    }

    [Fact]
    public void NoVoiceForTheLanguageKeepsTheSystemVoice()
    {
        Assert.Null(SpeechLanguage.VoiceId("ja", Voices, "en-US"));
        Assert.Null(SpeechLanguage.VoiceId(null, Voices, "en-US"));
    }

    [Fact]
    public void SettingsListsTheSystemLanguageFirstThenByName()
    {
        var groups = new[]
        {
            ("fr-FR", "French (France)"), ("en-GB", "English (United Kingdom)"),
            ("de-DE", "German (Germany)"), ("en-US", "English (United States)"),
        };
        var sorted = SpeechLanguage.SortGroups(groups, g => g.Item1, g => g.Item2, "de-DE");
        Assert.Equal(["de-DE", "en-GB", "en-US", "fr-FR"], sorted.Select(g => g.Item1));
    }
}

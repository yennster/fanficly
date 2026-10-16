namespace Fanficly.Core;

/// <summary>One of AO3's media categories with a curated seed list of fandoms
/// (the live list comes from <c>/media/&lt;category&gt;/fandoms</c>).</summary>
/// <param name="Symbol">Icon id (SF Symbol name; the app maps it to a Fluent glyph).</param>
public sealed class FandomCategory(string id, string name, string symbol, IReadOnlyList<BrowseFandom> fandoms)
{
    public string Id { get; } = id;
    public string Name { get; } = name;
    public string Symbol { get; } = symbol;
    public IReadOnlyList<BrowseFandom> Fandoms { get; } = fandoms;
    public string AO3CanonicalName => Name;
}

public sealed record BrowseFandom
{
    public string CanonicalName { get; }
    public string DisplayName { get; }
    /// <summary>AO3's listed work count for this fandom (from the
    /// <c>/media/.../fandoms</c> page), when known. Drives the live "Popular
    /// fandoms" ranking; null for curated seed entries.</summary>
    public int? WorkCount { get; }
    public string Id => CanonicalName;

    public BrowseFandom(string display, string? canonical = null, int? workCount = null)
    {
        DisplayName = display;
        CanonicalName = canonical ?? display;
        WorkCount = workCount;
    }
}

/// <summary>Curated "popular" tags for the Popular tab. AO3 has no
/// popular/trending API, so these are hand-picked canonical tag names (kept in
/// AO3's exact canonical form so the tag search resolves). Also the Popular
/// tab's offline fallback.</summary>
public static class PopularTags
{
    public static readonly IReadOnlyList<string> Fandoms =
    [
        "Harry Potter - J. K. Rowling",
        "Marvel Cinematic Universe",
        "Supernatural (TV 2005)",
        "Boku no Hero Academia | My Hero Academia",
        "Genshin Impact (Video Game)",
        "Good Omens (TV)",
        "Stranger Things (TV 2016)",
        "방탄소년단 | Bangtan Boys | BTS",
        "魔道祖师 - 墨香铜臭 | Módào Zǔshī - Mòxiāng Tóngxiù",
        "Star Wars - All Media Types",
        "Dragon Age - All Media Types",
        "Critical Role (Web Series)",
        "Our Flag Means Death (TV)",
        "Batman - All Media Types",
        "Naruto",
    ];

    public static readonly IReadOnlyList<string> Ships =
    [
        "Draco Malfoy/Harry Potter",
        "Hermione Granger/Draco Malfoy",
        "Castiel/Dean Winchester",
        "Steve Rogers/Tony Stark",
        "James \"Bucky\" Barnes/Steve Rogers",
        "Sherlock Holmes/John Watson",
        "Aziraphale/Crowley (Good Omens)",
        "Lan Zhan | Lan Wangji/Wei Ying | Wei Wuxian",
        "Katsuki Bakugou/Izuku Midoriya",
        "Nico di Angelo/Will Solace",
        "Anakin Skywalker/Obi-Wan Kenobi",
        "Buck/Eddie",
    ];

    public static readonly IReadOnlyList<string> Characters =
    [
        "Harry Potter",
        "Hermione Granger",
        "Draco Malfoy",
        "Dean Winchester",
        "Castiel (Supernatural)",
        "Tony Stark",
        "Steve Rogers",
        "Loki (Marvel)",
        "Sherlock Holmes",
        "Wei Ying | Wei Wuxian",
        "Katsuki Bakugou",
        "Percy Jackson",
    ];
}

public static class FandomCatalog
{
    /// <summary>Icon id for a fandom, matching the Browse category it belongs to.
    /// Uses an exact catalog match first, then AO3's canonical-name type
    /// suffixes ("(Video Game)", "(TV)", "(Movies)", …).</summary>
    public static string Symbol(string fandom)
    {
        if (SymbolByFandom.TryGetValue(fandom, out var known)) return known;
        var lower = fandom.ToLowerInvariant();
        bool Has(params string[] subs) => subs.Any(lower.Contains);
        if (Has("(anime", "manga", "アニメ", "| my hero", "no kyojin")) return "sparkles";
        if (Has("(video game", "(visual novel", "(vrchat")) return "gamecontroller";
        if (Has("(podcast", "(radio", "(audio")) return "headphones";
        if (Has("musical", "broadway", "- miranda", "lloyd webber")) return "theatermasks";
        if (Has("cinematic universe", "movies)", "(movie", "(film")) return "film";
        if (Has("(cartoon", "(web series", "(webcomic", "(web comic")) return "paintbrush.pointed";
        if (Has("(tv", " tv ", "us tv)", "uk tv)")) return "tv";
        if (Has("rpf")) return "person.fill";
        if (Has("(band", "(musician", "k-pop", "kpop", "방탄소년단")) return "music.note";
        return "book.closed";
    }

    // Built on first use: a field initializer here would run before `All`
    // (declared below) is assigned and throw from the type initializer.
    private static Dictionary<string, string> SymbolByFandom => s_symbolByFandom ??= BuildSymbolMap();
    private static Dictionary<string, string>? s_symbolByFandom;

    private static Dictionary<string, string> BuildSymbolMap()
    {
        var map = new Dictionary<string, string>();
        foreach (var category in All)
            foreach (var fandom in category.Fandoms) map[fandom.CanonicalName] = category.Symbol;
        return map;
    }

    public static readonly IReadOnlyList<FandomCategory> All =
    [
        new FandomCategory(
            id: "anime-manga",
            name: "Anime & Manga",
            symbol: "sparkles",
            fandoms: [
                new BrowseFandom("Boku no Hero Academia | My Hero Academia"),
                new BrowseFandom("Haikyuu!!"),
                new BrowseFandom("Shingeki no Kyojin | Attack on Titan"),
                new BrowseFandom("Naruto"),
                new BrowseFandom("One Piece"),
                new BrowseFandom("Jujutsu Kaisen"),
                new BrowseFandom("Demon Slayer | Kimetsu no Yaiba"),
                new BrowseFandom("Yuri!!! on Ice"),
                new BrowseFandom("Death Note"),
                new BrowseFandom("Sailor Moon"),
                new BrowseFandom("Hunter X Hunter"),
                new BrowseFandom("Tokyo Revengers"),
                new BrowseFandom("Chainsaw Man"),
                new BrowseFandom("Spy x Family"),
            ]
        ),
        new FandomCategory(
            id: "books",
            name: "Books & Literature",
            symbol: "book.closed",
            fandoms: [
                new BrowseFandom("Harry Potter - J. K. Rowling"),
                new BrowseFandom("The Lord of the Rings - J. R. R. Tolkien"),
                new BrowseFandom("Twilight Series - Stephenie Meyer"),
                new BrowseFandom("Hunger Games Series - All Media Types"),
                new BrowseFandom("A Song of Ice and Fire & Related Fandoms"),
                new BrowseFandom("Percy Jackson and the Olympians - Rick Riordan"),
                new BrowseFandom("The Mortal Instruments - Cassandra Clare"),
                new BrowseFandom("Discworld - Terry Pratchett"),
                new BrowseFandom("Dune - Frank Herbert"),
                new BrowseFandom("Six of Crows Series - Leigh Bardugo"),
                new BrowseFandom("The Locked Tomb - Tamsyn Muir"),
                new BrowseFandom("The Inheritance Cycle - Christopher Paolini"),
            ]
        ),
        new FandomCategory(
            id: "cartoons-comics",
            name: "Cartoons & Comics & Graphic Novels",
            symbol: "paintbrush.pointed",
            fandoms: [
                new BrowseFandom("Marvel"),
                new BrowseFandom("DCU"),
                new BrowseFandom("Avatar: The Last Airbender"),
                new BrowseFandom("She-Ra and the Princesses of Power (2018)"),
                new BrowseFandom("Steven Universe (Cartoon)"),
                new BrowseFandom("Adventure Time (Cartoon)"),
                new BrowseFandom("Gravity Falls"),
                new BrowseFandom("The Legend of Korra"),
                new BrowseFandom("The Owl House (Cartoon)"),
                new BrowseFandom("Hazbin Hotel (Cartoon)"),
                new BrowseFandom("Helluva Boss (Web Series)"),
                new BrowseFandom("Arcane: League of Legends (Cartoon 2021)"),
            ]
        ),
        new FandomCategory(
            id: "celebrities-rpf",
            name: "Celebrities & Real People",
            symbol: "person.fill",
            fandoms: [
                new BrowseFandom("Formula 1 RPF"),
                new BrowseFandom("Hockey RPF"),
                new BrowseFandom("Football RPF"),
                new BrowseFandom("Hollywood RPF"),
                new BrowseFandom("Music RPF"),
                new BrowseFandom("Critical Role RPF"),
            ]
        ),
        new FandomCategory(
            id: "movies",
            name: "Movies",
            symbol: "film",
            fandoms: [
                new BrowseFandom("The Avengers (Marvel Movies)"),
                new BrowseFandom("Marvel Cinematic Universe"),
                new BrowseFandom("Star Wars - All Media Types"),
                new BrowseFandom("The Lord of the Rings (Movies)"),
                new BrowseFandom("Harry Potter (Movies)"),
                new BrowseFandom("Pirates of the Caribbean (Movies)"),
                new BrowseFandom("Inception (2010)"),
                new BrowseFandom("Pacific Rim (Movies)"),
                new BrowseFandom("Top Gun (Movies)"),
                new BrowseFandom("Glass Onion: A Knives Out Mystery (2022)"),
                new BrowseFandom("Dune (Movies - Villeneuve)"),
                new BrowseFandom("Spider-Man: Across the Spider-Verse (2023)"),
            ]
        ),
        new FandomCategory(
            id: "music-bands",
            name: "Music & Bands",
            symbol: "music.note",
            fandoms: [
                new BrowseFandom("방탄소년단 | Bangtan Boys | BTS"),
                new BrowseFandom("Stray Kids (Band)"),
                new BrowseFandom("ATEEZ (Band)"),
                new BrowseFandom("ENHYPEN (Band)"),
                new BrowseFandom("SEVENTEEN (Band)"),
                new BrowseFandom("TWICE (Band)"),
                new BrowseFandom("My Chemical Romance"),
                new BrowseFandom("Twenty One Pilots"),
                new BrowseFandom("Fall Out Boy"),
                new BrowseFandom("Taylor Swift (Musician)"),
            ]
        ),
        new FandomCategory(
            id: "other-media",
            name: "Other Media",
            symbol: "headphones",
            fandoms: [
                new BrowseFandom("The Magnus Archives (Podcast)"),
                new BrowseFandom("The Magnus Protocol (Podcast)"),
                new BrowseFandom("Wolf 359 (Radio)"),
                new BrowseFandom("Welcome to Night Vale"),
                new BrowseFandom("Critical Role (Web Series)"),
                new BrowseFandom("Dimension 20 (Web Series)"),
                new BrowseFandom("The Adventure Zone (Podcast)"),
                new BrowseFandom("Malevolent (Podcast)"),
            ]
        ),
        new FandomCategory(
            id: "theater",
            name: "Theater",
            symbol: "theatermasks",
            fandoms: [
                new BrowseFandom("Hamilton - Miranda"),
                new BrowseFandom("Six: The Musical - Marlow & Moss"),
                new BrowseFandom("Hadestown - Mitchell"),
                new BrowseFandom("Be More Chill - Iconis/Tracz"),
                new BrowseFandom("Heathers: The Musical - Murphy/O'Keefe"),
                new BrowseFandom("Wicked - Schwartz/Holzman"),
                new BrowseFandom("The Phantom of the Opera - Lloyd Webber/Hart/Stilgoe"),
                new BrowseFandom("Les Misérables - All Media Types"),
                new BrowseFandom("Dear Evan Hansen - Pasek & Paul/Levenson"),
                new BrowseFandom("Epic - The Musical"),
            ]
        ),
        new FandomCategory(
            id: "tv-shows",
            name: "TV Shows",
            symbol: "tv",
            fandoms: [
                new BrowseFandom("Supernatural (TV 2005)"),
                new BrowseFandom("Sherlock (TV)"),
                new BrowseFandom("Doctor Who (2005)"),
                new BrowseFandom("Stranger Things (TV 2016)"),
                new BrowseFandom("Good Omens (TV)"),
                new BrowseFandom("Wednesday (TV 2022)"),
                new BrowseFandom("Bridgerton (TV)"),
                new BrowseFandom("Our Flag Means Death (TV)"),
                new BrowseFandom("Game of Thrones (TV)"),
                new BrowseFandom("House of the Dragon (TV)"),
                new BrowseFandom("Buffy the Vampire Slayer (TV)"),
                new BrowseFandom("Interview with the Vampire (TV 2022)"),
                new BrowseFandom("Ted Lasso (TV)"),
                new BrowseFandom("The Bear (TV 2022)"),
                new BrowseFandom("The Witcher (TV)"),
                new BrowseFandom("9-1-1 (TV)"),
            ]
        ),
        new FandomCategory(
            id: "video-games",
            name: "Video Games",
            symbol: "gamecontroller",
            fandoms: [
                new BrowseFandom("Genshin Impact (Video Game)"),
                new BrowseFandom("Honkai: Star Rail (Video Game)"),
                new BrowseFandom("Persona 5"),
                new BrowseFandom("Fire Emblem: Three Houses"),
                new BrowseFandom("Final Fantasy XIV Online"),
                new BrowseFandom("Pokemon - All Media Types"),
                new BrowseFandom("The Legend of Zelda: Tears of the Kingdom"),
                new BrowseFandom("The Legend of Zelda: Breath of the Wild"),
                new BrowseFandom("Mass Effect Trilogy"),
                new BrowseFandom("Dragon Age - All Media Types"),
                new BrowseFandom("Overwatch (Video Game)"),
                new BrowseFandom("League of Legends"),
                new BrowseFandom("Baldur's Gate 3 (Video Game 2023)"),
                new BrowseFandom("Hades (Video Game 2018)"),
                new BrowseFandom("Stardew Valley (Video Game)"),
            ]
        ),
    ];
}

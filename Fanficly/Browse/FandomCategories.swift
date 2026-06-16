import Foundation

public struct FandomCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let symbol: String
    public let fandoms: [BrowseFandom]

    public var ao3CanonicalName: String { name }
}

public struct BrowseFandom: Identifiable, Hashable, Sendable {
    public let canonicalName: String
    public let displayName: String
    public var id: String { canonicalName }

    public init(_ display: String, canonical: String? = nil) {
        self.displayName = display
        self.canonicalName = canonical ?? display
    }
}

/// Curated "popular" tags for the Popular tab. AO3 has no popular/trending
/// API, so these are hand-picked canonical tag names (kept in AO3's exact
/// canonical form so the tag search resolves). Each links to that tag's works
/// sorted by kudos. Refreshed periodically by hand.
enum PopularTags {
    static let fandoms: [String] = [
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
    ]

    static let ships: [String] = [
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
    ]

    static let characters: [String] = [
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
    ]
}

enum FandomCatalog {
    /// SF Symbol for a fandom, matching the Browse category it belongs to.
    /// Uses an exact catalog match first, then AO3's canonical-name type
    /// suffixes ("(Video Game)", "(TV)", "(Movies)", …).
    static func symbol(for fandom: String) -> String {
        if let known = symbolByFandom[fandom] { return known }
        let lower = fandom.lowercased()
        func has(_ subs: String...) -> Bool { subs.contains { lower.contains($0) } }
        if has("(anime", "manga", "アニメ", "| my hero", "no kyojin")  { return "sparkles" }
        if has("(video game", "(visual novel", "(vrchat")              { return "gamecontroller" }
        if has("(podcast", "(radio", "(audio")                         { return "headphones" }
        if has("musical", "broadway", "- miranda", "lloyd webber")     { return "theatermasks" }
        if has("cinematic universe", "movies)", "(movie", "(film")     { return "film" }
        if has("(cartoon", "(web series", "(webcomic", "(web comic")   { return "paintbrush.pointed" }
        if has("(tv", " tv ", "us tv)", "uk tv)")                      { return "tv" }
        if has("rpf")                                                  { return "person.fill" }
        if has("(band", "(musician", "k-pop", "kpop", "방탄소년단")      { return "music.note" }
        return "book.closed"
    }

    private static let symbolByFandom: [String: String] = {
        var map: [String: String] = [:]
        for category in all {
            for fandom in category.fandoms { map[fandom.canonicalName] = category.symbol }
        }
        return map
    }()

    static let all: [FandomCategory] = [
        FandomCategory(
            id: "anime-manga",
            name: "Anime & Manga",
            symbol: "sparkles",
            fandoms: [
                BrowseFandom("Boku no Hero Academia | My Hero Academia"),
                BrowseFandom("Haikyuu!!"),
                BrowseFandom("Shingeki no Kyojin | Attack on Titan"),
                BrowseFandom("Naruto"),
                BrowseFandom("One Piece"),
                BrowseFandom("Jujutsu Kaisen"),
                BrowseFandom("Demon Slayer | Kimetsu no Yaiba"),
                BrowseFandom("Yuri!!! on Ice"),
                BrowseFandom("Death Note"),
                BrowseFandom("Sailor Moon"),
                BrowseFandom("Hunter X Hunter"),
                BrowseFandom("Tokyo Revengers"),
                BrowseFandom("Chainsaw Man"),
                BrowseFandom("Spy x Family"),
            ]
        ),
        FandomCategory(
            id: "books",
            name: "Books & Literature",
            symbol: "book.closed",
            fandoms: [
                BrowseFandom("Harry Potter - J. K. Rowling"),
                BrowseFandom("The Lord of the Rings - J. R. R. Tolkien"),
                BrowseFandom("Twilight Series - Stephenie Meyer"),
                BrowseFandom("Hunger Games Series - All Media Types"),
                BrowseFandom("A Song of Ice and Fire & Related Fandoms"),
                BrowseFandom("Percy Jackson and the Olympians - Rick Riordan"),
                BrowseFandom("The Mortal Instruments - Cassandra Clare"),
                BrowseFandom("Discworld - Terry Pratchett"),
                BrowseFandom("Dune - Frank Herbert"),
                BrowseFandom("Six of Crows Series - Leigh Bardugo"),
                BrowseFandom("The Locked Tomb - Tamsyn Muir"),
                BrowseFandom("The Inheritance Cycle - Christopher Paolini"),
            ]
        ),
        FandomCategory(
            id: "cartoons-comics",
            name: "Cartoons & Comics & Graphic Novels",
            symbol: "paintbrush.pointed",
            fandoms: [
                BrowseFandom("Marvel"),
                BrowseFandom("DCU"),
                BrowseFandom("Avatar: The Last Airbender"),
                BrowseFandom("She-Ra and the Princesses of Power (2018)"),
                BrowseFandom("Steven Universe (Cartoon)"),
                BrowseFandom("Adventure Time (Cartoon)"),
                BrowseFandom("Gravity Falls"),
                BrowseFandom("The Legend of Korra"),
                BrowseFandom("The Owl House (Cartoon)"),
                BrowseFandom("Hazbin Hotel (Cartoon)"),
                BrowseFandom("Helluva Boss (Web Series)"),
                BrowseFandom("Arcane: League of Legends (Cartoon 2021)"),
            ]
        ),
        FandomCategory(
            id: "celebrities-rpf",
            name: "Celebrities & Real People",
            symbol: "person.fill",
            fandoms: [
                BrowseFandom("Formula 1 RPF"),
                BrowseFandom("Hockey RPF"),
                BrowseFandom("Football RPF"),
                BrowseFandom("Hollywood RPF"),
                BrowseFandom("Music RPF"),
                BrowseFandom("Critical Role RPF"),
            ]
        ),
        FandomCategory(
            id: "movies",
            name: "Movies",
            symbol: "film",
            fandoms: [
                BrowseFandom("The Avengers (Marvel Movies)"),
                BrowseFandom("Marvel Cinematic Universe"),
                BrowseFandom("Star Wars - All Media Types"),
                BrowseFandom("The Lord of the Rings (Movies)"),
                BrowseFandom("Harry Potter (Movies)"),
                BrowseFandom("Pirates of the Caribbean (Movies)"),
                BrowseFandom("Inception (2010)"),
                BrowseFandom("Pacific Rim (Movies)"),
                BrowseFandom("Top Gun (Movies)"),
                BrowseFandom("Glass Onion: A Knives Out Mystery (2022)"),
                BrowseFandom("Dune (Movies - Villeneuve)"),
                BrowseFandom("Spider-Man: Across the Spider-Verse (2023)"),
            ]
        ),
        FandomCategory(
            id: "music-bands",
            name: "Music & Bands",
            symbol: "music.note",
            fandoms: [
                BrowseFandom("방탄소년단 | Bangtan Boys | BTS"),
                BrowseFandom("Stray Kids (Band)"),
                BrowseFandom("ATEEZ (Band)"),
                BrowseFandom("ENHYPEN (Band)"),
                BrowseFandom("SEVENTEEN (Band)"),
                BrowseFandom("TWICE (Band)"),
                BrowseFandom("My Chemical Romance"),
                BrowseFandom("Twenty One Pilots"),
                BrowseFandom("Fall Out Boy"),
                BrowseFandom("Taylor Swift (Musician)"),
            ]
        ),
        FandomCategory(
            id: "other-media",
            name: "Other Media",
            symbol: "headphones",
            fandoms: [
                BrowseFandom("The Magnus Archives (Podcast)"),
                BrowseFandom("The Magnus Protocol (Podcast)"),
                BrowseFandom("Wolf 359 (Radio)"),
                BrowseFandom("Welcome to Night Vale"),
                BrowseFandom("Critical Role (Web Series)"),
                BrowseFandom("Dimension 20 (Web Series)"),
                BrowseFandom("The Adventure Zone (Podcast)"),
                BrowseFandom("Malevolent (Podcast)"),
            ]
        ),
        FandomCategory(
            id: "theater",
            name: "Theater",
            symbol: "theatermasks",
            fandoms: [
                BrowseFandom("Hamilton - Miranda"),
                BrowseFandom("Six: The Musical - Marlow & Moss"),
                BrowseFandom("Hadestown - Mitchell"),
                BrowseFandom("Be More Chill - Iconis/Tracz"),
                BrowseFandom("Heathers: The Musical - Murphy/O'Keefe"),
                BrowseFandom("Wicked - Schwartz/Holzman"),
                BrowseFandom("The Phantom of the Opera - Lloyd Webber/Hart/Stilgoe"),
                BrowseFandom("Les Misérables - All Media Types"),
                BrowseFandom("Dear Evan Hansen - Pasek & Paul/Levenson"),
                BrowseFandom("Epic - The Musical"),
            ]
        ),
        FandomCategory(
            id: "tv-shows",
            name: "TV Shows",
            symbol: "tv",
            fandoms: [
                BrowseFandom("Supernatural (TV 2005)"),
                BrowseFandom("Sherlock (TV)"),
                BrowseFandom("Doctor Who (2005)"),
                BrowseFandom("Stranger Things (TV 2016)"),
                BrowseFandom("Good Omens (TV)"),
                BrowseFandom("Wednesday (TV 2022)"),
                BrowseFandom("Bridgerton (TV)"),
                BrowseFandom("Our Flag Means Death (TV)"),
                BrowseFandom("Game of Thrones (TV)"),
                BrowseFandom("House of the Dragon (TV)"),
                BrowseFandom("Buffy the Vampire Slayer (TV)"),
                BrowseFandom("Interview with the Vampire (TV 2022)"),
                BrowseFandom("Ted Lasso (TV)"),
                BrowseFandom("The Bear (TV 2022)"),
                BrowseFandom("The Witcher (TV)"),
                BrowseFandom("9-1-1 (TV)"),
            ]
        ),
        FandomCategory(
            id: "video-games",
            name: "Video Games",
            symbol: "gamecontroller",
            fandoms: [
                BrowseFandom("Genshin Impact (Video Game)"),
                BrowseFandom("Honkai: Star Rail (Video Game)"),
                BrowseFandom("Persona 5"),
                BrowseFandom("Fire Emblem: Three Houses"),
                BrowseFandom("Final Fantasy XIV Online"),
                BrowseFandom("Pokemon - All Media Types"),
                BrowseFandom("The Legend of Zelda: Tears of the Kingdom"),
                BrowseFandom("The Legend of Zelda: Breath of the Wild"),
                BrowseFandom("Mass Effect Trilogy"),
                BrowseFandom("Dragon Age - All Media Types"),
                BrowseFandom("Overwatch (Video Game)"),
                BrowseFandom("League of Legends"),
                BrowseFandom("Baldur's Gate 3 (Video Game 2023)"),
                BrowseFandom("Hades (Video Game 2018)"),
                BrowseFandom("Stardew Valley (Video Game)"),
            ]
        ),
    ]
}

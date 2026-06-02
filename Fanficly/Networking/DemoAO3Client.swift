import Foundation

/// A fully offline `AO3ClientProtocol` backed by a curated, all-ages catalog of
/// **original** (non-fandom) works. Used only for App Store screenshots and
/// manual demos — selected at launch when the process is started with the
/// `-demoMode` argument (see `FanficlyApp.isDemoMode`). Nothing here ever ships
/// in a normal run, and no request ever touches the network.
///
/// Everything is rated General/Teen with no archive warnings, and the fandoms
/// are invented "(Original Work)" titles, so screenshots never surface mature or
/// explicit third-party content.
public final class DemoAO3Client: AO3ClientProtocol, @unchecked Sendable {
    public init() {}

    public func login(username: String, password: String) async throws {}
    public func logout() async {}
    public func currentUsername() async -> String? { "demo_reader" }

    public func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults {
        var works = DemoCatalog.works

        // Light, best-effort filtering so typing a prompt narrows the list.
        if !filters.ratings.isEmpty {
            let names = Set(filters.ratings.map(\.displayName))
            works = works.filter { names.contains($0.rating) }
        }
        if !filters.fandomNames.isEmpty {
            let wanted = filters.fandomNames.map { $0.lowercased() }
            works = works.filter { w in
                w.fandoms.contains { f in wanted.contains { f.lowercased().contains($0) } }
            }
        }
        if !filters.freeformNames.isEmpty {
            let wanted = filters.freeformNames.map { $0.lowercased() }
            works = works.filter { w in
                w.freeforms.contains { t in wanted.contains { t.lowercased().contains($0) } }
            }
        }
        if !filters.categories.isEmpty {
            let names = Set(filters.categories.map(\.displayName))
            works = works.filter { !Set($0.categories).isDisjoint(with: names) }
        }
        switch filters.complete {
        case .yes: works = works.filter(\.isComplete)
        case .no:  works = works.filter { !$0.isComplete }
        case .any: break
        }

        // If a free-text query is present and nothing matched the structured
        // filters, fall back to the full catalog so the results screen is never
        // empty in a demo.
        if works.isEmpty { works = DemoCatalog.works }

        return AO3SearchResults(works: works, totalPages: 1, currentPage: page)
    }

    public func fetchWork(id: Int) async throws -> AO3WorkPayload {
        DemoCatalog.payload(for: id)
    }

    public func fetchWorkMetadata(id: Int) async throws -> AO3WorkMetadata {
        let w = DemoCatalog.summary(for: id)
        return AO3WorkMetadata(id: id, chapterCount: w.chapterCount,
                               totalChapters: w.totalChapters, updatedAt: w.updatedAt)
    }

    public func fetchSubscriptions(username: String) async throws -> [AO3Subscription] {
        DemoCatalog.subscriptions
    }

    public func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom] {
        DemoCatalog.fandoms
    }

    public func autocomplete(field: AO3AutocompleteField, term: String) async throws -> [String] {
        [term]
    }

    public func downloadEPUB(workId: Int) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(workId).epub")
    }

    public func exportWork(workId: Int, format: WorkExportFormat, filename: String) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(filename).\(format.ext)")
    }

    public func subscribeToWork(workId: Int) async throws {}
}

// MARK: - Curated demo catalog

enum DemoCatalog {
    /// The eight all-ages works shown across Search, Browse, Library, Recently
    /// Viewed and Subscriptions. Order doubles as the default search ranking.
    static let works: [AO3WorkSummary] = [
        make(90001, "The Long Way Home", "wanderlight",
             summary: "Stranded a galaxy from home, a salvage crew of strangers learns that the fastest route back is the one you build together.",
             rating: "General Audiences", categories: ["Gen"],
             fandoms: ["Starbound Atlas (Original Work)"],
             relationships: [], characters: ["Captain Reyes", "Wira", "Ode"],
             freeforms: ["Found Family", "Slow Burn", "Hurt/Comfort", "Adventure"],
             words: 48_213, chapters: 12, total: 12, kudos: 3204, hits: 51_882, complete: true, daysAgo: 4),
        make(90002, "Letters Never Sent", "paperboats",
             summary: "Two lighthouse keepers on opposite headlands write the letters they never quite dare to deliver.",
             rating: "Teen And Up Audiences", categories: ["F/M"],
             fandoms: ["The Lighthouse Keepers (Original Work)"],
             relationships: ["Mara & Soren"], characters: ["Mara", "Soren"],
             freeforms: ["Epistolary", "Mutual Pining", "Slow Burn", "Soft"],
             words: 22_150, chapters: 8, total: 8, kudos: 1890, hits: 28_400, complete: true, daysAgo: 9),
        make(90003, "Of Maps and Mistakes", "tealeaf",
             summary: "A disgraced cartographer and the rival who got her exiled are assigned to chart the same impossible coastline.",
             rating: "General Audiences", categories: ["Gen"],
             fandoms: ["Cartographer's Guild (Original Work)"],
             relationships: [], characters: ["Isolde", "Brannoch"],
             freeforms: ["Enemies to Lovers", "Adventure", "Banter", "Slow Burn"],
             words: 64_002, chapters: 15, total: 20, kudos: 5120, hits: 88_120, complete: false, daysAgo: 1),
        make(90004, "Coffee, Two Sugars", "morningmugs",
             summary: "The new barista keeps spelling Theo's name wrong. Theo keeps coming back anyway.",
             rating: "Teen And Up Audiences", categories: ["M/M"],
             fandoms: ["Brewhaven (Original Work)"],
             relationships: ["Eli & Theo"], characters: ["Eli", "Theo"],
             freeforms: ["Coffee Shop AU", "Fluff", "First Meetings", "Slow Burn"],
             words: 12_400, chapters: 3, total: 3, kudos: 2750, hits: 40_310, complete: true, daysAgo: 6),
        make(90005, "The Understudy", "stagelights",
             summary: "When the lead breaks her ankle on opening night, the understudy nobody believed in finally steps into the light.",
             rating: "General Audiences", categories: ["Gen"],
             fandoms: ["Marigold Theatre (Original Work)"],
             relationships: [], characters: ["Priya", "Daniel"],
             freeforms: ["Theatre", "Friendship", "Found Family", "Hurt/Comfort"],
             words: 31_200, chapters: 9, total: 9, kudos: 1450, hits: 19_905, complete: true, daysAgo: 14),
        make(90006, "Gardens in Winter", "frostfern",
             summary: "Two neighbours, one shared greenhouse, and a whole cold season to figure out what's growing between them.",
             rating: "Teen And Up Audiences", categories: ["F/F"],
             fandoms: ["Hollowdale (Original Work)"],
             relationships: ["Ivy & Wren"], characters: ["Ivy", "Wren"],
             freeforms: ["Cottagecore", "Soft", "Found Family", "Slow Burn"],
             words: 27_800, chapters: 7, total: 7, kudos: 3380, hits: 44_770, complete: true, daysAgo: 3),
        make(90007, "Signal Lost", "orbital",
             summary: "The only two researchers left awake on a sleeper ship trade messages across a failing comms link to keep each other sane.",
             rating: "Teen And Up Audiences", categories: ["Gen"],
             fandoms: ["Deep Field (Original Work)"],
             relationships: [], characters: ["Yuki", "Cole"],
             freeforms: ["Science Fiction", "Slow Burn", "Hurt/Comfort", "Space"],
             words: 41_000, chapters: 11, total: 16, kudos: 2210, hits: 33_540, complete: false, daysAgo: 2),
        make(90008, "The Baker's Dozen", "flourchild",
             summary: "A failing small-town bakery, twelve impossible orders, and one very stubborn pastry chef who refuses to close.",
             rating: "General Audiences", categories: ["Gen"],
             fandoms: ["Sweetbriar Lane (Original Work)"],
             relationships: [], characters: ["Margot", "Sam"],
             freeforms: ["Small Town", "Baking", "Fluff", "Found Family"],
             words: 19_500, chapters: 6, total: 6, kudos: 1675, hits: 22_115, complete: true, daysAgo: 11),
    ]

    static let fandoms: [BrowseFandom] = works.map { BrowseFandom($0.fandoms.first ?? "Original Work") }

    static let subscriptions: [AO3Subscription] = [
        AO3Subscription(kind: .work, resourceId: "90003", title: "Of Maps and Mistakes", author: "tealeaf"),
        AO3Subscription(kind: .work, resourceId: "90007", title: "Signal Lost", author: "orbital"),
        AO3Subscription(kind: .user, resourceId: "wanderlight", title: "wanderlight", author: nil),
    ]

    static func summary(for id: Int) -> AO3WorkSummary {
        works.first { $0.id == id } ?? works[0]
    }

    static func payload(for id: Int) -> AO3WorkPayload {
        let s = summary(for: id)
        let count = max(1, min(s.chapterCount, 3)) // render up to 3 chapters for the reader
        let chapters = (1...count).map { idx in
            AO3ChapterPayload(index: idx,
                              title: chapterTitles[(idx - 1) % chapterTitles.count],
                              bodyHTML: chapterHTML(work: s, chapter: idx))
        }
        return AO3WorkPayload(summary: s, chapters: chapters)
    }

    // MARK: Helpers

    private static let chapterTitles = ["Landfall", "What the Tide Brought", "The Long Way Home"]

    private static func make(
        _ id: Int, _ title: String, _ author: String, summary: String,
        rating: String, categories: [String], fandoms: [String],
        relationships: [String], characters: [String], freeforms: [String],
        words: Int, chapters: Int, total: Int, kudos: Int, hits: Int,
        complete: Bool, daysAgo: Int
    ) -> AO3WorkSummary {
        AO3WorkSummary(
            id: id, title: title, author: author, summary: summary,
            rating: rating, warnings: ["No Archive Warnings Apply"],
            categories: categories, fandoms: fandoms, characters: characters,
            relationships: relationships, freeforms: freeforms,
            wordCount: words, chapterCount: complete ? total : chapters,
            totalChapters: total, language: "English", kudos: kudos, hits: hits,
            isComplete: complete,
            updatedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)
        )
    }

    /// A fixed reference instant so the demo is deterministic (no `Date()` calls).
    private static let referenceDate = Date(timeIntervalSince1970: 1_780_000_000) // ~mid 2026

    /// Original, wholesome prose so the reader screenshot looks like a real fic.
    private static func chapterHTML(work: AO3WorkSummary, chapter: Int) -> String {
        let opening: String
        switch chapter {
        case 1:
            opening = "<p>The morning the engines finally went quiet, Reyes woke to the strangest sound in the world: nothing at all. No hum in the deck plating, no rattle of the coolant lines, no distant cough of the recyclers. Just the small noises of a ship full of people pretending, very hard, to still be asleep.</p>"
        case 2:
            opening = "<p>By the second week they had a routine, which Wira insisted was the same thing as a plan if you said it with enough confidence. Wake. Check the patch on the hull. Argue gently about breakfast. Pretend the long-range array might, today, finally catch something other than static.</p>"
        default:
            opening = "<p>Home, Ode decided, was not a place after all. It was the particular way the others laughed when they thought no one was keeping score — Reyes too loud, Wira not nearly loud enough, and somewhere underneath it the steady thrum of a ship that had decided, against all odds, to keep going.</p>"
        }
        return """
        \(opening)
        <p>“You're up early,” said Wira, who was already three cups of something vaguely coffee-shaped into the day. She slid a mug across the table without being asked, which was its own kind of language. “Couldn't sleep, or didn't want to?”</p>
        <p>“Both,” Reyes admitted. “Mostly I keep thinking about the long way round. Six months, maybe seven, if the slingshot holds. Everyone keeps asking me if it's worth it.”</p>
        <p>Wira considered this with the seriousness she reserved for genuinely important questions and absolutely nothing else. “And what do you tell them?”</p>
        <p>Outside the viewport the stars hung close and patient, the way they only ever did when you had nowhere to be and all the time in the world to get there. Reyes wrapped both hands around the warm mug and, for the first time in a long while, found that the answer came easily.</p>
        <p>“I tell them,” she said, “that the long way home is still the way home.”</p>
        """
    }
}

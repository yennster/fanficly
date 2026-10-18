import XCTest
@testable import Fanficly

/// The search box: words stay keywords (AO3 does the matching), explicit
/// `key:value` tokens and a short list of filter-only phrases become filters,
/// and rendering round-trips.
final class SearchSyntaxTests: XCTestCase {
    private func parse(_ s: String) -> AO3SearchFilters { SearchSyntax.parse(s) }

    // MARK: - Words stay words (the old parser's failures)

    func test_teenWolf_isAFandomSearch_notATeenRating() {
        let f = parse("teen wolf derek stiles slow burn")
        XCTAssertEqual(f.query, "teen wolf derek stiles slow burn")
        XCTAssertTrue(f.ratings.isEmpty)
    }

    func test_everydayWords_neverBecomeFilters() {
        for prompt in ["supernatural creatures", "wednesday addams", "french kiss", "korean idol au",
                       "the other side", "soft family drama", "mature themes", "general hospital",
                       "harry potter", "popular kid", "recent graduate", "finished line", "multi chapter"] {
            let f = parse(prompt)
            XCTAssertEqual(f.query, prompt, prompt)
            var bare = f
            bare.query = ""
            XCTAssertTrue(bare.isEmpty, "\(prompt) added filters")
        }
    }

    func test_ships_stayKeywords() {
        // AO3 matches "edward/bella" exactly like "edward bella" (verified).
        XCTAssertEqual(parse("edward/bella").query, "edward/bella")
        XCTAssertTrue(parse("edward/bella").relationshipNames.isEmpty)
    }

    func test_exclusionsAndPhrases_passThroughToAO3() {
        XCTAssertEqual(parse("drarry -angst \"enemies to lovers\"").query, "drarry -angst \"enemies to lovers\"")
    }

    // MARK: - Filter-only phrases

    func test_completion() {
        XCTAssertEqual(parse("drarry complete").complete, .yes)
        XCTAssertEqual(parse("drarry completed").complete, .yes)
        XCTAssertEqual(parse("drarry wip").complete, .no)
        XCTAssertEqual(parse("drarry incomplete").complete, .no)
        XCTAssertEqual(parse("drarry complete").query, "drarry")
    }

    func test_quotedFilterWord_isTheLiteralWord() {
        let f = parse("\"complete\" idiot")
        XCTAssertEqual(f.complete, .any)
        XCTAssertEqual(f.query, "\"complete\" idiot")
    }

    func test_oneShots() {
        for s in ["oneshot", "one shot", "one-shot", "oneshots"] {
            XCTAssertTrue(parse("fluff \(s)").singleChapter, s)
        }
    }

    func test_ratings_onlyUnambiguousForms() {
        XCTAssertEqual(parse("smut explicit").ratings, [.explicit])
        XCTAssertEqual(parse("nsfw").ratings, [.mature, .explicit])
        XCTAssertEqual(parse("sfw").ratings, [.general, .teen])
        XCTAssertEqual(parse("rated mature").ratings, [.mature])
        XCTAssertEqual(parse("m-rated").ratings, [.mature])
        XCTAssertEqual(parse("teen and up audiences").ratings, [.teen])
        XCTAssertTrue(parse("teen").ratings.isEmpty)
        XCTAssertTrue(parse("mature").ratings.isEmpty)
    }

    func test_categories() {
        XCTAssertEqual(parse("coffee shop au m/m").categories, [.mm])
        XCTAssertEqual(parse("f/f femslash").categories, [.ff])
        XCTAssertTrue(parse("gen").categories.isEmpty)
    }

    func test_wordCount_needsAUnit() {
        XCTAssertEqual(parse("under 10k").wordCount, "<10000")
        XCTAssertEqual(parse("over 50,000 words").wordCount, ">50000")
        XCTAssertEqual(parse("less than 5000 words").wordCount, "<5000")
        XCTAssertEqual(parse("between 10k and 50k").wordCount, "10000-50000")
        XCTAssertEqual(parse("between 10 and 50k").wordCount, "10000-50000")
        XCTAssertEqual(parse("over 9000").wordCount, "")
        XCTAssertEqual(parse("over 9000").query, "over 9000")
    }

    func test_language_needsIn() {
        XCTAssertEqual(parse("drarry in spanish").languageId, "es")
        XCTAssertEqual(parse("en español").languageId, "es")
        XCTAssertEqual(parse("spanish inquisition").languageId, "")
    }

    func test_crossoversAndWarnings() {
        XCTAssertEqual(parse("no crossovers").crossover, .no)
        XCTAssertEqual(parse("marvel crossover").crossover, .yes)
        XCTAssertEqual(parse("angst no mcd").excludedTagNames, ["Major Character Death"])
        XCTAssertEqual(parse("no archive warnings apply").warnings, [.noWarningsApply])
    }

    // MARK: - Explicit tokens

    func test_keyValueTokens() {
        let f = parse("title:\"The Long Way Home\" by:wanderlight tag:\"Slow Burn\" -tag:\"Major Character Death\" rating:explicit warning:mcd category:m/m complete:yes crossover:no oneshot:yes words:<10k lang:es kudos:>1000")
        XCTAssertEqual(f.title, "The Long Way Home")
        XCTAssertEqual(f.creators, "wanderlight")
        XCTAssertEqual(f.otherTagNames, ["Slow Burn"])
        XCTAssertEqual(f.excludedTagNames, ["Major Character Death"])
        XCTAssertEqual(f.ratings, [.explicit])
        XCTAssertEqual(f.warnings, [.majorCharacterDeath])
        XCTAssertEqual(f.categories, [.mm])
        XCTAssertEqual(f.complete, .yes)
        XCTAssertEqual(f.crossover, .no)
        XCTAssertTrue(f.singleChapter)
        XCTAssertEqual(f.wordCount, "<10000")
        XCTAssertEqual(f.languageId, "es")
        XCTAssertEqual(f.kudosCount, ">1000")
        XCTAssertEqual(f.query, "")
    }

    func test_unknownKeys_stayInTheQuery() {
        XCTAssertEqual(parse("Re:Zero rating_ids:12").query, "Re:Zero rating_ids:12")
        XCTAssertEqual(parse("rating:bogus").query, "rating:bogus")
    }

    func test_smartQuotes() {
        XCTAssertEqual(parse("title:\u{201C}The Great Gatsby\u{201D}").title, "The Great Gatsby")
    }

    func test_lengthChangingCharacters_doNotCrashOrShift() {
        let f = parse("İstanbul by:melis complete")
        XCTAssertEqual(f.creators, "melis")
        XCTAssertEqual(f.complete, .yes)
        XCTAssertEqual(f.query, "İstanbul")
    }

    // MARK: - Round trip

    func test_render_roundTrips() {
        var f = AO3SearchFilters()
        f.query = "drarry -angst"
        f.title = "Long Way"
        f.creators = "someone"
        f.otherTagNames = ["Teen Wolf (TV)", "Slow Burn"]
        f.excludedTagNames = ["Major Character Death"]
        f.fandomNames = ["Harry Potter - J. K. Rowling"]
        f.relationshipNames = ["Draco Malfoy/Harry Potter"]
        f.characterNames = ["Hermione Granger"]
        f.freeformNames = ["Fluff"]
        f.excludedFreeforms = ["sad ending"]
        f.ratings = [.mature, .explicit, .notRated]
        f.warnings = [.noWarningsApply, .majorCharacterDeath]
        f.categories = [.mm, .ff]
        f.complete = .no
        f.crossover = .yes
        f.singleChapter = true
        f.wordCount = "1000-5000"
        f.languageId = "es"
        f.kudosCount = ">100"
        f.hits = "<5000"
        f.commentsCount = ">10"
        f.bookmarksCount = ">5"
        f.revisedAt = "<1week"
        XCTAssertEqual(parse(SearchSyntax.render(f)), f)
    }

    func test_emptyRendersEmpty() {
        XCTAssertEqual(SearchSyntax.render(AO3SearchFilters()), "")
        XCTAssertTrue(parse("   ").isEmpty)
    }

    func test_automaticSort_kudosWithoutKeywords() {
        XCTAssertEqual(SearchSyntax.automaticSort(hasKeywords: false), .kudosCount)
        XCTAssertEqual(SearchSyntax.automaticSort(hasKeywords: true), .bestMatch)
    }

    // MARK: - AO3 fields

    func test_tagFieldsReachAO3() {
        var f = AO3SearchFilters()
        f.otherTagNames = ["Teen Wolf (TV)", "Slow Burn"]
        f.excludedTagNames = ["Major Character Death"]
        let items = Dictionary(uniqueKeysWithValues: f.queryItems().map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["work_search[other_tag_names]"], "Teen Wolf (TV), Slow Burn")
        XCTAssertEqual(items["work_search[excluded_tag_names]"], "Major Character Death")
        XCTAssertFalse(f.isEmpty)
    }

    func test_filtersSavedBeforeTagFields_stillDecode() throws {
        let old = #"{"query":"","title":"","creators":"","revisedAt":"","complete":"yes","crossover":"any","singleChapter":false,"wordCount":"","languageId":"","fandomNames":[],"characterNames":[],"relationshipNames":["A/B"],"freeformNames":[],"excludedFreeforms":[],"ratings":["13"],"warnings":[],"categories":[],"hits":"","kudosCount":"","commentsCount":"","bookmarksCount":"","sortColumn":"kudos_count","sortDirection":"desc"}"#
        let decoded = try XCTUnwrap(AO3SearchFilters.from(savedJSON: old))
        XCTAssertEqual(decoded.relationshipNames, ["A/B"])
        XCTAssertEqual(decoded.complete, .yes)
        XCTAssertEqual(decoded.sortColumn, .kudosCount)
        XCTAssertEqual(decoded.otherTagNames, [])
    }

    func test_merging_unionsListsAndKeepsSort() {
        var base = AO3SearchFilters()
        base.otherTagNames = ["Slow Burn"]
        base.sortColumn = .kudosCount
        base.query = "kept out"
        let merged = base.merging(parse("tag:\"slow burn\" tag:Fluff complete"))
        XCTAssertEqual(merged.otherTagNames, ["Slow Burn", "Fluff"])
        XCTAssertEqual(merged.complete, .yes)
        XCTAssertEqual(merged.sortColumn, .kudosCount)
        XCTAssertEqual(merged.query, "kept out")
    }
}

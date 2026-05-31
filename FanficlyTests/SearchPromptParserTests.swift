import XCTest
@testable import Fanficly

final class SearchPromptParserTests: XCTestCase {
    let parser = SearchPromptParser()

    func test_shipsBecomeRelationships() {
        let filters = parser.parse("edward/bella")
        XCTAssertEqual(filters.relationshipNames, ["Edward/Bella"])
        XCTAssertEqual(filters.query, "")
    }

    func test_categorySlashIsNotMistakenForShip() {
        let filters = parser.parse("f/f romance")
        XCTAssertTrue(filters.categories.contains(.ff))
        XCTAssertTrue(filters.relationshipNames.isEmpty)
    }

    func test_ratingExplicit() {
        let filters = parser.parse("edward/bella explicit")
        XCTAssertTrue(filters.ratings.contains(.explicit))
    }

    func test_ratingShortForm() {
        let filters = parser.parse("e-rated harry/draco")
        XCTAssertTrue(filters.ratings.contains(.explicit))
    }

    func test_warning_majorCharacterDeath() {
        let filters = parser.parse("major character death angst")
        XCTAssertTrue(filters.warnings.contains(.majorCharacterDeath))
    }

    func test_warning_noWarnings() {
        let filters = parser.parse("no archive warnings apply fluff")
        XCTAssertTrue(filters.warnings.contains(.noWarningsApply))
    }

    func test_freeformTag_allHuman() {
        let filters = parser.parse("edward/bella all human")
        XCTAssertTrue(filters.freeformNames.contains("All Human"))
    }

    func test_freeformTag_slowBurn() {
        let filters = parser.parse("harry/draco slow burn enemies to lovers")
        XCTAssertTrue(filters.freeformNames.contains("Slow Burn"))
        XCTAssertTrue(filters.freeformNames.contains("Enemies to Lovers"))
    }

    func test_wordCountUnder() {
        let filters = parser.parse("oneshot under 5k")
        XCTAssertEqual(filters.wordCount, "<5000")
        XCTAssertTrue(filters.singleChapter)
    }

    func test_wordCountOver() {
        let filters = parser.parse("over 50k slow burn")
        XCTAssertEqual(filters.wordCount, ">50000")
    }

    func test_wordCountBetween() {
        let filters = parser.parse("between 5k and 20k")
        XCTAssertEqual(filters.wordCount, "5000-20000")
    }

    func test_statusComplete() {
        let filters = parser.parse("complete edward/bella")
        XCTAssertEqual(filters.complete, .yes)
    }

    func test_statusWIP() {
        let filters = parser.parse("wip slow burn")
        XCTAssertEqual(filters.complete, .no)
    }

    func test_engagementPopular() {
        let filters = parser.parse("popular harry/draco")
        XCTAssertEqual(filters.kudosCount, ">1000")
    }

    func test_engagementMostKudos() {
        let filters = parser.parse("most kudos")
        XCTAssertEqual(filters.sortColumn, .kudosCount)
        XCTAssertEqual(filters.sortDirection, .desc)
    }

    func test_language() {
        let filters = parser.parse("edward/bella in spanish")
        XCTAssertEqual(filters.languageId, "es")
    }

    func test_crossover() {
        let filters = parser.parse("crossover edward/bella")
        XCTAssertEqual(filters.crossover, .yes)
    }

    func test_noCrossover() {
        let filters = parser.parse("no crossovers edward/bella")
        XCTAssertEqual(filters.crossover, .no)
    }

    func test_exclusionMinus() {
        let filters = parser.parse("edward/bella -omegaverse")
        XCTAssertEqual(filters.excludedFreeforms, ["omegaverse"])
    }

    func test_exclusionMultiple() {
        let filters = parser.parse("harry/draco -mpreg -omegaverse")
        XCTAssertTrue(filters.excludedFreeforms.contains("mpreg"))
        XCTAssertTrue(filters.excludedFreeforms.contains("omegaverse"))
    }

    func test_exclusionAngstAtEnd() {
        let filters = parser.parse("draco/hermione explicit complete -angst")
        XCTAssertEqual(filters.relationshipNames, ["Draco/Hermione"])
        XCTAssertTrue(filters.ratings.contains(.explicit))
        XCTAssertEqual(filters.complete, .yes)
        XCTAssertEqual(filters.excludedFreeforms, ["angst"])
    }

    func test_exclusionAngstInMiddle() {
        let filters = parser.parse("draco/hermione -angst complete")
        XCTAssertTrue(filters.excludedFreeforms.contains("angst"))
        XCTAssertEqual(filters.complete, .yes)
    }

    func test_exclusionStopsAtNextWord_doesNotEatTrailingFandom() {
        let filters = parser.parse("draco/hermione complete -omegaverse harry potter")
        XCTAssertEqual(filters.excludedFreeforms, ["omegaverse"])
        XCTAssertTrue(filters.fandomNames.contains("Harry Potter - J. K. Rowling"))
        XCTAssertEqual(filters.relationshipNames, ["Draco/Hermione"])
        XCTAssertEqual(filters.complete, .yes)
    }

    func test_exclusionQuotedPhrase() {
        let filters = parser.parse("harry/draco -\"slow burn\" complete")
        XCTAssertTrue(filters.excludedFreeforms.contains("slow burn"))
        XCTAssertEqual(filters.complete, .yes)
    }

    func test_fandomHarryPotter() {
        let filters = parser.parse("harry potter slow burn")
        XCTAssertEqual(filters.fandomNames, ["Harry Potter - J. K. Rowling"])
        XCTAssertTrue(filters.freeformNames.contains("Slow Burn"))
    }

    func test_fandomMcuAlias() {
        let filters = parser.parse("mcu fluff")
        XCTAssertTrue(filters.fandomNames.contains("Marvel Cinematic Universe"))
    }

    func test_exampleFromUser_edwardBellaRomanceAllHumanExplicit() {
        let filters = parser.parse("edward/bella romance all human explicit")
        XCTAssertEqual(filters.relationshipNames, ["Edward/Bella"])
        XCTAssertTrue(filters.ratings.contains(.explicit))
        XCTAssertTrue(filters.freeformNames.contains("All Human"))
        // "romance" is a recognised freeform tag, not leftover query text.
        XCTAssertTrue(filters.freeformNames.contains("Romance"))
        XCTAssertEqual(filters.query, "")
    }

    func test_romanceIsAFreeformTag() {
        let filters = parser.parse("romance fluff")
        XCTAssertTrue(filters.freeformNames.contains("Romance"))
        XCTAssertTrue(filters.freeformNames.contains("Fluff"))
        XCTAssertEqual(filters.query, "")
    }

    func test_queryItemsRoundTripIncludesAllStandardFields() {
        var filters = AO3SearchFilters()
        filters.relationshipNames = ["Edward/Bella"]
        filters.ratings = [.explicit]
        filters.freeformNames = ["All Human"]
        filters.complete = .yes
        filters.wordCount = ">10000"
        let items = filters.queryItems()
        let names = items.map(\.name)
        XCTAssertTrue(names.contains("work_search[relationship_names]"))
        XCTAssertTrue(names.contains("work_search[rating_ids][]"))
        XCTAssertTrue(names.contains("work_search[freeform_names]"))
        XCTAssertTrue(names.contains("work_search[complete]"))
        XCTAssertTrue(names.contains("work_search[word_count]"))
    }

    func test_excludedFreeformsBecomeNotInQuery() {
        var filters = AO3SearchFilters()
        filters.query = "harry/draco"
        filters.excludedFreeforms = ["mpreg"]
        let q = filters.queryItems().first(where: { $0.name == "work_search[query]" })?.value
        XCTAssertEqual(q, "harry/draco NOT mpreg")
    }

    func test_emptyPromptYieldsEmptyFilters() {
        let filters = parser.parse("")
        XCTAssertTrue(filters.isEmpty)
    }

    func test_queryRemainderIsPreserved() {
        let filters = parser.parse("space pirates with feelings")
        XCTAssertEqual(filters.query, "space pirates with feelings")
    }
}

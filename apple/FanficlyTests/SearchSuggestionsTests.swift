import XCTest
@testable import Fanficly

/// Typeahead: which words suggestions are for, the instant local ones, how
/// AO3's tags are ranked, and what tapping one does.
final class SearchSuggestionsTests: XCTestCase {
    func test_activeWords_areTheTrailingPlainWords() {
        XCTAssertEqual(SearchSuggestions.activeWords(in: "slow burn teen wol"), ["burn", "teen", "wol"])
        XCTAssertEqual(SearchSuggestions.activeWords(in: "teen wolf "), ["teen", "wolf"])
        XCTAssertEqual(SearchSuggestions.activeWords(in: "by:someone fluff"), ["fluff"])
        XCTAssertEqual(SearchSuggestions.activeWords(in: "-angst fluff"), ["fluff"])
        XCTAssertEqual(SearchSuggestions.activeWords(in: "\"enemies to lovers\" coffee"), ["coffee"])
        XCTAssertEqual(SearchSuggestions.activeWords(in: "\"enemies to"), [], "inside an open quote")
        XCTAssertEqual(SearchSuggestions.activeWords(in: ""), [])
    }

    private func labels(_ words: [String]) -> [String] {
        SearchSuggestions.local(for: words).map(\.suggestion.label)
    }

    func test_local_fandomAbbreviations() {
        let candidates = SearchSuggestions.local(for: ["hp"])
        XCTAssertEqual(candidates.first?.suggestion, .tag("Harry Potter - J. K. Rowling"))
        XCTAssertEqual(candidates.first?.consumedWords, 1)
    }

    func test_local_filterWords_areOffered_notApplied() {
        XCTAssertTrue(SearchSuggestions.local(for: ["teen"]).map(\.suggestion).contains(.rating(.teen)))
        XCTAssertTrue(SearchSuggestions.local(for: ["comp"]).map(\.suggestion).contains(.completion(.yes)))
        XCTAssertTrue(SearchSuggestions.local(for: ["wip"]).map(\.suggestion).contains(.completion(.no)))
        XCTAssertTrue(SearchSuggestions.local(for: ["one", "sh"]).isEmpty == false)
        XCTAssertTrue(SearchSuggestions.local(for: ["m/m"]).map(\.suggestion).contains(.category(.mm)))
        XCTAssertTrue(SearchSuggestions.local(for: ["spa"]).map(\.suggestion).contains(.language("es")))
        XCTAssertTrue(SearchSuggestions.local(for: ["under", "10k"]).map(\.suggestion).contains(.wordCount("<10000")))
    }

    func test_local_multiWordMatch_consumesItsWords() {
        let candidate = SearchSuggestions.local(for: ["drarry", "under", "10k"])
            .first { $0.suggestion == .wordCount("<10000") }
        XCTAssertEqual(candidate?.consumedWords, 2)
    }

    func test_local_shortFragmentsStayQuiet() {
        XCTAssertTrue(SearchSuggestions.local(for: ["te"]).isEmpty)
        XCTAssertTrue(SearchSuggestions.local(for: ["derek"]).isEmpty)
    }

    func test_rankTags_putsTheTagYoureTypingFirst() {
        // AO3's raw order for "teen wolf" (abridged from a live response).
        let raw = [
            "Episode: s01e09 Wolf's Bane (Teen Wolf TV)",
            "Jana (Wolfblood)/Scott McCall (Teen Wolf)",
            "Teen Wolf (TV)",
            "Scott McCall (Teen Wolf)",
            "teen wolf (tv)",
        ]
        let ranked = SearchSuggestions.rankTags(raw, for: "teen wolf")
        XCTAssertEqual(ranked.first, "Teen Wolf (TV)")
        XCTAssertEqual(ranked.last, "Episode: s01e09 Wolf's Bane (Teen Wolf TV)")
        XCTAssertEqual(ranked.count, 4, "case-insensitive duplicates collapse")
    }

    func test_rankTags_exactMatchWins() {
        XCTAssertEqual(SearchSuggestions.rankTags(["Slow Burn Draco Malfoy/Harry Potter", "Slow Burn"], for: "slow burn").first, "Slow Burn")
    }

    func test_apply_replacesTheWordsWithAFilter() {
        var text = "explicit teen wolf"
        var filters = AO3SearchFilters()
        SearchSuggestions.apply(SuggestionCandidate(suggestion: .tag("Teen Wolf (TV)"), consumedWords: 2),
                                text: &text, filters: &filters)
        XCTAssertEqual(text, "explicit ")
        XCTAssertEqual(filters.otherTagNames, ["Teen Wolf (TV)"])

        SearchSuggestions.apply(SuggestionCandidate(suggestion: .rating(.explicit), consumedWords: 1),
                                text: &text, filters: &filters)
        XCTAssertEqual(text, "")
        XCTAssertEqual(filters.ratings, [.explicit])
    }

    func test_apply_sameTagTwice_isOneFilter() {
        var text = "slow burn"
        var filters = AO3SearchFilters()
        filters.otherTagNames = ["Slow Burn"]
        SearchSuggestions.apply(SuggestionCandidate(suggestion: .tag("slow burn"), consumedWords: 2),
                                text: &text, filters: &filters)
        XCTAssertEqual(filters.otherTagNames, ["Slow Burn"])
    }

    func test_suggestionLabels() {
        XCTAssertEqual(SearchSuggestion.rating(.explicit).label, "Rated Explicit")
        XCTAssertEqual(SearchSuggestion.completion(.no).label, "Works in progress")
        XCTAssertEqual(SearchSuggestion.language("es").label, "In Spanish")
        XCTAssertTrue(SearchSuggestion.wordCount("<10000").label.hasPrefix("Under "))
        XCTAssertEqual(SearchSuggestion.tag("Draco Malfoy/Harry Potter").systemImage, "heart")
    }

    // MARK: - Recents

    func test_recents_newestFirst_deduped_capped() {
        var raw = ""
        for n in 1...12 { raw = RecentSearches.adding("search \(n)", to: raw) }
        raw = RecentSearches.adding("SEARCH 5", to: raw)
        let list = RecentSearches.list(raw)
        XCTAssertEqual(list.count, RecentSearches.limit)
        XCTAssertEqual(list.first, "SEARCH 5")
        XCTAssertFalse(list.contains("search 5"))
        XCTAssertEqual(RecentSearches.list(RecentSearches.removing("SEARCH 5", from: raw)).count, RecentSearches.limit - 1)
        XCTAssertEqual(RecentSearches.adding("   ", to: raw), raw)
    }

    // MARK: - Results count

    func test_searchPage_totalFound() throws {
        let html = """
        <html><body><h3 class="heading">126,555 Found  <a class="help symbol question modal" href="/help">?</a></h3>
        <ol class="work index group"></ol></body></html>
        """
        XCTAssertEqual(try SearchResultsParser.parse(html: html).totalFound, 126_555)
        XCTAssertNil(try SearchResultsParser.parse(html: "<html><body><ol class=\"work index group\"></ol></body></html>").totalFound)
    }

    // MARK: Fandom picker (Filters sheet)

    func test_fandomPicks_putTheKnownAbbreviationFirst_thenAO3sMatchesRanked() {
        let ao3 = ["Harry Potter - Fandom", "Harry Potter - J. K. Rowling", "Harry Potter and the Cursed Child - Thorne & Rowling"]
        let picks = SearchSuggestions.fandomPicks(for: "hp", from: ao3)
        XCTAssertEqual(picks.first, "Harry Potter - J. K. Rowling")
        XCTAssertEqual(picks.filter { $0 == "Harry Potter - J. K. Rowling" }.count, 1, "no duplicate of the alias")

        let typed = SearchSuggestions.fandomPicks(for: "teen wolf", from: ["Teen Wolf - Episode: Lunatic", "Teen Wolf (TV)"])
        XCTAssertEqual(typed.first, "Teen Wolf (TV)", "a prefix match beats AO3's order")
    }

    func test_fandomPicks_leaveOutPickedFandoms_andNeverPickForAnEmptyTerm() {
        let picks = SearchSuggestions.fandomPicks(for: "teen", from: ["Teen Wolf (TV)", "Teen Titans (Cartoon)"], excluding: ["teen wolf (tv)"])
        XCTAssertEqual(picks, ["Teen Titans (Cartoon)"])
        XCTAssertEqual(SearchSuggestions.fandomPicks(for: "  ", from: ["Teen Wolf (TV)"]), [])
    }

    func test_popularFandomPicks_skipPicked_andCap() {
        let popular = ["A (TV)", "B (Movie)", "C (Anime)"]
        XCTAssertEqual(SearchSuggestions.popularFandomPicks(popular, excluding: ["b (movie)"], limit: 2), ["A (TV)", "C (Anime)"])
        XCTAssertEqual(SearchSuggestions.popularFandomPicks(popular, limit: 0), [])
    }

    func test_addingFandom_trims_andIgnoresDuplicates() {
        XCTAssertEqual(SearchSuggestions.addingFandom("  Naruto ", to: []), ["Naruto"])
        XCTAssertEqual(SearchSuggestions.addingFandom("naruto", to: ["Naruto"]), ["Naruto"])
        XCTAssertEqual(SearchSuggestions.addingFandom("", to: ["Naruto"]), ["Naruto"])
    }

    func test_demoClient_fandomAutocomplete_offersOnlyFandoms() async throws {
        let names = try await DemoAO3Client().autocomplete(field: .fandom, term: "original work")
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.allSatisfy { name in DemoCatalog.works.contains { $0.fandoms.contains(name) } })
    }
}

import XCTest
@testable import Fanficly

final class TagResolverTests: XCTestCase {
    override func setUp() async throws {
        // The resolution cache is process-global; clear it so a memoized result
        // from one case can't leak into the next.
        await TagResolver.clearCacheForTesting()
    }

    func test_bestMatch_prefersExactCaseInsensitive() {
        let matches = ["Hermione Granger/Draco Malfoy", "Draco Malfoy/Harry Potter"]
        XCTAssertEqual(
            TagResolver.bestMatch(for: "hermione granger/draco malfoy", in: matches),
            "Hermione Granger/Draco Malfoy"
        )
    }

    func test_bestMatch_fallsBackToFirst() {
        let matches = ["Hermione Granger/Draco Malfoy", "Other Ship"]
        XCTAssertEqual(TagResolver.bestMatch(for: "dramione", in: matches), "Hermione Granger/Draco Malfoy")
    }

    func test_bestMatch_emptyReturnsNil() {
        XCTAssertNil(TagResolver.bestMatch(for: "x", in: []))
    }

    func test_candidates_relationshipExpandsSlashVariants() {
        let c = TagResolver.candidates(for: "hermione/draco", field: .relationship)
        XCTAssertTrue(c.contains("hermione/draco"))
        XCTAssertTrue(c.contains("hermione draco"))   // slash -> space
        XCTAssertTrue(c.contains("draco hermione"))   // reversed
    }

    func test_candidates_nonRelationshipIsJustTheTerm() {
        XCTAssertEqual(TagResolver.candidates(for: "Slow Burn", field: .freeform), ["Slow Burn"])
        XCTAssertEqual(TagResolver.candidates(for: "Hermione Granger", field: .character), ["Hermione Granger"])
    }

    func test_resolve_usesMockAutocomplete() async {
        // MockAO3Client echoes the term, so resolution returns the input.
        var filters = AO3SearchFilters()
        filters.relationshipNames = ["Edward/Bella"]
        let resolved = await TagResolver.resolve(filters, using: MockAO3Client())
        XCTAssertEqual(resolved.relationshipNames, ["Edward/Bella"])
    }

    func test_resolve_shipViaCharacterFallback() async {
        // AO3 can't match "hermione/draco" directly, but can match each
        // character and then the ship from the full names.
        let stub = StubAO3Client()
        stub.autocompleteResponses = [
            // Direct relationship lookups return nothing for the short forms…
            "hermione/draco": [],
            "hermione draco": [],
            "draco hermione": [],
            // …character lookups succeed…
            "hermione": ["Hermione Granger"],
            "draco": ["Draco Malfoy"],
            // …and the ship from the canonical names resolves.
            "hermione granger/draco malfoy": ["Hermione Granger/Draco Malfoy"],
        ]
        var filters = AO3SearchFilters()
        filters.relationshipNames = ["hermione/draco"]
        let resolved = await TagResolver.resolve(filters, using: stub)
        XCTAssertEqual(resolved.relationshipNames, ["Hermione Granger/Draco Malfoy"])
    }

    func test_bestMatch_relationshipPrefersSameArityWholeWordMatch() {
        // "Bella/Edward" must not resolve to a 3-person ship where "Bella"
        // is only a substring of "Isabella".
        let matches = [
            "Oswald Cobblepot/Isabella/Edward Nygma",
            "Bella Swan/Edward Cullen"
        ]
        XCTAssertEqual(
            TagResolver.bestMatch(for: "Bella/Edward", in: matches, field: .relationship),
            "Bella Swan/Edward Cullen"
        )
    }

    func test_bestMatch_freeformDoesNotExpandToMoreSpecificTag() {
        // Regression: typing the freeform "caveman" must not get rewritten to a
        // popular compound tag that merely contains it. AO3 ranks autocomplete
        // by popularity, so "Caveman Derek Hale" comes back first.
        let matches = ["Caveman Derek Hale"]
        XCTAssertEqual(
            TagResolver.bestMatch(for: "caveman", in: matches, field: .freeform),
            "caveman"
        )
    }

    func test_bestMatch_freeformStillCanonicalizesFormatting() {
        // Same tag up to case/spacing/punctuation should still resolve.
        let matches = ["Caveman Derek Hale", "Hurt/Comfort"]
        XCTAssertEqual(
            TagResolver.bestMatch(for: "hurt comfort", in: matches, field: .freeform),
            "Hurt/Comfort"
        )
    }

    func test_resolve_freeformKeepsTypedTermWhenOnlyNarrowerSuggestions() async {
        let stub = StubAO3Client()
        stub.autocompleteResponses = ["caveman": ["Caveman Derek Hale"]]
        var filters = AO3SearchFilters()
        filters.freeformNames = ["caveman"]
        let resolved = await TagResolver.resolve(filters, using: stub)
        XCTAssertEqual(resolved.freeformNames, ["caveman"])
    }

    func test_resolve_directRelationshipMatch() async {
        let stub = StubAO3Client()
        stub.autocompleteResponses = ["edward/bella": ["Edward Cullen/Bella Swan"]]
        var filters = AO3SearchFilters()
        filters.relationshipNames = ["edward/bella"]
        let resolved = await TagResolver.resolve(filters, using: stub)
        XCTAssertEqual(resolved.relationshipNames, ["Edward Cullen/Bella Swan"])
    }
}

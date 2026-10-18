import XCTest
@testable import Fanficly

/// Live integration check — hits AO3's real autocomplete endpoint to guard the
/// tag-resolution path end-to-end (it regressed once when the shared session's
/// `Accept: text/html` header made AO3 404 the JSON-only autocomplete route).
///
/// Gated behind an env var so it never runs in CI. To run it, set `AO3_LIVE=1`
/// in the test scheme's environment (CLI env vars don't reach the sim process).
final class LiveResolutionTests: XCTestCase {
    private var live: Bool { ProcessInfo.processInfo.environment["AO3_LIVE"] == "1" }

    func test_live_hermioneDracoResolvesToCanonical() async throws {
        try XCTSkipUnless(live, "set AO3_LIVE=1 in the scheme to run live AO3 tests")
        let client = AO3Client()

        // The endpoint must answer JSON, not 404 on an HTML Accept header.
        let raw = try await client.autocomplete(field: .relationship, term: "Hermione/Draco")
        XCTAssertTrue(raw.contains("Hermione Granger/Draco Malfoy"), "got \(raw)")

        var filters = AO3SearchFilters()
        filters.relationshipNames = ["Hermione/Draco"]
        let resolved = await TagResolver.resolve(filters, using: client)
        XCTAssertEqual(resolved.relationshipNames, ["Hermione Granger/Draco Malfoy"])
    }
}

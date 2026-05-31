import XCTest
@testable import Fanficly

final class AO3EndpointsTests: XCTestCase {
    let base = URL(string: "https://archiveofourown.org")!

    func test_workURL_includesFullAndAdult() throws {
        let url = try AO3Endpoints.work(id: 12345, base: base)
        let s = url.absoluteString
        XCTAssertTrue(s.contains("/works/12345"))
        XCTAssertTrue(s.contains("view_full_work=true"))
        XCTAssertTrue(s.contains("view_adult=true"))
    }

    func test_downloadURL_perFormat() throws {
        for format in WorkExportFormat.allCases {
            let url = try AO3Endpoints.download(workId: 99, format: format, base: base)
            XCTAssertEqual(url.absoluteString, "https://archiveofourown.org/downloads/99/work.\(format.ext)")
        }
    }

    func test_autocompleteURL() throws {
        let url = try AO3Endpoints.autocomplete(field: "relationship", term: "harry/draco", base: base)
        XCTAssertTrue(url.absoluteString.contains("/autocomplete/relationship"))
        XCTAssertTrue(url.absoluteString.contains("term=harry/draco") || url.absoluteString.contains("term=harry%2Fdraco"))
    }

    func test_mediaFandomsURL_encodesAO3Path() throws {
        // AO3 encodes special characters: & -> *a*, / -> *s*, . -> *d*
        let url = try AO3Endpoints.mediaFandoms(categoryName: "Cartoons & Comics & Graphic Novels", base: base)
        let s = url.absoluteString
        XCTAssertTrue(s.contains("/media/"))
        XCTAssertTrue(s.contains("*a*"))          // the & became *a*
        XCTAssertTrue(s.hasSuffix("/fandoms"))
        XCTAssertFalse(s.contains(" "))            // spaces encoded
    }

    func test_workCommentsURL_hasFragmentAndShowComments() throws {
        let url = try AO3Endpoints.workComments(id: 5, base: base)
        XCTAssertTrue(url.absoluteString.contains("show_comments=true"))
        XCTAssertEqual(url.fragment, "comments")
    }

    func test_searchURL_paginates() throws {
        var filters = AO3SearchFilters()
        filters.freeformNames = ["Fluff"]
        let page1 = try AO3Endpoints.search(filters: filters, page: 1, base: base)
        XCTAssertFalse(page1.absoluteString.contains("page="))
        let page3 = try AO3Endpoints.search(filters: filters, page: 3, base: base)
        XCTAssertTrue(page3.absoluteString.contains("page=3"))
    }

    func test_workSubscriptionsURL() throws {
        let url = try AO3Endpoints.workSubscriptions(id: 42, base: base)
        XCTAssertEqual(url.absoluteString, "https://archiveofourown.org/works/42/subscriptions")
    }
}

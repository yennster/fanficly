import XCTest
@testable import Fanficly

/// Tapping a poller notification must open what it's about: the work with new
/// chapters, an author's single new work, or the author's page when several
/// arrived at once. The route rides in the notification's `userInfo`, which the
/// system stores as a property list and hands back on tap.
final class NotificationRouteTests: XCTestCase {
    private let author = AuthorRef(username: "some_login", displayName: "Some Pseud")

    /// Encode → plist (as the system stores it) → decode.
    private func delivered(_ userInfo: [AnyHashable: Any]) throws -> NotificationRoute? {
        let data = try PropertyListSerialization.data(fromPropertyList: userInfo, format: .binary, options: 0)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return NotificationRoute(userInfo: try XCTUnwrap(plist as? [AnyHashable: Any]))
    }

    func test_everyRouteSurvivesDelivery() throws {
        let routes: [NotificationRoute] = [
            .newChapters(workId: 12345),
            .newWork(workId: 67890),
            .newWorks(author: author),
            .searchMatch(workId: 13579),
            .savedSearch(name: "Slow burn", prompt: #"tag:"Slow Burn" complete:yes"#),
        ]
        for route in routes {
            XCTAssertEqual(try delivered(route.userInfo), route)
        }
    }

    // Notifications posted before taps were routed carried only the work id,
    // for chapter alerts and single new works alike. Tapping one still opens
    // the work.
    func test_legacyWorkIdOnlyPayload_opensTheWork() throws {
        XCTAssertEqual(try delivered(["workId": 4242]), .newChapters(workId: 4242))
    }

    func test_ignoresUnrelatedKeys() {
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": "hi"], "kind": "newWork", "workId": NSNumber(value: 7)]
        XCTAssertEqual(NotificationRoute(userInfo: userInfo), .newWork(workId: 7))
    }

    func test_payloadWithNothingToOpen_isNil() {
        XCTAssertNil(NotificationRoute(userInfo: [:]))
        XCTAssertNil(NotificationRoute(userInfo: ["workId": "12345"]))
        XCTAssertNil(NotificationRoute(userInfo: ["kind": "newWork"]))
        XCTAssertNil(NotificationRoute(userInfo: ["kind": "newWorks"]))
        XCTAssertNil(NotificationRoute(userInfo: ["kind": "newWorks", "authorUsername": ""]))
        XCTAssertNil(NotificationRoute(userInfo: ["kind": "searchMatch"]))
        XCTAssertNil(NotificationRoute(userInfo: ["kind": "savedSearch", "searchName": "Empty", "searchPrompt": ""]))
    }

    func test_newWorksWithoutDisplayName_fallsBackToUsername() {
        let route = NotificationRoute(userInfo: ["kind": "newWorks", "authorUsername": "some_login", "authorName": ""])
        XCTAssertEqual(route, .newWorks(author: AuthorRef(username: "some_login", displayName: "some_login")))
    }

    // Opened from the iPhone sidebar (or a cold launch), Back should land
    // somewhere related.
    func test_landingTab() {
        XCTAssertEqual(NotificationRoute.newChapters(workId: 1).landingTab(workIsSaved: true), .library)
        XCTAssertEqual(NotificationRoute.newChapters(workId: 1).landingTab(workIsSaved: false), .subscriptions)
        XCTAssertEqual(NotificationRoute.newWork(workId: 1).landingTab(workIsSaved: false), .authors)
        XCTAssertEqual(NotificationRoute.newWorks(author: author).landingTab(workIsSaved: false), .authors)
        XCTAssertEqual(NotificationRoute.searchMatch(workId: 1).landingTab(workIsSaved: true), .search)
        XCTAssertEqual(NotificationRoute.savedSearch(name: "x", prompt: "x").landingTab(workIsSaved: false), .search)
    }

    // MARK: - What the poller actually posts

    func test_newChapterNotification_opensTheWork() throws {
        let content = SubscriptionPoller.newChapterContent(title: "A Fic", oldCount: 3, newCount: 5, workId: 12345)
        XCTAssertEqual(content.body, "2 new chapters posted (5 total)")
        XCTAssertEqual(try delivered(content.userInfo), .newChapters(workId: 12345))
    }

    func test_singleNewWorkNotification_opensTheWork() throws {
        let content = SubscriptionPoller.newWorkContent(
            authorUsername: author.username, authorName: author.displayName,
            newWorks: [.stub(id: 67890, title: "Brand New")]
        )
        XCTAssertEqual(content.body, "New work: Brand New")
        XCTAssertEqual(try delivered(content.userInfo), .newWork(workId: 67890))
    }

    func test_severalNewWorksNotification_opensTheAuthor() throws {
        let content = SubscriptionPoller.newWorkContent(
            authorUsername: author.username, authorName: author.displayName,
            newWorks: [.stub(id: 1, title: "One"), .stub(id: 2, title: "Two")]
        )
        XCTAssertEqual(content.title, "Some Pseud")
        XCTAssertEqual(content.body, "2 new works posted")
        XCTAssertEqual(try delivered(content.userInfo), .newWorks(author: author))
    }

    func test_singleSavedSearchMatch_opensTheWork() throws {
        let content = SubscriptionPoller.savedSearchContent(
            searchName: "Slow burn", prompt: "tag:\"Slow Burn\"",
            newWorks: [.stub(id: 24680, title: "Finally")]
        )
        XCTAssertEqual(content.title, "Slow burn")
        XCTAssertEqual(content.body, "New fic: Finally")
        XCTAssertEqual(try delivered(content.userInfo), .searchMatch(workId: 24680))
    }

    func test_severalSavedSearchMatches_openTheSearch() throws {
        let content = SubscriptionPoller.savedSearchContent(
            searchName: "Slow burn", prompt: "tag:\"Slow Burn\"",
            newWorks: [.stub(id: 1, title: "One"), .stub(id: 2, title: "Two"), .stub(id: 3, title: "Three")]
        )
        XCTAssertEqual(content.body, "3 new fics match this search")
        XCTAssertEqual(try delivered(content.userInfo), .savedSearch(name: "Slow burn", prompt: "tag:\"Slow Burn\""))
    }
}

/// Which shared, dropped, pasted or opened links import a work (#176).
final class ImportLinkTests: XCTestCase {
    private func id(_ link: String) -> Int? {
        guard let url = URL(string: link) else { return nil }
        return ImportLink.workId(from: url)
    }

    func test_ao3WorkLinks_giveTheWork() {
        XCTAssertEqual(id("https://archiveofourown.org/works/123"), 123)
        XCTAssertEqual(id("https://archiveofourown.org/works/123/chapters/456?view_adult=true#workskin"), 123)
        XCTAssertEqual(id("https://www.archiveofourown.org/collections/fest/works/9"), 9)
        XCTAssertEqual(id("http://ao3.org/works/7"), 7)
        XCTAssertEqual(id("HTTPS://ArchiveOfOurOwn.org/Works/8"), 8)
        // Pasted without https://.
        XCTAssertEqual(id("archiveofourown.org/works/5"), 5)
    }

    func test_fanficlyLinks_giveTheWork() {
        XCTAssertEqual(id("fanficly://import?url=https%3A%2F%2Farchiveofourown.org%2Fworks%2F42%3Fview_adult%3Dtrue"), 42)
        XCTAssertEqual(id("fanficly://import?url=https://archiveofourown.org/works/43"), 43)
        XCTAssertEqual(id("fanficly://works/8"), 8)
        XCTAssertEqual(id("fanficly://work/9"), 9)
    }

    func test_otherLinks_giveNoWork() {
        XCTAssertNil(id("https://archiveofourown.org/series/1"))
        XCTAssertNil(id("https://archiveofourown.org/users/someone/works"))
        XCTAssertNil(id("https://archiveofourown.org/tags/Fluff/works"))
        XCTAssertNil(id("https://archiveofourown.org/works/search?work_search%5Bquery%5D=x"))
        XCTAssertNil(id("https://archiveofourown.org/chapters/456"))
        XCTAssertNil(id("https://example.com/works/123"))
        XCTAssertNil(id("https://archiveofourown.org.example.com/works/1"))
        XCTAssertNil(id("ftp://archiveofourown.org/works/1"))
        XCTAssertNil(id("fanficly://import?url=https%3A%2F%2Fexample.com%2F"))
        XCTAssertNil(id("fanficly://import"))
        // The app's own widget links never import, whatever their query says.
        XCTAssertNil(id("fanficly://search?query=works/5"))
        XCTAssertNil(id("fanficly://library?folder=works/5"))
        XCTAssertNil(id("fanficly://resume/5"))
    }

    func test_workInDroppedText() {
        XCTAssertEqual(ImportLink.workId(fromText: "My fic: https://archiveofourown.org/works/123 enjoy!"), 123)
        XCTAssertEqual(ImportLink.workId(fromText: "(archiveofourown.org/works/77)."), 77)
        XCTAssertEqual(ImportLink.workId(fromText: "  https://archiveofourown.org/works/12/chapters/3 \n"), 12)
        XCTAssertEqual(ImportLink.workId(fromText: "fanficly://works/8"), 8)
        // No scheme, with "://" later in the query.
        XCTAssertEqual(ImportLink.workId(fromText: "archiveofourown.org/works/5?return_to=https://x"), 5)
        XCTAssertNil(ImportLink.workId(fromText: "see https://example.com/works/1"))
        XCTAssertNil(ImportLink.workId(fromText: "a paragraph from Notes"))
        XCTAssertFalse(ImportLink.hasWebLink("a paragraph from Notes"))
        XCTAssertTrue(ImportLink.hasWebLink("see HTTPS://archiveofourown.org/series/1"))
    }

    func test_onlySharedLinks_warnWhenTheyArentAWork() throws {
        XCTAssertTrue(ImportLink.isLinkToImport(try XCTUnwrap(URL(string: "https://example.com/"))))
        XCTAssertTrue(ImportLink.isLinkToImport(try XCTUnwrap(URL(string: "fanficly://import?url=https%3A%2F%2Fexample.com"))))
        XCTAssertFalse(ImportLink.isLinkToImport(try XCTUnwrap(URL(string: "fanficly://search?query=x"))))
        XCTAssertFalse(ImportLink.isLinkToImport(try XCTUnwrap(URL(string: "fanficly://resume/5"))))
    }
}

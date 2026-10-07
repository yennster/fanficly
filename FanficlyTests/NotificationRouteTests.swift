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
}

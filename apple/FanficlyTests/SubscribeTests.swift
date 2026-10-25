import XCTest
import SwiftData
@testable import Fanficly

/// `AO3Client.subscribeToWork` against AO3's answers from otwarchive's
/// `SubscriptionsController#create`: both outcomes redirect back to the work
/// with a flash, and a stale session lands on the login page, all as a 200
/// once URLSession follows the redirect. Only a confirmation counts.
final class SubscribeClientTests: XCTestCase {
    private static let base = "https://archiveofourown.org"

    private static let signedInPage = """
    <html><head><meta name="csrf-token" content="T0K"></head><body>
    <div id="header"><ul id="greeting"><li><a href="/users/reader">Hi, reader!</a></li></ul></div>
    <div id="main" class="works-show"><ul class="work navigation actions"><li class="subscribe">
      <form id="new_subscription" action="/users/reader/subscriptions" method="post">
        <input type="submit" value="Subscribe">
      </form>
    </li></ul></div></body></html>
    """

    private static let signedOutPage = """
    <html><head><meta name="csrf-token" content="T0K"></head><body>
    <div id="header"><form id="new_user" action="/users/login" method="post"><input name="user[login]"></form></div>
    <div id="main" class="works-show"></div></body></html>
    """

    private func makeClient() -> AO3Client {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommentStubProtocol.self]
        return AO3Client(session: URLSession(configuration: config))
    }

    override func setUp() {
        super.setUp()
        CommentStubProtocol.answers = []
        CommentStubProtocol.requests = []
    }

    private func answer(_ path: String, status: Int = 200, _ html: String) -> CommentStubProtocol.Answer {
        .init(url: Self.base + path, status: status, html: html)
    }

    /// The work page, then AO3's answer to the POST.
    private func subscribeError(after answer: CommentStubProtocol.Answer?) async -> AO3Error? {
        CommentStubProtocol.answers = [self.answer("/works/42?view_adult=true", Self.signedInPage)]
        if let answer { CommentStubProtocol.answers.append(answer) }
        do {
            try await makeClient().subscribeToWork(workId: 42)
            return nil
        } catch let error as AO3Error {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    func test_successNoticeSubscribes() async throws {
        let error = await subscribeError(after: answer("/works/42", """
        <div id="main"><div class="flash notice">You are now following Of Maps and Mistakes. If you'd like to stop \
        receiving email updates, you can unsubscribe from <a href="/users/reader/subscriptions">your Subscriptions page</a>.</div></div>
        """))
        XCTAssertNil(error)
        let requests = CommentStubProtocol.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        // The light first page, not the whole work.
        let page = try XCTUnwrap(requests.first?.url)
        XCTAssertEqual(page.path, "/works/42")
        XCTAssertFalse(page.query?.contains("view_full_work") ?? false)
        let post = try XCTUnwrap(requests.last)
        XCTAssertEqual(post.url?.path, "/works/42/subscriptions")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-CSRF-Token"), "T0K")
    }

    func test_unsubscribeButtonSubscribes() async {
        let error = await subscribeError(after: answer("/works/42", """
        <div id="main" class="works-show"><li class="subscribe">
          <form action="/users/reader/subscriptions/99" method="post">
            <input type="hidden" name="_method" value="delete"><input type="submit" value="Unsubscribe">
          </form></li></div>
        """))
        XCTAssertNil(error)
    }

    func test_alreadySubscribedCountsAsSubscribed() async {
        let error = await subscribeError(after: answer("/works/42",
            #"<div id="main"><div class="flash error">You are already subscribed to that.</div></div>"#))
        XCTAssertNil(error)
    }

    func test_loginRedirectIsUnauthorized() async {
        let error = await subscribeError(after: answer("/users/login", """
        <div id="main" class="sessions-new"><div class="flash error">Sorry, you don't have permission to access \
        the page you were trying to reach. Please log in.</div>
        <form id="new_user" action="/users/login"><input name="user[login]"></form></div>
        """))
        XCTAssertEqual(error, .unauthorized)
    }

    func test_refusedTokenIsNotSubscribed() async {
        let error = await subscribeError(after: answer("/works/42/subscriptions", status: 422, "<html></html>"))
        XCTAssertEqual(error, .http(status: 422))
    }

    func test_errorFlashIsNotSubscribed() async {
        let error = await subscribeError(after: answer("/works/42",
            #"<div id="main"><div class="flash error">You can't subscribe to that.</div></div>"#))
        XCTAssertEqual(error, .subscribeRejected(message: "You can't subscribe to that."))
    }

    func test_pageWithoutConfirmationIsNotSubscribed() async {
        // The work again, its button still saying Subscribe: nothing confirms it.
        let error = await subscribeError(after: answer("/works/42", Self.signedInPage))
        guard case .subscribeRejected? = error else { return XCTFail("got \(String(describing: error))") }
    }

    func test_signedOutPageSendsNoPost() async {
        CommentStubProtocol.answers = [answer("/works/42?view_adult=true", Self.signedOutPage)]
        do {
            try await makeClient().subscribeToWork(workId: 42)
            XCTFail("subscribed while signed out")
        } catch {
            XCTAssertEqual(error as? AO3Error, .unauthorized)
        }
        XCTAssertEqual(CommentStubProtocol.requests.map(\.httpMethod), ["GET"])
    }

    func test_failedPostIsNotRetried() async {
        // No answer for the POST: the stub fails it like a dropped connection.
        let error = await subscribeError(after: nil)
        guard case .network? = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(CommentStubProtocol.requests.map(\.httpMethod), ["GET", "POST"])
    }
}

/// The menu item's model: what it sends and what it mirrors locally.
@MainActor
final class WorkSubscriberTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: SubscriptionRecord.self, configurations: config)
        return ModelContext(container)
    }

    private func records(_ context: ModelContext) throws -> [SubscriptionRecord] {
        try context.fetch(FetchDescriptor<SubscriptionRecord>())
    }

    func test_subscribingMirrorsARecordWithTodaysBaseline() async throws {
        let context = try makeContext()
        let client = StubAO3Client()
        let subscriber = WorkSubscriber()
        await subscriber.subscribe(workId: 42, title: "Of Maps", author: "tealeaf", chapterCount: 7,
                                   username: "reader", client: client, context: context)

        XCTAssertEqual(client.subscribeCalls, [42])
        XCTAssertTrue(subscriber.isSubscribed)
        XCTAssertEqual(subscriber.result?.title, "Subscribed on AO3")
        let record = try XCTUnwrap(records(context).first)
        XCTAssertEqual(record.key, "work:42")
        XCTAssertEqual(record.kind, "work")
        XCTAssertEqual(record.displayName, "Of Maps")
        XCTAssertEqual(record.authorName, "tealeaf")
        XCTAssertEqual(record.lastSeenChapterCount, 7)

        // A second tap sends nothing.
        await subscriber.subscribe(workId: 42, title: "Of Maps", author: "tealeaf", chapterCount: 7,
                                   username: "reader", client: client, context: context)
        XCTAssertEqual(client.subscribeCalls, [42])
    }

    func test_loggedOutSendsNothing() async throws {
        let context = try makeContext()
        let client = StubAO3Client()
        let subscriber = WorkSubscriber()
        await subscriber.subscribe(workId: 42, title: "x", author: "y", chapterCount: 1,
                                   username: nil, client: client, context: context)
        XCTAssertTrue(client.subscribeCalls.isEmpty)
        XCTAssertTrue(try records(context).isEmpty)
    }

    func test_failureMirrorsNothing() async throws {
        let context = try makeContext()
        let client = StubAO3Client()
        client.subscribeError = AO3Error.subscribeRejected(message: "You can't subscribe to that.")
        let subscriber = WorkSubscriber()
        await subscriber.subscribe(workId: 42, title: "x", author: "y", chapterCount: 1,
                                   username: "reader", client: client, context: context)
        XCTAssertFalse(subscriber.isSubscribed)
        XCTAssertEqual(subscriber.result?.message, "You can't subscribe to that.")
        XCTAssertTrue(try records(context).isEmpty)
    }

    func test_expiredSessionIsFlagged() async throws {
        let context = try makeContext()
        let client = StubAO3Client()
        client.subscribeError = AO3Error.unauthorized
        let subscriber = WorkSubscriber()
        await subscriber.subscribe(workId: 42, title: "x", author: "y", chapterCount: 1,
                                   username: "reader", client: client, context: context)
        XCTAssertTrue(subscriber.sessionExpired)
        XCTAssertFalse(subscriber.isSubscribed)
    }

    func test_anExistingRecordShowsAsSubscribed() throws {
        let context = try makeContext()
        context.insert(SubscriptionRecord(key: "work:42", kind: "work", displayName: "x"))
        let subscriber = WorkSubscriber()
        subscriber.refresh(workId: 42, in: context)
        XCTAssertTrue(subscriber.isSubscribed)
        subscriber.refresh(workId: 43, in: context)
        XCTAssertFalse(subscriber.isSubscribed)
    }
}

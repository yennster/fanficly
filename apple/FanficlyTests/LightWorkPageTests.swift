import XCTest
@testable import Fanficly

/// The new-chapter poll and subscribing read the work's light page (its first
/// chapter), never `view_full_work`, AO3's heaviest page (#148).
final class LightWorkPageTests: XCTestCase {
    private static let lightPage = "https://archiveofourown.org/works/77?view_adult=true"
    private static let workPage = Data(AO3PageFixtures.guestPage(mainClass: "works-show", body: """
    <meta name="csrf-token" content="TOK">
    <dl class="stats"><dt class="chapters">Chapters:</dt><dd class="chapters">3/?</dd></dl>
    """).utf8)

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func test_fetchWorkMetadata_readsTheLightPage() async throws {
        let sent = SentRequests()
        StubURLProtocol.responder = { request in
            sent.append(request)
            return (request.url!, Self.workPage)
        }

        let meta = try await client().fetchWorkMetadata(id: 77)

        XCTAssertEqual(meta.chapterCount, 3)
        XCTAssertEqual(sent.urls, [Self.lightPage])
    }

    func test_subscribe_takesItsTokenFromTheLightPage() async throws {
        let page = Data(AO3PageFixtures.signedInPage(mainClass: "works-show", body: """
        <meta name="csrf-token" content="TOK">
        <ul class="work navigation actions"><li class="subscribe">
          <form action="/users/reader/subscriptions" method="post">
            <input type="hidden" name="subscription[subscribable_id]" value="77">
            <input type="hidden" name="subscription[subscribable_type]" value="Work">
            <input type="submit" value="Subscribe">
          </form>
        </li></ul>
        """).utf8)
        let followed = Data(#"<div id="main"><div class="flash notice">You are now following Work 77.</div></div>"#.utf8)
        let sent = SentRequests()
        StubURLProtocol.responder = { request in
            sent.append(request)
            return (request.url!, request.httpMethod == "POST" ? followed : page)
        }

        try await client().subscribeToWork(workId: 77)

        XCTAssertEqual(sent.urls, [Self.lightPage, "https://archiveofourown.org/users/reader/subscriptions"])
        XCTAssertEqual(sent.requests.last?.value(forHTTPHeaderField: "X-CSRF-Token"), "TOK")
    }

    private func client() -> AO3Client {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AO3Client(session: URLSession(configuration: config))
    }
}

/// The requests a stub answered, in order.
private final class SentRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { sent.append(request) }
    }

    var requests: [URLRequest] { lock.withLock { sent } }
    var urls: [String] { requests.compactMap { $0.url?.absoluteString } }
}

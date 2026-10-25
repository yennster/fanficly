import XCTest
@testable import Fanficly

/// Keeps the login name in memory, so tests never touch the Keychain.
final class MemoryLoginNameStore: LoginNameStore, @unchecked Sendable {
    var username: String?
    init(_ username: String? = nil) { self.username = username }
    func storedUsername() -> String? { username }
    func setUsername(_ username: String?) { self.username = username }
}

/// Signing in with an email address (#144): AO3 accepts "Username or email",
/// but `/users/<name>` pages (Bookmarks, Marked for Later, Subscriptions, the
/// subscription poller) need the AO3 login name, so that's what gets stored.
@MainActor
final class LoginNameTests: XCTestCase {
    private static let base = "https://archiveofourown.org"

    private static let loginForm = """
    <html><head><meta name="csrf-token" content="TOK"></head><body>
    <form id="new_user" action="/users/login" method="post"><input name="user[login]"></form>
    </body></html>
    """

    /// A page AO3 renders for the signed-in reader `real_reader`.
    private static let signedInPage = """
    <html><body><div id="header"><ul id="greeting">
    <li><a href="/users/real_reader">Hi, real_reader!</a></li>
    <li><a href="/users/logout">Log Out</a></li>
    </ul></div><div id="main">Welcome</div></body></html>
    """

    private func makeClient() -> AO3Client {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommentStubProtocol.self]
        return AO3Client(session: URLSession(configuration: config))
    }

    private func answer(_ path: String, _ html: String) -> CommentStubProtocol.Answer {
        .init(url: Self.base + path, html: html)
    }

    override func setUp() {
        super.setUp()
        CommentStubProtocol.answers = []
        CommentStubProtocol.requests = []
    }

    func test_clientLoginWithEmail_returnsTheAO3LoginName() async throws {
        CommentStubProtocol.answers = [answer("/users/login", Self.loginForm), answer("/", Self.signedInPage)]
        let client = makeClient()
        let name = try await client.login(username: "reader@example.com", password: "pw")
        XCTAssertEqual(name, "real_reader")
        let current = await client.currentUsername()
        XCTAssertEqual(current, "real_reader")
        XCTAssertEqual(CommentStubProtocol.requests.map(\.httpMethod), ["GET", "POST"])
    }

    func test_signingInWithEmail_storesTheAO3LoginName() async {
        CommentStubProtocol.answers = [answer("/users/login", Self.loginForm), answer("/", Self.signedInPage)]
        let store = MemoryLoginNameStore()
        let auth = AuthState(store: store)
        await auth.login(using: makeClient(), username: "  reader@example.com\n", password: "pw")
        XCTAssertNil(auth.lastError)
        XCTAssertEqual(auth.username, "real_reader")
        XCTAssertEqual(store.username, "real_reader")
        XCTAssertTrue(auth.hasSession)
    }

    func test_storedEmailIsRepairedFromAO3sHeader() async {
        CommentStubProtocol.answers = [answer("/", Self.signedInPage)]
        let store = MemoryLoginNameStore("reader@example.com")
        let auth = AuthState(store: store)
        await auth.repairStoredLogin(using: makeClient())
        XCTAssertEqual(auth.username, "real_reader")
        XCTAssertEqual(store.username, "real_reader")
        XCTAssertEqual(CommentStubProtocol.requests.map { $0.url?.host }, ["archiveofourown.org"])
    }

    func test_storedEmailStaysWhenAO3ShowsAGuestPage() async {
        CommentStubProtocol.answers = [answer("/", "<html><body>\(AO3PageFixtures.guestHeader)</body></html>")]
        let store = MemoryLoginNameStore("reader@example.com")
        let auth = AuthState(store: store)
        await auth.repairStoredLogin(using: makeClient())
        XCTAssertEqual(auth.username, "reader@example.com")
        XCTAssertEqual(store.username, "reader@example.com")
    }

    func test_storedLoginNameNeedsNoRequest() async {
        let store = MemoryLoginNameStore("real_reader")
        let login = await AuthState.repairedLogin(store: store, client: makeClient())
        XCTAssertEqual(login, "real_reader")
        XCTAssertTrue(CommentStubProtocol.requests.isEmpty)
    }
}

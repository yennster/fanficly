import XCTest
@testable import Fanficly

/// Keeps cookies in memory and remembers every value it was asked to save, so
/// tests never touch the Keychain.
final class MemoryCookieVault: CookieVault, @unchecked Sendable {
    private let lock = NSLock()
    private var _cookies: [HTTPCookie] = []
    private var _savedValues: [String] = []

    init(_ cookies: [HTTPCookie] = []) { _cookies = cookies }

    var cookies: [HTTPCookie] { lock.withLock { _cookies } }
    /// Every cookie value ever saved, in order.
    var savedValues: [String] { lock.withLock { _savedValues } }

    func saveCookies(_ cookies: [HTTPCookie]) {
        lock.withLock {
            _cookies = cookies
            _savedValues += cookies.map(\.value)
        }
    }

    func loadCookies() -> [HTTPCookie] { cookies }
    func clearCookies() { lock.withLock { _cookies = [] } }
}

/// Answers by method and path ("GET /"), sets each answer's cookie in `jar` before the response
/// arrives (as URLSession does), and can hold one path's answer until the
/// test releases it: a request still running when the reader signs out.
final class SignOutStubProtocol: URLProtocol {
    struct Answer {
        var html: String
        var setCookie: String?
    }

    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var jar: HTTPCookieStorage?
    nonisolated(unsafe) static var heldPath: String?
    nonisolated(unsafe) static var heldStarted = false
    nonisolated(unsafe) static var release = DispatchSemaphore(value: 0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let url = request.url, let answer = Self.answers["\(request.httpMethod ?? "GET") \(url.path)"] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard url.path == Self.heldPath else { return deliver(answer, for: url) }
        Self.heldStarted = true
        nonisolated(unsafe) let me = self
        DispatchQueue.global().async {
            Self.release.wait()
            me.deliver(answer, for: url)
        }
    }

    private func deliver(_ answer: Answer, for url: URL) {
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        if let setCookie = answer.setCookie {
            headers["Set-Cookie"] = setCookie
            Self.jar?.setCookies(HTTPCookie.cookies(withResponseHeaderFields: headers, for: url), for: url, mainDocumentURL: nil)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Signing out signs out (#145): AO3 is told, a response that was already on
/// its way can't bring the session back, and a reinstall starts signed out.
@MainActor
final class SignOutTests: XCTestCase {
    private static let base = URL(string: "https://archiveofourown.org")!

    private static let loginForm = """
    <html><head><meta name="csrf-token" content="LOGIN_TOK"></head><body>
    <form id="new_user" action="/users/login" method="post"><input name="user[login]"></form>
    </body></html>
    """

    private static let signedInPage = """
    <html><head><meta name="csrf-token" content="LOGOUT_TOK"></head><body>
    <div id="header"><ul id="greeting">
    <li><a href="/users/reader">Hi, reader!</a></li>
    <li><a href="/users/logout">Log Out</a></li>
    </ul></div><div id="main">Welcome</div></body></html>
    """

    private var jar: HTTPCookieStorage!

    override func setUp() {
        super.setUp()
        SignOutStubProtocol.answers = [:]
        SignOutStubProtocol.requests = []
        SignOutStubProtocol.heldPath = nil
        SignOutStubProtocol.heldStarted = false
        SignOutStubProtocol.release = DispatchSemaphore(value: 0)
    }

    override func tearDown() {
        SignOutStubProtocol.release.signal()
        SignOutStubProtocol.jar = nil
        super.tearDown()
    }

    private func makeClient(vault: MemoryCookieVault, names: MemoryLoginNameStore) -> AO3Client {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SignOutStubProtocol.self]
        jar = config.httpCookieStorage
        SignOutStubProtocol.jar = jar
        return AO3Client(session: URLSession(configuration: config), vault: vault, loginNames: names)
    }

    private var siteCookieValues: [String] { (jar.cookies(for: Self.base) ?? []).map(\.value) }

    private func waitForHeldRequest() async throws {
        for _ in 0..<200 where !SignOutStubProtocol.heldStarted {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(SignOutStubProtocol.heldStarted, "the held request never started")
    }

    func test_responseArrivingAfterLogout_doesNotKeepOrSaveItsCookie() async throws {
        SignOutStubProtocol.answers = [
            "GET /users/login": .init(html: Self.loginForm),
            "POST /users/login": .init(html: Self.signedInPage, setCookie: "_otwarchive_session=SIGNED_IN; path=/; secure"),
            "GET /": .init(html: Self.signedInPage),
            "POST /users/logout": .init(html: "<html><body>Signed out</body></html>",
                                   setCookie: "_otwarchive_session=GUEST; path=/; secure"),
            "GET /works/1": .init(html: "<html><body></body></html>",
                              setCookie: "_otwarchive_session=LATE; path=/; secure"),
        ]
        let vault = MemoryCookieVault()
        let names = MemoryLoginNameStore()
        let client = makeClient(vault: vault, names: names)
        let auth = AuthState(store: names)
        await auth.login(using: client, username: "reader", password: "pw")
        XCTAssertEqual(auth.username, "reader")
        XCTAssertEqual(siteCookieValues, ["SIGNED_IN"])

        // A request (the poller, a search) is still waiting on AO3 when the
        // reader signs out.
        SignOutStubProtocol.heldPath = "/works/1"
        let running = Task { try? await client.fetchWorkMetadata(id: 1) }
        try await waitForHeldRequest()
        await auth.logout(using: client)
        XCTAssertEqual(siteCookieValues, [])

        SignOutStubProtocol.release.signal()
        _ = await running.value

        XCTAssertEqual(siteCookieValues, [], "the late session cookie stayed in the jar")
        XCTAssertFalse(vault.savedValues.contains("LATE"), "the late session cookie was saved")
        XCTAssertFalse(vault.savedValues.contains("GUEST"))
        XCTAssertTrue(vault.cookies.isEmpty)
        XCTAssertNil(names.username)
    }

    func test_logout_endsTheSessionOnAO3_once() async throws {
        SignOutStubProtocol.answers = [
            "GET /users/login": .init(html: Self.loginForm),
            "POST /users/login": .init(html: Self.signedInPage, setCookie: "_otwarchive_session=SIGNED_IN; path=/; secure"),
            "GET /": .init(html: Self.signedInPage),
            "POST /users/logout": .init(html: "<html><body>Signed out</body></html>"),
        ]
        let names = MemoryLoginNameStore()
        let client = makeClient(vault: MemoryCookieVault(), names: names)
        _ = try await client.login(username: "reader", password: "pw")
        SignOutStubProtocol.requests = []

        await client.logout()

        let sent = SignOutStubProtocol.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        XCTAssertEqual(sent, ["GET /", "POST /users/logout"])
        let post = try XCTUnwrap(SignOutStubProtocol.requests.last)
        let body = String(data: post.httpBody ?? post.bodyStreamData ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("_method=delete"), body)
        XCTAssertTrue(body.contains("authenticity_token=LOGOUT_TOK"), body)
        XCTAssertEqual(siteCookieValues, [])
    }

    func test_logoutWhenAO3CantBeReached_stillSignsOutHere() async throws {
        SignOutStubProtocol.answers = [
            "GET /users/login": .init(html: Self.loginForm),
            "POST /users/login": .init(html: Self.signedInPage, setCookie: "_otwarchive_session=SIGNED_IN; path=/; secure"),
            "GET /": .init(html: Self.signedInPage),
        ]
        let vault = MemoryCookieVault()
        let client = makeClient(vault: vault, names: MemoryLoginNameStore())
        _ = try await client.login(username: "reader", password: "pw")
        SignOutStubProtocol.answers = [:] // offline
        SignOutStubProtocol.requests = []

        await client.logout()

        XCTAssertEqual(SignOutStubProtocol.requests.count, 1, "the logout page must not be retried")
        XCTAssertEqual(siteCookieValues, [])
    }

    func test_signedOut_savedCookiesAreNotLoaded() async throws {
        let stale = try XCTUnwrap(HTTPCookie(properties: [
            .name: "remember_user_token", .value: "OLD", .domain: "archiveofourown.org", .path: "/",
        ]))
        SignOutStubProtocol.answers = ["GET /works/1": .init(html: "<html><body></body></html>")]
        let client = makeClient(vault: MemoryCookieVault([stale]), names: MemoryLoginNameStore())
        _ = try? await client.fetchWorkMetadata(id: 1)
        XCTAssertEqual(siteCookieValues, [])
    }

    // MARK: - Cookie saves

    func test_cookieSaves_stopAtSignOut() {
        let vault = MemoryCookieVault()
        let persistence = CookiePersistence(vault: vault, signedIn: true)
        let cookie = HTTPCookie(properties: [.name: "_otwarchive_session", .value: "A",
                                             .domain: "archiveofourown.org", .path: "/"])!
        persistence.cookiesChanged([cookie])
        persistence.signedOut()
        persistence.cookiesChanged([cookie])
        persistence.flush()
        XCTAssertTrue(vault.cookies.isEmpty)
        XCTAssertFalse(persistence.isSignedIn)

        persistence.signedIn(with: [cookie])
        persistence.flush()
        XCTAssertEqual(vault.cookies.map(\.value), ["A"])
    }

    // MARK: - Reinstall

    private func freshDefaults() -> UserDefaults {
        let name = "SignOutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func test_firstLaunchOfAFreshInstall_clearsTheKeychain() {
        let defaults = freshDefaults()
        var cleared = 0
        XCTAssertTrue(CredentialStore.forgetPreviousInstall(defaults: defaults) { cleared += 1 })
        XCTAssertFalse(CredentialStore.forgetPreviousInstall(defaults: defaults) { cleared += 1 })
        XCTAssertEqual(cleared, 1)
    }

    func test_updateFromABuildWithoutTheFlag_keepsTheSignIn() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: ContentControl.ageConfirmedKey)
        var cleared = false
        XCTAssertFalse(CredentialStore.forgetPreviousInstall(defaults: defaults) { cleared = true })
        XCTAssertFalse(cleared)
        XCTAssertTrue(defaults.bool(forKey: CredentialStore.installedKey))
    }
}

private extension URLRequest {
    /// URLProtocol sees a POST body as a stream.
    var bodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

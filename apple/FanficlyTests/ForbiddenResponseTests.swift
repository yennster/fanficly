import XCTest
@testable import Fanficly

/// A 403 is a sign-in problem only when it's AO3's login page (#146).
/// Cloudflare's bot challenge and block pages, and AO3's own "forbidden"
/// pages, answer 403 to signed-out readers too, so they get their own errors
/// and never mark a signed-in reader's session expired. Every `AO3Error`
/// reads as a sentence, never as the enum.
final class ForbiddenResponseTests: XCTestCase {
    private static let searchURL = URL(string: "https://archiveofourown.org/works/search?work_search%5Bquery%5D=x")!
    private static let loginURL = URL(string: "https://archiveofourown.org/users/login?restricted=true")!

    /// Cloudflare's managed challenge ("Just a moment..."), trimmed.
    private static let challengePage = """
    <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>
    <meta http-equiv="refresh" content="390"></head><body>
    <div class="main-wrapper" role="main"><div class="main-content">
    <h1 class="zone-name-title h1">archiveofourown.org</h1>
    <h2 class="h2" id="challenge-running">Checking if the site connection is secure</h2></div></div>
    <script>(function(){window._cf_chl_opt={cvId: '3',cZone: "archiveofourown.org",cType: 'managed'};}());</script>
    </body></html>
    """

    /// Cloudflare's firewall block page (error 1020), trimmed.
    private static let blockPage = """
    <!DOCTYPE html><html lang="en-US"><head><title>Attention Required! | Cloudflare</title></head><body>
    <div id="cf-wrapper"><div id="cf-error-details" class="cf-error-details-wrapper">
    <h1 data-translate="block_headline">Sorry, you have been blocked</h1>
    <h2 class="cf-subheadline">You are unable to access archiveofourown.org</h2></div></div>
    </body></html>
    """

    /// An AO3 page that isn't the login page, with the bot-detection script
    /// Cloudflare injects into ordinary pages.
    private static let ao3ForbiddenPage = AO3PageFixtures.guestPage(mainClass: "errors-forbidden", body: """
    <h2 class="heading">Error 403</h2>
    <p>Sorry, you don't have permission to access the page you were trying to reach.</p>
    <script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>
    """)

    override func tearDown() {
        StatusStubProtocol.responder = nil
        super.tearDown()
    }

    // MARK: - Classifying a 403

    func test_cfMitigatedHeader_isBlockedByProtection() {
        XCTAssertEqual(classify(Data(), headers: ["cf-mitigated": "challenge", "Server": "cloudflare"]),
                       .blockedByProtection)
    }

    /// Cloudflare can challenge the login page itself: signing in again
    /// wouldn't help there either.
    func test_cloudflareOnTheLoginURL_isBlockedByProtection() {
        XCTAssertEqual(classify(Data(), url: Self.loginURL, headers: ["cf-mitigated": "challenge"]), .blockedByProtection)
        XCTAssertEqual(classify(Data(Self.challengePage.utf8), url: Self.loginURL), .blockedByProtection)
    }

    func test_challengeAndBlockPages_areBlockedByProtection_withoutTheHeader() {
        XCTAssertEqual(classify(Data(Self.challengePage.utf8)), .blockedByProtection)
        XCTAssertEqual(classify(Data(Self.blockPage.utf8)), .blockedByProtection)
    }

    func test_loginPage_isUnauthorized() {
        XCTAssertEqual(classify(Data(AO3PageFixtures.loginPage.utf8)), .unauthorized)
        XCTAssertEqual(classify(Data(), url: Self.loginURL), .unauthorized)
    }

    func test_ao3sOwnForbiddenPage_isForbidden_evenServedThroughCloudflare() {
        XCTAssertEqual(classify(Data(Self.ao3ForbiddenPage.utf8), headers: ["Server": "cloudflare"]), .forbidden)
        XCTAssertEqual(classify(Data()), .forbidden)
    }

    // MARK: - Through the client

    func test_client_cloudflare403_throwsBlockedByProtection() async {
        StatusStubProtocol.responder = { request in
            (request.url!, 403, ["cf-mitigated": "challenge", "Server": "cloudflare"], Data(Self.challengePage.utf8))
        }
        await assertSearchThrows(.blockedByProtection)
    }

    func test_client_login403_throwsUnauthorized() async {
        StatusStubProtocol.responder = { request in
            (request.url!, 403, ["Server": "cloudflare"], Data(AO3PageFixtures.loginPage.utf8))
        }
        await assertSearchThrows(.unauthorized)
    }

    func test_client_plain403_throwsForbidden_and401_throwsUnauthorized() async {
        StatusStubProtocol.responder = { request in (request.url!, 403, [:], Data(Self.ao3ForbiddenPage.utf8)) }
        await assertSearchThrows(.forbidden)
        StatusStubProtocol.responder = { request in (request.url!, 401, [:], Data()) }
        await assertSearchThrows(.unauthorized)
    }

    @MainActor
    func test_onlyUnauthorized_expiresTheSession() {
        let auth = AuthState()
        auth.username = "reader"
        XCTAssertFalse(auth.explains(AO3Error.blockedByProtection))
        XCTAssertFalse(auth.explains(AO3Error.forbidden))
        XCTAssertTrue(auth.hasSession)
        XCTAssertTrue(auth.explains(AO3Error.unauthorized))
    }

    // MARK: - Readable text

    func test_everyError_readsAsASentence() {
        let errors: [AO3Error] = [
            .loginFailed(reason: "Incorrect username or password."), .rateLimited, .unauthorized,
            .parseFailed(reason: "Not a works listing"), .http(status: 404), .http(status: 503),
            .network(underlying: "The request timed out."), .network(underlying: "Non-HTTP response"), .kudosRejected(message: "You can't leave kudos on your own work."),
            .commentRejected(message: "The comment is empty."), .forbidden, .blockedByProtection,
        ]
        for error in errors {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("AO3Error"), text)
            XCTAssertFalse(text.contains("operation couldn"), text)
            XCTAssertFalse(text.contains("reason:") || text.contains("underlying:") || text.contains("status:"), text)
        }
        XCTAssertEqual(AO3Error.blockedByProtection.localizedDescription,
                       "AO3's protection blocked the request. Wait a few minutes, then try again.")
        XCTAssertEqual(AO3Error.network(underlying: "Non-HTTP response").localizedDescription,
                       "Couldn't reach AO3: Non-HTTP response.")
        XCTAssertEqual(AO3Error.parseFailed(reason: "Not a works listing").localizedDescription,
                       "Couldn't read AO3's response: Not a works listing.")
    }

    func test_parseFailedSentence_isShownAsIs() {
        let reason = "Your AO3 reading history is turned off. Check \"Turn on History\" in your AO3 preferences to see this list."
        XCTAssertEqual(AO3Error.parseFailed(reason: reason).localizedDescription, reason)
    }

    // MARK: - Helpers

    private func classify(_ body: Data, url: URL = searchURL, headers: [String: String] = [:]) -> AO3Error {
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: headers)!
        return AO3Client.forbiddenError(data: body, response: response)
    }

    private func assertSearchThrows(_ expected: AO3Error, file: StaticString = #filePath, line: UInt = #line) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatusStubProtocol.self]
        let client = AO3Client(session: URLSession(configuration: config))
        do {
            _ = try await client.search(filters: AO3SearchFilters(), page: 1)
            XCTFail("Expected \(expected), got no error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AO3Error, expected, file: file, line: line)
        }
    }
}

/// Answers every request with the responder's URL, status, headers and body.
final class StatusStubProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (URL, Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (url, status, headers, data) = responder(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

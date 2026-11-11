import XCTest
@testable import Fanficly

/// A failed Popular refresh or tag lookup must never be cached as if it
/// succeeded (#196): the Popular crawl stops on a rate limit or sign-in and
/// throws when nothing live came back, so `PopularStore` keeps its last good
/// snapshot; autocomplete throws on an unreadable answer, so the suggestion
/// cache and `TagResolver` don't memoize it as "no match" (TagResolverTests
/// covers the resolver's side).
final class LookupFailureCachingTests: XCTestCase {
    private static let popularKey = "popular.snapshot.v1"
    private var savedPopular: Data?

    override func setUp() {
        super.setUp()
        savedPopular = UserDefaults.standard.data(forKey: Self.popularKey)
    }

    override func tearDown() {
        StatusStubProtocol.responder = nil
        CountingStub.reset()
        if let savedPopular {
            UserDefaults.standard.set(savedPopular, forKey: Self.popularKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.popularKey)
        }
        super.tearDown()
    }

    // MARK: - Popular crawl

    func test_popular_rateLimited_stopsAfterTheFirstRequestAndThrows() async {
        CountingStub.respond(status: 429, body: Data())
        await assertPopularThrows(.rateLimited)
        XCTAssertEqual(CountingStub.count, 1, "no more requests after AO3 said to slow down")
    }

    func test_popular_unauthorized_stopsAfterTheFirstRequestAndThrows() async {
        CountingStub.respond(status: 401, body: Data())
        await assertPopularThrows(.unauthorized)
        XCTAssertEqual(CountingStub.count, 1)
    }

    func test_stopsPopularCrawl_onlyForErrorsEveryLaterRequestWouldHitToo() {
        XCTAssertTrue(AO3Client.stopsPopularCrawl(AO3Error.rateLimited))
        XCTAssertTrue(AO3Client.stopsPopularCrawl(AO3Error.unauthorized))
        XCTAssertTrue(AO3Client.stopsPopularCrawl(AO3Error.blockedByProtection))
        XCTAssertTrue(AO3Client.stopsPopularCrawl(CancellationError()))
        XCTAssertFalse(AO3Client.stopsPopularCrawl(AO3Error.http(status: 404)))
        XCTAssertFalse(AO3Client.stopsPopularCrawl(AO3Error.parseFailed(reason: "x")))
        XCTAssertFalse(AO3Client.stopsPopularCrawl(AO3Error.network(underlying: "offline")))
    }

    // MARK: - PopularStore

    func test_popularStore_keepsTheCachedSnapshotWhenARefreshFails() async throws {
        let old = PopularSnapshot(fandoms: ["Live Fandom"], ships: ["A/B"], characters: ["Cee"],
                                  fetchedAt: Date.now.addingTimeInterval(-2 * 24 * 60 * 60))
        UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: Self.popularKey)
        let client = StubAO3Client()
        client.popularResult = .failure(AO3Error.network(underlying: "offline"))

        let shown = await PopularStore.refreshIfStale(client: client)

        XCTAssertEqual(shown, old)
        XCTAssertEqual(PopularStore.cached(), old, "the failed refresh must not replace the last good snapshot")
        XCTAssertTrue(PopularStore.isStale(PopularStore.cached()), "so the next visit tries again")
    }

    func test_popularStore_cachesASuccessfulRefresh() async {
        UserDefaults.standard.removeObject(forKey: Self.popularKey)
        let client = StubAO3Client()
        let fresh = PopularSnapshot(fandoms: ["New"], ships: ["X/Y"], characters: ["Zed"])
        client.popularResult = .success(fresh)

        let shown = await PopularStore.refreshIfStale(client: client)

        XCTAssertEqual(shown, fresh)
        XCTAssertEqual(PopularStore.cached(), fresh)
    }

    // MARK: - Autocomplete

    func test_decodeAutocomplete_readsNamesThenIds() throws {
        let json = Data(#"[{"id":"Harry Potter/Draco Malfoy","name":"Harry Potter/Draco Malfoy"},{"id":"Only Id"},{"id":null,"name":null}]"#.utf8)
        XCTAssertEqual(try AO3Client.decodeAutocomplete(json), ["Harry Potter/Draco Malfoy", "Only Id"])
        XCTAssertEqual(try AO3Client.decodeAutocomplete(Data("[]".utf8)), [])
    }

    func test_decodeAutocomplete_htmlPage_throwsParseFailed() {
        let page = Data("<!DOCTYPE html><html><head><title>Just a moment...</title></head></html>".utf8)
        XCTAssertThrowsError(try AO3Client.decodeAutocomplete(page)) { error in
            guard case .parseFailed = error as? AO3Error else { return XCTFail("expected parseFailed, got \(error)") }
        }
    }

    func test_autocomplete_htmlServedWith200_throwsInsteadOfNoMatch() async {
        StatusStubProtocol.responder = { request in
            (request.url!, 200, ["Content-Type": "text/html"], Data("<html><body>Error</body></html>".utf8))
        }
        let client = AO3Client(session: Self.session(StatusStubProtocol.self))
        do {
            let names = try await client.autocomplete(field: .tag, term: "slow burn")
            XCTFail("Expected parseFailed, got \(names)")
        } catch {
            guard case .parseFailed = error as? AO3Error else { return XCTFail("expected parseFailed, got \(error)") }
        }
    }

    // MARK: - Helpers

    private func assertPopularThrows(_ expected: AO3Error, file: StaticString = #filePath, line: UInt = #line) async {
        let client = AO3Client(session: Self.session(CountingStub.self))
        do {
            let snapshot = try await client.fetchPopularSnapshot()
            XCTFail("Expected \(expected), got \(snapshot)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AO3Error, expected, file: file, line: line)
        }
    }

    private static func session(_ protocolClass: AnyClass) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return URLSession(configuration: config)
    }
}

/// Answers every request with one status and body, counting the requests.
final class CountingStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var requests = 0

    static var count: Int { lock.withLock { requests } }

    static func respond(status: Int, body: Data) {
        lock.withLock { Self.status = status; Self.body = body; requests = 0 }
    }

    static func reset() { respond(status: 200, body: Data()) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock { () -> (Int, Data) in
            Self.requests += 1
            return (Self.status, Self.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

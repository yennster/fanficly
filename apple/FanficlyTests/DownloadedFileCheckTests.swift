import XCTest
@testable import Fanficly

/// A download is saved only when it really is the file: AO3's login page (a
/// restricted work fetched signed out, which URLSession follows to a 200) or an
/// error page must never be written as the EPUB or an export, or the Library
/// shows the work as Downloaded.
final class DownloadedFileCheckTests: XCTestCase {
    private static let base = URL(string: "https://archiveofourown.org")!
    private static let loginURL = URL(string: "https://archiveofourown.org/users/login?restricted=true")!
    private static let workId = 128_000_128

    private static let zip = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 64)
    private static let mobi = Data(repeating: 0, count: 60) + Data("BOOKMOBI".utf8) + Data(repeating: 0, count: 16)
    private static let pdf = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\n".utf8)
    private static let htmlDownload = Data("""
    <!DOCTYPE html><html><head><title>A Fic</title></head><body>
    <div id="preface"><h1>A Fic</h1></div>
    <div id="chapters" class="userstuff"><div class="userstuff"><p>Once upon a time.</p></div></div>
    <div id="afterword"></div>
    </body></html>
    """.utf8)
    private static let loginPage = Data(AO3PageFixtures.loginPage.utf8)
    private static let errorPage = Data("""
    <html><body><div id="main" class="region"><h2>Error 502</h2>
    <p>The page was responding too slowly.</p></div></body></html>
    """.utf8)

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    // MARK: - The check

    func test_realFiles_pass() {
        let workURL = URL(string: "https://archiveofourown.org/downloads/1/work.epub")!
        XCTAssertNoThrow(try AO3Client.ensureDownloadedFile(Self.zip, finalURL: workURL, format: .epub))
        XCTAssertNoThrow(try AO3Client.ensureDownloadedFile(Self.mobi, finalURL: workURL, format: .azw3))
        XCTAssertNoThrow(try AO3Client.ensureDownloadedFile(Self.mobi, finalURL: workURL, format: .mobi))
        XCTAssertNoThrow(try AO3Client.ensureDownloadedFile(Self.pdf, finalURL: workURL, format: .pdf))
        XCTAssertNoThrow(try AO3Client.ensureDownloadedFile(Self.htmlDownload, finalURL: workURL, format: .html))
    }

    func test_endingAtTheLoginURL_isUnauthorized_evenForAFileShapedBody() {
        assertThrows(.unauthorized) {
            try AO3Client.ensureDownloadedFile(Self.zip, finalURL: Self.loginURL, format: .epub)
        }
    }

    func test_loginPage_isUnauthorized_forEveryFormat() {
        for format in WorkExportFormat.allCases {
            assertThrows(.unauthorized, format.displayName) {
                try AO3Client.ensureDownloadedFile(Self.loginPage, finalURL: nil, format: format)
            }
        }
    }

    func test_errorPage_failsToParse_forEveryFormat() {
        for format in WorkExportFormat.allCases {
            assertThrows(.parseFailed(reason: "AO3 didn't send the \(format.displayName) file"), format.displayName) {
                try AO3Client.ensureDownloadedFile(Self.errorPage, finalURL: nil, format: format)
            }
        }
    }

    func test_wrongFormatAndEmptyBody_fail() {
        assertThrows(.parseFailed(reason: "AO3 didn't send the PDF file")) {
            try AO3Client.ensureDownloadedFile(Self.zip, finalURL: nil, format: .pdf)
        }
        assertThrows(.parseFailed(reason: "AO3 didn't send the EPUB file")) {
            try AO3Client.ensureDownloadedFile(Data(), finalURL: nil, format: .epub)
        }
    }

    // MARK: - Through the client: nothing is written

    func test_downloadEPUB_ofLoginPage_throwsUnauthorized_andWritesNothing() async throws {
        let file = try epubFile()
        try? FileManager.default.removeItem(at: file)
        StubURLProtocol.responder = { _ in (Self.loginURL, Self.loginPage) }

        await assertThrowsAsync(.unauthorized) {
            _ = try await self.client().downloadEPUB(workId: Self.workId)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(WorkPersistence.epubURL(workId: Self.workId))
    }

    func test_downloadEPUB_ofErrorPage_throwsParseFailed_andWritesNothing() async throws {
        let file = try epubFile()
        try? FileManager.default.removeItem(at: file)
        StubURLProtocol.responder = { request in (request.url!, Self.errorPage) }

        await assertThrowsAsync(.parseFailed(reason: "AO3 didn't send the EPUB file")) {
            _ = try await self.client().downloadEPUB(workId: Self.workId)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_downloadEPUB_ofRealEPUB_writesIt() async throws {
        let file = try epubFile()
        defer { try? FileManager.default.removeItem(at: file) }
        StubURLProtocol.responder = { request in (request.url!, Self.zip) }

        let url = try await client().downloadEPUB(workId: Self.workId)
        XCTAssertEqual(url.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Self.zip)
    }

    func test_exportWork_ofLoginOrErrorPage_writesNothing() async throws {
        let title = "Download Check \(Self.workId)"
        let exports = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)

        StubURLProtocol.responder = { _ in (Self.loginURL, Self.loginPage) }
        let pdf = exports.appendingPathComponent("\(title).pdf")
        try? FileManager.default.removeItem(at: pdf)
        await assertThrowsAsync(.unauthorized) {
            _ = try await self.client().exportWork(workId: Self.workId, format: .pdf, filename: title)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))

        StubURLProtocol.responder = { request in (request.url!, Self.errorPage) }
        let html = exports.appendingPathComponent("\(title).html")
        try? FileManager.default.removeItem(at: html)
        await assertThrowsAsync(.parseFailed(reason: "AO3 didn't send the HTML file")) {
            _ = try await self.client().exportWork(workId: Self.workId, format: .html, filename: title)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: html.path))
    }

    // MARK: - Helpers

    private func client() -> AO3Client {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AO3Client(session: URLSession(configuration: config))
    }

    private func epubFile() throws -> URL {
        try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("library/\(Self.workId).epub")
    }

    private func assertThrows(_ expected: AO3Error, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) { error in
            XCTAssertEqual(error as? AO3Error, expected, message, file: file, line: line)
        }
    }

    private func assertThrowsAsync(_ expected: AO3Error,
                                   file: StaticString = #filePath, line: UInt = #line,
                                   _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected \(expected), got no error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AO3Error, expected, file: file, line: line)
        }
    }
}

/// Answers every request with the responder's final URL (where a followed
/// redirect ended) and body, as a 200.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (URL, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (url, data) = responder(request)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

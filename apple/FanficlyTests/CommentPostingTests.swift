import XCTest
@testable import Fanficly

/// Answers the client's requests from a script instead of AO3. The response's
/// URL is the page URLSession would land on after following AO3's redirect.
final class CommentStubProtocol: URLProtocol {
    struct Answer {
        var url: String
        var status = 200
        var html: String
    }

    nonisolated(unsafe) static var answers: [Answer] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard !Self.answers.isEmpty,
              let url = URL(string: Self.answers[0].url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let answer = Self.answers.removeFirst()
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `AO3Client.postComment` against AO3's answers from otwarchive's
/// `CommentsController#create`: a refused comment comes back as a 200 page or a
/// followed redirect, never an error status, so it mustn't read as posted.
final class CommentPostingTests: XCTestCase {
    private static let base = "https://archiveofourown.org"
    private static let action = "/works/12/chapters/34/comments"

    private static let signedInPage = """
    <html><body><div id="header"><ul id="greeting"><li><a href="/users/reader">Hi, reader!</a></li></ul></div>
    <div id="main" class="chapters-show">
      <form action="\(CommentPostingTests.action)" method="post" id="comment_for_34">
        <input type="hidden" name="authenticity_token" value="TOK">
        <input type="hidden" name="comment[pseud_id]" value="20">
        <textarea name="comment[comment_content]"></textarea>
      </form>
    </div></body></html>
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

    private func answer(_ path: String, _ html: String) -> CommentStubProtocol.Answer {
        .init(url: Self.base + path, html: html)
    }

    private func postError(_ text: String = "Loved it!") async -> AO3Error? {
        do {
            try await makeClient().postComment(workId: 12, chapterId: 34, text: text)
            return nil
        } catch let error as AO3Error {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    func test_postsWhenAO3ShowsTheCommentNotice() async {
        CommentStubProtocol.answers = [
            answer("/works/12/chapters/34?show_comments=true", Self.signedInPage),
            answer("/works/12/chapters/34?show_comments=true",
                   #"<div id="main"><div class="flash comment_notice">Comment created!</div></div>"#),
        ]
        let error = await postError()
        XCTAssertNil(error)
        XCTAssertEqual(CommentStubProtocol.requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertEqual(CommentStubProtocol.requests.last?.url?.path, Self.action)
    }

    func test_reRenderedErrorPageThrows() async {
        CommentStubProtocol.answers = [
            answer("/works/12/chapters/34?show_comments=true", Self.signedInPage),
            answer(Self.action, """
            <div id="main" class="comments-create"><div class="flash error">Couldn't save comment!</div>
            <div id="error" class="error"><ul><li>Comment content can't be blank.</li></ul></div></div>
            """),
        ]
        let error = await postError()
        XCTAssertEqual(error, .commentRejected(message: "Couldn't save comment! Comment content can't be blank."))
    }

    func test_loginRedirectThrowsUnauthorized() async {
        CommentStubProtocol.answers = [
            answer("/works/12/chapters/34?show_comments=true", Self.signedInPage),
            answer("/users/login",
                   #"<div id="main" class="sessions-new"><form id="new_user" action="/users/login"><input name="user[login]"></form></div>"#),
        ]
        let error = await postError()
        XCTAssertEqual(error, .unauthorized)
    }

    func test_guestFormThrowsUnauthorizedWithoutPosting() async {
        CommentStubProtocol.answers = [
            answer("/works/12/chapters/34?show_comments=true", """
            <html><body><div id="main" class="chapters-show">
              <form action="\(Self.action)" method="post">
                <input type="hidden" name="authenticity_token" value="TOK">
                <input type="text" name="comment[name]"><input type="text" name="comment[email]">
                <textarea name="comment[comment_content]"></textarea>
              </form>
            </div></body></html>
            """),
        ]
        let error = await postError()
        XCTAssertEqual(error, .unauthorized)
        XCTAssertEqual(CommentStubProtocol.requests.map(\.httpMethod), ["GET"])
    }

    func test_blankTextThrowsWithoutARequest() async {
        let error = await postError(" \n ")
        XCTAssertEqual(error, .commentRejected(message: "The comment is empty."))
        XCTAssertTrue(CommentStubProtocol.requests.isEmpty)
    }
}

import Foundation
import os

public protocol AO3ClientProtocol: Sendable {
    func login(username: String, password: String) async throws
    func logout() async
    func currentUsername() async -> String?
    func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults
    func fetchAuthorWorks(username: String, page: Int) async throws -> AO3SearchResults
    func fetchWork(id: Int) async throws -> AO3WorkPayload
    func fetchWorkMetadata(id: Int) async throws -> AO3WorkMetadata
    func fetchSubscriptions(username: String) async throws -> [AO3Subscription]
    func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom]
    func autocomplete(field: AO3AutocompleteField, term: String) async throws -> [String]
    func downloadEPUB(workId: Int) async throws -> URL
    func exportWork(workId: Int, format: WorkExportFormat, filename: String) async throws -> URL
    func subscribeToWork(workId: Int) async throws
}

public struct AO3SearchResults: Sendable, Equatable {
    public let works: [AO3WorkSummary]
    public let totalPages: Int
    public let currentPage: Int
}

public struct AO3WorkSummary: Sendable, Equatable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let author: String
    /// The author's AO3 login (the `/users/<login>` segment), used to open
    /// their works page. Empty for anonymous works or when not parsed.
    public let authorUsername: String
    public let summary: String
    public let rating: String
    public let warnings: [String]
    public let categories: [String]
    public let fandoms: [String]
    public let characters: [String]
    public let relationships: [String]
    public let freeforms: [String]
    public let wordCount: Int
    public let chapterCount: Int
    public let totalChapters: Int?
    public let language: String
    public let kudos: Int
    public let hits: Int
    public let isComplete: Bool
    public let updatedAt: Date?

    // Explicit init (rather than the synthesized memberwise one) so adding
    // `authorUsername` with a default keeps every existing call site compiling.
    public init(
        id: Int, title: String, author: String, authorUsername: String = "",
        summary: String, rating: String, warnings: [String], categories: [String],
        fandoms: [String], characters: [String], relationships: [String], freeforms: [String],
        wordCount: Int, chapterCount: Int, totalChapters: Int?, language: String,
        kudos: Int, hits: Int, isComplete: Bool, updatedAt: Date?
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.authorUsername = authorUsername
        self.summary = summary
        self.rating = rating
        self.warnings = warnings
        self.categories = categories
        self.fandoms = fandoms
        self.characters = characters
        self.relationships = relationships
        self.freeforms = freeforms
        self.wordCount = wordCount
        self.chapterCount = chapterCount
        self.totalChapters = totalChapters
        self.language = language
        self.kudos = kudos
        self.hits = hits
        self.isComplete = isComplete
        self.updatedAt = updatedAt
    }
}

public struct AO3WorkPayload: Sendable {
    public let summary: AO3WorkSummary
    public let chapters: [AO3ChapterPayload]
}

public struct AO3ChapterPayload: Sendable {
    public let index: Int
    public let title: String
    public let bodyHTML: String
}

public enum AO3AutocompleteField: String, Sendable {
    case relationship, character, freeform, fandom
}

public enum WorkExportFormat: String, CaseIterable, Sendable, Identifiable {
    case azw3, epub, mobi, pdf, html

    public var id: String { rawValue }
    public var ext: String { rawValue }

    public var displayName: String {
        switch self {
        case .azw3: "AZW3"
        case .epub: "EPUB"
        case .mobi: "MOBI"
        case .pdf:  "PDF"
        case .html: "HTML"
        }
    }

    public var icon: String {
        switch self {
        case .azw3: "books.vertical"
        case .epub: "book"
        case .mobi: "book.closed"
        case .pdf:  "doc.richtext"
        case .html: "globe"
        }
    }
}

public enum AO3Error: Error, Sendable, Equatable {
    case loginFailed(reason: String)
    case rateLimited
    case unauthorized
    case parseFailed(reason: String)
    case http(status: Int)
    case network(underlying: String)
}

public actor AO3Client: AO3ClientProtocol {
    private let baseURL = URL(string: "https://archiveofourown.org")!
    private let session: URLSession
    private let throttle = ThrottleActor(minimumInterval: 1.0)
    private let logger = Logger(subsystem: "io.github.yennster.fanficly", category: "AO3Client")
    private var cachedUsername: String?

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.httpAdditionalHeaders = [
                "User-Agent": Self.userAgent,
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Language": "en-US,en;q=0.9",
            ]
            cfg.httpCookieAcceptPolicy = .always
            cfg.httpShouldSetCookies = true
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            // Don't let a stalled request hang forever (default resource
            // timeout is ~7 days) — surface an error instead.
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: cfg)
        }
    }

    public static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "Fanficly/\(version) (+github.com/yennster/fanficly)"
    }

    public func login(username: String, password: String) async throws {
        await throttle.wait()

        let loginURL = try AO3Endpoints.login(base: baseURL)
        let (formData, _) = try await performRequest(URLRequest(url: loginURL))
        guard let formHTML = String(data: formData, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Login page not UTF-8")
        }
        guard let token = try LoginParser.authenticityToken(html: formHTML) else {
            throw AO3Error.parseFailed(reason: "authenticity_token not found")
        }

        await throttle.wait()
        var post = URLRequest(url: loginURL)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        post.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        post.setValue(loginURL.absoluteString, forHTTPHeaderField: "Referer")
        let body = encodeForm([
            "utf8": "\u{2713}",
            "authenticity_token": token,
            "user[login]": username,
            "user[password]": password,
            "user[remember_me]": "1",
            "commit": "Log in",
        ])
        post.httpBody = body.data(using: .utf8)

        let (loginRespData, _) = try await performRequest(post)
        let respHTML = String(data: loginRespData, encoding: .utf8) ?? ""

        // Success: the response shows the logged-in user navigation.
        if let name = try LoginParser.currentUsername(html: respHTML) {
            cachedUsername = name
            return
        }
        // Explicit AO3 error flash.
        if let err = try LoginParser.detectLoginFailure(html: respHTML) {
            throw AO3Error.loginFailed(reason: err)
        }
        // Still on the login form → credentials rejected.
        if try LoginParser.hasLoginForm(html: respHTML) {
            throw AO3Error.loginFailed(reason: "Incorrect username or password.")
        }
        // Unexpected response — assume the session cookie was set anyway.
        if let cookies = HTTPCookieStorage.shared.cookies(for: baseURL),
           cookies.contains(where: { $0.name.contains("user_credentials") || $0.name.contains("remember_user_token") }) {
            cachedUsername = username
            return
        }
        throw AO3Error.loginFailed(reason: "Couldn't confirm login. Please try again.")
    }

    public func logout() async {
        if let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) {
            for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        cachedUsername = nil
    }

    public func currentUsername() async -> String? {
        cachedUsername
    }

    public func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults {
        await throttle.wait()
        let url = try AO3Endpoints.search(filters: filters, page: page, base: baseURL)
        logger.debug("GET \(url.absoluteString, privacy: .public)")
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Search response not UTF-8")
        }
        return try SearchResultsParser.parse(html: html)
    }

    public func fetchAuthorWorks(username: String, page: Int) async throws -> AO3SearchResults {
        await throttle.wait()
        let url = try AO3Endpoints.authorWorks(name: username, page: page, base: baseURL)
        logger.debug("GET \(url.absoluteString, privacy: .public)")
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Author works response not UTF-8")
        }
        // An author's works page lists works with the same `li.work.blurb`
        // markup as search, so the search parser handles it unchanged.
        return try SearchResultsParser.parse(html: html)
    }

    public func fetchWork(id: Int) async throws -> AO3WorkPayload {
        await throttle.wait()
        let url = try AO3Endpoints.work(id: id, base: baseURL)
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Work response not UTF-8")
        }
        return try WorkPageParser.parse(html: html, workId: id)
    }

    public func fetchWorkMetadata(id: Int) async throws -> AO3WorkMetadata {
        await throttle.wait()
        let url = try AO3Endpoints.work(id: id, base: baseURL)
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Work response not UTF-8")
        }
        return try WorkMetadataParser.parse(html: html, workId: id)
    }

    public func fetchSubscriptions(username: String) async throws -> [AO3Subscription] {
        await throttle.wait()
        let url = try AO3Endpoints.userSubscriptions(name: username, base: baseURL)
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Subscriptions response not UTF-8")
        }
        return try SubscriptionsParser.parse(html: html)
    }

    public func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom] {
        await throttle.wait()
        let url = try AO3Endpoints.mediaFandoms(categoryName: categoryName, base: baseURL)
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Media category response not UTF-8")
        }
        return try MediaCategoryParser.parse(html: html)
    }

    public func autocomplete(field: AO3AutocompleteField, term: String) async throws -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        await throttle.wait()
        let url = try AO3Endpoints.autocomplete(field: field.rawValue, term: trimmed, base: baseURL)
        var request = URLRequest(url: url)
        // The shared session sends `Accept: text/html`, but AO3's autocomplete
        // only serves JSON — Rails content-negotiation 404s an HTML request.
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, _) = try await performRequest(request)
        struct Item: Decodable { let id: String?; let name: String? }
        let items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        return items.compactMap { $0.name ?? $0.id }
    }

    public func downloadEPUB(workId: Int) async throws -> URL {
        await throttle.wait()
        let url = try AO3Endpoints.epub(workId: workId, base: baseURL)
        let (data, _) = try await performRequest(URLRequest(url: url))
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(workId).epub")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    public func exportWork(workId: Int, format: WorkExportFormat, filename: String) async throws -> URL {
        await throttle.wait()
        let url = try AO3Endpoints.download(workId: workId, format: format, base: baseURL)
        let (data, _) = try await performRequest(URLRequest(url: url))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = Self.sanitizeFilename(filename.isEmpty ? "work-\(workId)" : filename)
        let fileURL = dir.appendingPathComponent("\(safe).\(format.ext)")
        try? FileManager.default.removeItem(at: fileURL)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    public func subscribeToWork(workId: Int) async throws {
        await throttle.wait()
        let pageURL = try AO3Endpoints.work(id: workId, base: baseURL)
        let (pageData, _) = try await performRequest(URLRequest(url: pageURL))
        guard let pageHTML = String(data: pageData, encoding: .utf8),
              let token = try LoginParser.authenticityToken(html: pageHTML) else {
            throw AO3Error.parseFailed(reason: "authenticity_token not found on work page")
        }

        await throttle.wait()
        let subsURL = try AO3Endpoints.workSubscriptions(id: workId, base: baseURL)
        var request = URLRequest(url: subsURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
        let body = encodeForm([
            "authenticity_token": token,
            "subscription[subscribable_id]": String(workId),
            "subscription[subscribable_type]": "Work",
        ])
        request.httpBody = body.data(using: .utf8)

        let (_, response) = try await performRequest(request)
        if response.statusCode >= 400 && response.statusCode != 422 {
            throw AO3Error.http(status: response.statusCode)
        }
    }


    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AO3Error.network(underlying: "Non-HTTP response")
            }
            switch http.statusCode {
            case 200..<300, 302: return (data, http)
            case 401, 403:        throw AO3Error.unauthorized
            case 429:             throw AO3Error.rateLimited
            default:              throw AO3Error.http(status: http.statusCode)
            }
        } catch let error as AO3Error {
            throw error
        } catch {
            throw AO3Error.network(underlying: error.localizedDescription)
        }
    }

    private func encodeForm(_ pairs: [String: String]) -> String {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=")
        return pairs.map { k, v in
            let key = k.addingPercentEncoding(withAllowedCharacters: cs) ?? k
            let val = v.addingPercentEncoding(withAllowedCharacters: cs) ?? v
            return "\(key)=\(val)"
        }.joined(separator: "&")
    }
}

public final class MockAO3Client: AO3ClientProtocol, @unchecked Sendable {
    public init() {}
    public func login(username: String, password: String) async throws {}
    public func logout() async {}
    public func currentUsername() async -> String? { nil }
    public func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    public func fetchAuthorWorks(username: String, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    public func fetchWork(id: Int) async throws -> AO3WorkPayload {
        AO3WorkPayload(
            summary: AO3WorkSummary(
                id: id, title: "Sample Work", author: "Anon",
                summary: "", rating: "Not Rated", warnings: [],
                categories: [], fandoms: [], characters: [],
                relationships: [], freeforms: [], wordCount: 0,
                chapterCount: 1, totalChapters: 1, language: "en",
                kudos: 0, hits: 0, isComplete: true, updatedAt: nil
            ),
            chapters: []
        )
    }
    public func fetchWorkMetadata(id: Int) async throws -> AO3WorkMetadata {
        AO3WorkMetadata(id: id, chapterCount: 1, totalChapters: 1, updatedAt: nil)
    }
    public func fetchSubscriptions(username: String) async throws -> [AO3Subscription] { [] }
    public func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom] { [] }
    public func autocomplete(field: AO3AutocompleteField, term: String) async throws -> [String] { [term] }
    public func downloadEPUB(workId: Int) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(workId).epub")
    }
    public func exportWork(workId: Int, format: WorkExportFormat, filename: String) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(filename).\(format.ext)")
    }
    public func subscribeToWork(workId: Int) async throws {}
}

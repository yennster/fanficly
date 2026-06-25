import Foundation
import os

public protocol AO3ClientProtocol: Sendable {
    func login(username: String, password: String) async throws
    func logout() async
    func currentUsername() async -> String?
    func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults
    func fetchAuthorWorks(username: String, page: Int) async throws -> AO3SearchResults
    func fetchBookmarks(username: String, page: Int) async throws -> AO3SearchResults
    func fetchWork(id: Int) async throws -> AO3WorkPayload
    func fetchWorkMetadata(id: Int) async throws -> AO3WorkMetadata
    func fetchSubscriptions(username: String) async throws -> [AO3Subscription]
    /// Comments for a specific chapter (AO3 threads comments per chapter). Pass
    /// `chapterId` = the chapter's AO3 id; nil fetches the work-level page (the
    /// first chapter's thread), used as a fallback when the id is unknown.
    func fetchComments(workId: Int, chapterId: Int?) async throws -> [AO3Comment]
    func postComment(workId: Int, chapterId: Int?, text: String) async throws
    func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom]
    func fetchPopularSnapshot() async throws -> PopularSnapshot
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

/// A live snapshot of popular fandoms, ships, and characters, derived from AO3
/// HTML (media-page fandom counts + works-filter facet counts). Codable so it
/// can be cached on-device and refreshed ~daily. Names are AO3-canonical so
/// tapping one resolves to a search.
public struct PopularSnapshot: Sendable, Codable, Hashable {
    public let fandoms: [String]
    public let ships: [String]
    public let characters: [String]
    public let fetchedAt: Date

    public init(fandoms: [String], ships: [String], characters: [String], fetchedAt: Date = .now) {
        self.fandoms = fandoms
        self.ships = ships
        self.characters = characters
        self.fetchedAt = fetchedAt
    }
}

public struct AO3Comment: Sendable, Identifiable, Hashable {
    public let id: String
    public let commenterName: String
    /// AO3 login for registered commenters; "" for guests.
    public let commenterUsername: String
    public let dateText: String
    public let bodyHTML: String
    /// Thread nesting: 0 = top-level, 1 = reply, etc. (drives indentation).
    public let depth: Int

    public init(id: String, commenterName: String, commenterUsername: String,
                dateText: String, bodyHTML: String, depth: Int) {
        self.id = id
        self.commenterName = commenterName
        self.commenterUsername = commenterUsername
        self.dateText = dateText
        self.bodyHTML = bodyHTML
        self.depth = depth
    }
}

public struct AO3ChapterPayload: Sendable {
    public let index: Int
    public let title: String
    public let bodyHTML: String
    /// AO3's chapter database id, parsed from the chapter's
    /// `/works/<id>/chapters/<chapterId>` link. Drives per-chapter comments;
    /// nil when the markup doesn't expose it (e.g. some single-chapter works),
    /// in which case callers fall back to work-level comments.
    public let aoId: Int?

    public init(index: Int, title: String, bodyHTML: String, aoId: Int? = nil) {
        self.index = index
        self.title = title
        self.bodyHTML = bodyHTML
        self.aoId = aoId
    }
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
        
        // Listen for cookie storage changes to automatically save them to the Keychain
        NotificationCenter.default.addObserver(
            forName: .NSHTTPCookieManagerCookiesChanged,
            object: HTTPCookieStorage.shared,
            queue: nil
        ) { [weak self] _ in
            self?.saveCookiesToKeychain()
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

    public func fetchBookmarks(username: String, page: Int) async throws -> AO3SearchResults {
        await throttle.wait()
        let url = try AO3Endpoints.userBookmarks(name: username, page: page, base: baseURL)
        logger.debug("GET \(url.absoluteString, privacy: .public)")
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Bookmarks response not UTF-8")
        }
        // The bookmarks page wraps each work in `li.bookmark.blurb` (vs.
        // `li.work.blurb` on search) but the inner blurb markup is identical.
        return try SearchResultsParser.parse(html: html, blurbSelector: "li.bookmark.blurb")
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

    public func fetchComments(workId: Int, chapterId: Int?) async throws -> [AO3Comment] {
        await throttle.wait()
        let url = try commentsPageURL(workId: workId, chapterId: chapterId)
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Comments response not UTF-8")
        }
        return try CommentsParser.parse(html: html)
    }

    /// The page whose `?show_comments=true` thread we read/post against: a
    /// specific chapter when its id is known, else the work page.
    private func commentsPageURL(workId: Int, chapterId: Int?) throws -> URL {
        if let chapterId {
            return try AO3Endpoints.chapterComments(workId: workId, chapterId: chapterId, base: baseURL)
        }
        return try AO3Endpoints.workComments(id: workId, base: baseURL)
    }

    public func postComment(workId: Int, chapterId: Int?, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Load the chapter's (or work's) comment page and replay its actual
        // new-comment form: the form's hidden inputs carry the CSRF token and the
        // `comment[commentable_id]`/`[commentable_type]` that bind the comment to
        // exactly the chapter AO3 would — so we never hardcode the POST shape.
        await throttle.wait()
        let pageURL = try commentsPageURL(workId: workId, chapterId: chapterId)
        let (pageData, _) = try await performRequest(URLRequest(url: pageURL))
        guard let pageHTML = String(data: pageData, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Comment page not UTF-8")
        }
        guard let form = CommentsParser.newCommentForm(html: pageHTML, base: baseURL) else {
            throw AO3Error.parseFailed(reason: "comment form not found (login required?)")
        }

        await throttle.wait()
        var request = URLRequest(url: form.action)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if let token = form.fields["authenticity_token"] {
            request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
        }
        var fields = form.fields
        fields["comment[comment_content]"] = trimmed
        fields["commit"] = "Comment"
        request.httpBody = encodeForm(fields).data(using: .utf8)

        let (_, response) = try await performRequest(request)
        guard response.statusCode < 400 else {
            throw AO3Error.http(status: response.statusCode)
        }
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

    /// The works-filter facet sidebar for a tag (`/tags/<tag>/works`) — its
    /// top relationships/characters/freeforms with counts.
    private func fetchWorkFilters(tagName: String) async throws -> AO3WorkFilters {
        await throttle.wait()
        let url = try AO3Endpoints.tagWorks(tagName: tagName, base: baseURL)
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Tag works response not UTF-8")
        }
        return try WorkFiltersParser.parse(html: html)
    }

    /// Builds a live popular snapshot: fandoms ranked by AO3's media-page work
    /// counts, then ships/characters aggregated from the facet sidebars of the
    /// top few fandoms. Each list falls back to the curated `PopularTags` seed
    /// when AO3 yields nothing (offline / markup drift), so the tab is never
    /// empty. ~10–13 throttled requests — meant to run in the background and be
    /// cached for a day (see `PopularStore`).
    public func fetchPopularSnapshot() async throws -> PopularSnapshot {
        var fandomCounts: [String: Int] = [:]
        for category in FandomCatalog.all {
            guard let fandoms = try? await fetchFandomsInCategory(categoryName: category.ao3CanonicalName) else { continue }
            for fandom in fandoms where (fandom.workCount ?? 0) > 0 {
                fandomCounts[fandom.canonicalName] = max(fandomCounts[fandom.canonicalName] ?? 0, fandom.workCount ?? 0)
            }
        }
        let topFandoms = fandomCounts.sorted { $0.value > $1.value }.map(\.key)

        var shipCounts: [String: Int] = [:]
        var charCounts: [String: Int] = [:]
        // Aggregate ship/character facets from the top few fandoms — enough
        // fandoms to surface ~30 unique ships/characters for the Popular lists.
        for fandom in topFandoms.prefix(5) {
            guard let filters = try? await fetchWorkFilters(tagName: fandom) else { continue }
            for r in filters.relationships { shipCounts[r.name, default: 0] += max(r.count, 1) }
            for c in filters.characters { charCounts[c.name, default: 0] += max(c.count, 1) }
        }
        let topShips = shipCounts.sorted { $0.value > $1.value }.map(\.key)
        let topChars = charCounts.sorted { $0.value > $1.value }.map(\.key)

        return PopularSnapshot(
            fandoms: topFandoms.isEmpty ? PopularTags.fandoms : Array(topFandoms.prefix(30)),
            ships: topShips.isEmpty ? PopularTags.ships : Array(topShips.prefix(30)),
            characters: topChars.isEmpty ? PopularTags.characters : Array(topChars.prefix(30))
        )
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


    private var cookiesLoaded = false

    private func ensureCookiesLoaded() {
        guard !cookiesLoaded else { return }
        let cookies = CredentialStore.shared.loadCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        cookiesLoaded = true
    }

    private nonisolated func saveCookiesToKeychain() {
        let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) ?? []
        Task.detached(priority: .utility) {
            CredentialStore.shared.saveCookies(cookies)
        }
    }

    /// How many times a transient failure (timeout / dropped connection / a 429
    /// rate-limit) is retried before it surfaces to the caller.
    private static let maxRetries = 2

    private func performRequest(_ request: URLRequest, attempt: Int = 0) async throws -> (Data, HTTPURLResponse) {
        ensureCookiesLoaded()
        // Only auto-retry idempotent reads. Replaying a POST (login, comment,
        // subscribe) after a timeout could double-submit — e.g. a comment that
        // actually landed but whose response was lost — so those surface the
        // error to the caller instead.
        let canRetry = (request.httpMethod ?? "GET").uppercased() == "GET" && attempt < Self.maxRetries
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AO3Error.network(underlying: "Non-HTTP response")
            }
            switch http.statusCode {
            case 200..<300, 302: return (data, http)
            case 401, 403:        throw AO3Error.unauthorized
            case 429:
                // We've been rate-limited. Back off (longer each time) and try
                // again through the throttle before giving up, so a brief AO3
                // clamp-down doesn't surface as a hard failure.
                if canRetry {
                    try? await Task.sleep(nanoseconds: Self.backoffNanos(attempt))
                    await throttle.wait()
                    return try await performRequest(request, attempt: attempt + 1)
                }
                throw AO3Error.rateLimited
            default:              throw AO3Error.http(status: http.statusCode)
            }
        } catch let error as AO3Error {
            throw error
        } catch let urlError as URLError where canRetry && Self.isTransient(urlError) {
            // Timeouts and dropped connections are often transient (a slow AO3
            // response, a network blip) — retry with backoff instead of failing
            // the whole load.
            try? await Task.sleep(nanoseconds: Self.backoffNanos(attempt))
            await throttle.wait()
            return try await performRequest(request, attempt: attempt + 1)
        } catch {
            throw AO3Error.network(underlying: error.localizedDescription)
        }
    }

    /// Exponential backoff before a retry: ~0.5s, then ~1s.
    private static func backoffNanos(_ attempt: Int) -> UInt64 {
        let seconds = 0.5 * pow(2.0, Double(attempt))
        return UInt64(seconds * 1_000_000_000)
    }

    /// URLSession errors worth retrying — network hiccups rather than
    /// programmer/permanent errors (a bad URL or cancellation isn't retried).
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable, .secureConnectionFailed:
            return true
        default:
            return false
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
    public func fetchBookmarks(username: String, page: Int) async throws -> AO3SearchResults {
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
    public func fetchComments(workId: Int, chapterId: Int?) async throws -> [AO3Comment] { [] }
    public func postComment(workId: Int, chapterId: Int?, text: String) async throws {}
    public func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom] { [] }
    public func fetchPopularSnapshot() async throws -> PopularSnapshot {
        PopularSnapshot(fandoms: PopularTags.fandoms, ships: PopularTags.ships, characters: PopularTags.characters)
    }
    public func autocomplete(field: AO3AutocompleteField, term: String) async throws -> [String] { [term] }
    public func downloadEPUB(workId: Int) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(workId).epub")
    }
    public func exportWork(workId: Int, format: WorkExportFormat, filename: String) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(filename).\(format.ext)")
    }
    public func subscribeToWork(workId: Int) async throws {}
}

import Foundation
import os

public protocol AO3ClientProtocol: Sendable {
    /// Signs in with an AO3 username or email address and returns the account's
    /// AO3 login name, which is what `/users/<name>` pages need (#144).
    @discardableResult
    func login(username: String, password: String) async throws -> String
    func logout() async
    /// The signed-in AO3 login name, read from AO3's page header when this
    /// launch hasn't signed in yet; nil when signed out or unreachable.
    func currentUsername() async -> String?
    func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults
    func fetchAuthorWorks(username: String, page: Int) async throws -> AO3SearchResults
    func fetchBookmarks(username: String, page: Int) async throws -> AO3SearchResults
    /// One page of the user's AO3 Marked for Later list. Login required.
    func fetchMarkedForLater(username: String, page: Int) async throws -> AO3SearchResults
    /// One page of the user's AO3 reading history, most recently visited
    /// first. Login required, and the reader must have History turned on.
    func fetchReadingHistory(username: String, page: Int) async throws -> AO3SearchResults
    func fetchWork(id: Int) async throws -> AO3WorkPayload
    func fetchWorkMetadata(id: Int) async throws -> AO3WorkMetadata
    /// One page of a series (`/series/<id>`): its title, creators and works in
    /// series order. AO3 lists 20 works a page.
    func fetchSeries(id: Int, page: Int) async throws -> AO3Series
    func fetchSubscriptions(username: String) async throws -> [AO3Subscription]
    /// Comments for a specific chapter (AO3 threads comments per chapter). Pass
    /// `chapterId` = the chapter's AO3 id; nil fetches the work-level page (the
    /// first chapter's thread), used as a fallback when the id is unknown.
    func fetchComments(workId: Int, chapterId: Int?, page: Int) async throws -> AO3CommentsPage
    func postComment(workId: Int, chapterId: Int?, text: String) async throws
    func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom]
    func fetchPopularSnapshot() async throws -> PopularSnapshot
    func autocomplete(field: AO3AutocompleteField, term: String) async throws -> [String]
    func downloadEPUB(workId: Int) async throws -> URL
    func exportWork(workId: Int, format: WorkExportFormat, filename: String) async throws -> URL
    func subscribeToWork(workId: Int) async throws
    /// Leaves kudos on a work as the logged-in user: one POST, never retried.
    /// Throws `.unauthorized` when the session isn't logged in, so a stale
    /// cookie can't quietly leave a guest kudo instead.
    func leaveKudos(workId: Int) async throws -> KudosOutcome
    /// The signed-in user's bookmark form for a work, prefilled when they
    /// already bookmarked it. Throws `.unauthorized` when signed out.
    func fetchBookmarkForm(workId: Int) async throws -> AO3BookmarkForm
    /// Creates or updates the bookmark by posting `form` back to AO3.
    func saveBookmark(_ form: AO3BookmarkForm) async throws
}

/// What AO3 said to a kudos POST. AO3 allows one kudo per user per work and
/// answers a second one with "You have already left kudos here. :)", which
/// is still a kudo on the work, so the app remembers it the same way.
public enum KudosOutcome: Sendable, Equatable {
    case left
    case alreadyLeft
}

public struct AO3SearchResults: Sendable, Equatable {
    public let works: [AO3WorkSummary]
    public let totalPages: Int
    public let currentPage: Int
    /// The search page's "126,555 Found" total; nil on listings without one.
    public let totalFound: Int?
    /// AO3 rendered the page for a signed-out reader (the header's login form,
    /// no greeting). A guest listing leaves out restricted (archive-locked)
    /// works, so a signed-in reader getting one has an expired session; see
    /// `AuthState.noteListing(_:)`.
    public let servedAsGuest: Bool

    public init(works: [AO3WorkSummary], totalPages: Int, currentPage: Int, totalFound: Int? = nil,
                servedAsGuest: Bool = false) {
        self.works = works
        self.totalPages = totalPages
        self.currentPage = currentPage
        self.totalFound = totalFound
        self.servedAsGuest = servedAsGuest
    }
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
    /// The series this work belongs to ("Part 2 of …"), parsed from the work
    /// page's `dd.series`. Empty for search blurbs and saved works.
    public let series: [AO3SeriesPart]

    // Explicit init (rather than the synthesized memberwise one) so adding
    // `authorUsername` or `series` with a default keeps every existing call site compiling.
    public init(
        id: Int, title: String, author: String, authorUsername: String = "",
        summary: String, rating: String, warnings: [String], categories: [String],
        fandoms: [String], characters: [String], relationships: [String], freeforms: [String],
        wordCount: Int, chapterCount: Int, totalChapters: Int?, language: String,
        kudos: Int, hits: Int, isComplete: Bool, updatedAt: Date?,
        series: [AO3SeriesPart] = []
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
        self.series = series
    }
}

/// A work's place in one series, from the work page's
/// `<span class="series">← Previous Work · Part 2 of <a href="/series/9">…</a> · Next Work →</span>`.
/// AO3 counts only the works visible to the viewer, so `position` and the
/// neighbours can differ logged in and out.
public struct AO3SeriesPart: Sendable, Hashable {
    public let seriesId: Int
    public let title: String
    public let position: Int
    public let previousWorkId: Int?
    public let nextWorkId: Int?

    public init(seriesId: Int, title: String, position: Int,
                previousWorkId: Int? = nil, nextWorkId: Int? = nil) {
        self.seriesId = seriesId
        self.title = title
        self.position = position
        self.previousWorkId = previousWorkId
        self.nextWorkId = nextWorkId
    }
}

/// One page of a series page (`/series/<id>`).
public struct AO3Series: Sendable, Equatable {
    public let id: Int
    public let title: String
    /// Byline text, comma-joined for co-created series.
    public let creator: String
    /// The first creator's AO3 login, "" for anonymous/orphaned series.
    public let creatorUsername: String
    public let descriptionHTML: String
    /// AO3's "Works:" stat (visible works across every page); nil if missing.
    public let workCount: Int?
    public let isComplete: Bool
    /// This page's works in series order. Unrevealed ("Mystery Work") entries,
    /// which have no link to open, are left out.
    public let works: [AO3WorkSummary]
    public let currentPage: Int
    public let totalPages: Int

    public init(id: Int, title: String, creator: String, creatorUsername: String = "",
                descriptionHTML: String = "", workCount: Int? = nil, isComplete: Bool = false,
                works: [AO3WorkSummary], currentPage: Int = 1, totalPages: Int = 1) {
        self.id = id
        self.title = title
        self.creator = creator
        self.creatorUsername = creatorUsername
        self.descriptionHTML = descriptionHTML
        self.workCount = workCount
        self.isComplete = isComplete
        self.works = works
        self.currentPage = currentPage
        self.totalPages = totalPages
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

/// One page of a chapter's (or one-shot's) comment threads. AO3 paginates
/// comments by top-level thread; `totalPages` comes from the thread's
/// will_paginate list and is 1 when there is none.
public struct AO3CommentsPage: Sendable, Equatable {
    public let comments: [AO3Comment]
    public let currentPage: Int
    public let totalPages: Int

    public var hasMore: Bool { currentPage < totalPages }

    public init(comments: [AO3Comment], currentPage: Int = 1, totalPages: Int = 1) {
        self.comments = comments
        self.currentPage = currentPage
        self.totalPages = totalPages
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

/// The bookmark form AO3 renders on a work page for the signed-in user
/// (`#bookmark_form_placement`). Saving replays it: `action` is
/// `/works/<id>/bookmarks` for a new bookmark or `/bookmarks/<id>` (with a
/// hidden `_method=put`) for an existing one, and `hiddenFields` carries the
/// CSRF token and the pseud, so neither is hardcoded.
public struct AO3BookmarkForm: Sendable, Equatable {
    public let action: URL
    public let hiddenFields: [String: String]
    /// True when the work is already bookmarked, so saving updates it.
    public let isExisting: Bool
    /// Notes may contain AO3's allowed HTML; they're sent back as typed.
    public var notes: String
    /// The bookmarker's own tags, comma separated, as AO3's field takes them.
    public var tags: String
    /// Collections the bookmark is in, kept as-is (not edited in the app);
    /// nil when the form had no such field, so nothing is sent for it.
    public var collections: String?
    public var isPrivate: Bool
    public var isRec: Bool

    public init(action: URL, hiddenFields: [String: String], isExisting: Bool,
                notes: String = "", tags: String = "", collections: String? = nil,
                isPrivate: Bool = false, isRec: Bool = false) {
        self.action = action
        self.hiddenFields = hiddenFields
        self.isExisting = isExisting
        self.notes = notes
        self.tags = tags
        self.collections = collections
        self.isPrivate = isPrivate
        self.isRec = isRec
    }

    /// The urlencoded fields to POST: the hidden inputs plus the edited
    /// values, with the checkboxes sent as Rails' `0`/`1`.
    public var postFields: [String: String] {
        var fields = hiddenFields
        fields["bookmark[bookmarker_notes]"] = notes
        fields["bookmark[tag_string]"] = tags
        if let collections { fields["bookmark[collection_names]"] = collections }
        fields["bookmark[private]"] = isPrivate ? "1" : "0"
        fields["bookmark[rec]"] = isRec ? "1" : "0"
        fields["commit"] = isExisting ? "Update" : "Create"
        return fields
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
    /// Every canonical tag type at once — one request per search suggestion.
    case tag
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
    /// AO3 refused a kudo, with its own reason ("You can't leave kudos on your
    /// own work.", a block, a suspended account).
    case kudosRejected(message: String)
    /// AO3 didn't post a comment, with its own reason when it gave one.
    case commentRejected(message: String)
    /// AO3 didn't confirm a subscription, with its own reason when it gave one.
    case subscribeRejected(message: String)
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
            // Room for search, which sets its own longer request timeout.
            cfg.timeoutIntervalForResource = 90
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
        // Not the "(+url)" form web crawlers use; the Windows app sends "(Windows; …)".
        #if targetEnvironment(macCatalyst)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return "Fanficly/\(version) (\(platform); https://github.com/yennster/fanficly)"
    }

    @discardableResult
    public func login(username: String, password: String) async throws -> String {
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

        // Success: the response shows the logged-in user navigation (and no
        // login form, whose header links aren't a name).
        if try !LoginParser.hasLoginForm(html: respHTML), let name = try LoginParser.currentUsername(html: respHTML) {
            cachedUsername = name
            return name
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
            // The typed text may be an email address, which no /users/ page
            // takes, so ask AO3 for the login name.
            if let name = await fetchLoggedInName() {
                cachedUsername = name
                return name
            }
            if !username.contains("@") {
                cachedUsername = username
                return username
            }
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
        if let cachedUsername { return cachedUsername }
        cachedUsername = await fetchLoggedInName()
        return cachedUsername
    }

    /// The login name in the header of AO3's home page; nil for a guest page
    /// or a failed request.
    private func fetchLoggedInName() async -> String? {
        await throttle.wait()
        guard let response = try? await performRequest(URLRequest(url: baseURL)),
              let html = String(data: response.0, encoding: .utf8),
              (try? LoginParser.hasLoginForm(html: html)) == false else { return nil }
        return try? LoginParser.currentUsername(html: html)
    }

    public func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults {
        await throttle.wait()
        let url = try AO3Endpoints.search(filters: filters, page: page, base: baseURL)
        logger.debug("GET \(url.absoluteString, privacy: .public)")
        // AO3's search pages routinely take 20–30s to start responding (the
        // server is busy rendering, not stalled), so the default 30s idle
        // timeout failed searches on slow days, then retried them twice for
        // a minute-plus wait. Give search 60s and a single retry.
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, _) = try await performRequest(request, maxRetries: 1)
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

    public func fetchMarkedForLater(username: String, page: Int) async throws -> AO3SearchResults {
        await throttle.wait()
        let url = try AO3Endpoints.userMarkedForLater(name: username, page: page, base: baseURL)
        logger.debug("GET \(url.absoluteString, privacy: .public)")
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Marked for Later response not UTF-8")
        }
        return try SearchResultsParser.parseReadings(html: html)
    }

    public func fetchReadingHistory(username: String, page: Int) async throws -> AO3SearchResults {
        await throttle.wait()
        let url = try AO3Endpoints.userReadingHistory(name: username, page: page, base: baseURL)
        logger.debug("GET \(url.absoluteString, privacy: .public)")
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "History response not UTF-8")
        }
        return try SearchResultsParser.parseReadings(html: html)
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

    public func fetchSeries(id: Int, page: Int) async throws -> AO3Series {
        await throttle.wait()
        let url = try AO3Endpoints.series(id: id, page: page, base: baseURL)
        logger.debug("GET \(url.absoluteString, privacy: .public)")
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Series response not UTF-8")
        }
        return try SeriesParser.parse(html: html, seriesId: id)
    }

    public func fetchSubscriptions(username: String) async throws -> [AO3Subscription] {
        // AO3 paginates the subscriptions index at 20 per page — walk every
        // page (each fetch goes through the 1 req/s throttle) or anything past
        // the first 20 is invisible and its records get treated as stale. Any
        // page failing throws the whole call, so a partial list can never
        // reach the caller's delete pass. The page ceiling only guards against
        // a pagination-parse glitch turning one sync into an unbounded crawl.
        var all: [AO3Subscription] = []
        var seen = Set<String>()
        var page = 1
        var totalPages = 1
        let maxPages = 50
        while page <= min(totalPages, maxPages) {
            await throttle.wait()
            let url = try AO3Endpoints.userSubscriptions(name: username, page: page, base: baseURL)
            logger.debug("GET \(url.absoluteString, privacy: .public)")
            let (data, _) = try await performRequest(URLRequest(url: url))
            guard let html = String(data: data, encoding: .utf8) else {
                throw AO3Error.parseFailed(reason: "Subscriptions response not UTF-8")
            }
            let parsed = try SubscriptionsParser.parsePage(html: html)
            for sub in parsed.subscriptions where seen.insert(sub.key).inserted {
                all.append(sub)
            }
            totalPages = parsed.totalPages
            page += 1
        }
        return all
    }

    public func fetchComments(workId: Int, chapterId: Int?, page: Int) async throws -> AO3CommentsPage {
        await throttle.wait()
        let url = try commentsPageURL(workId: workId, chapterId: chapterId, page: page)
        let (data, _) = try await performRequest(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Comments response not UTF-8")
        }
        return try CommentsParser.parsePage(html: html)
    }

    /// The page whose `?show_comments=true` thread we read/post against: a
    /// specific chapter when its id is known, else the work page.
    private func commentsPageURL(workId: Int, chapterId: Int?, page: Int = 1) throws -> URL {
        if let chapterId {
            return try AO3Endpoints.chapterComments(workId: workId, chapterId: chapterId, page: page, base: baseURL)
        }
        return try AO3Endpoints.workComments(id: workId, page: page, base: baseURL)
    }

    public func postComment(workId: Int, chapterId: Int?, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AO3Error.commentRejected(message: "The comment is empty.") }

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
            if !KudosParser.isSignedIn(html: pageHTML) { throw AO3Error.unauthorized }
            throw AO3Error.parseFailed(reason: "comment form not found")
        }
        // AO3 shows its guest form (name and email) once the session has
        // ended. Posting it without them is refused, and posting as a guest
        // isn't what a signed-in reader meant.
        guard !form.isGuest else { throw AO3Error.unauthorized }

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

        // AO3 answers a refused comment with a 200 page (or a redirect that
        // URLSession follows), never an error status, so judge by the page.
        let (data, response) = try await performRequest(request)
        let html = String(data: data, encoding: .utf8) ?? ""
        switch CommentsParser.postOutcome(html: html, finalURL: response.url, formAction: form.action) {
        case .posted: return
        case .signedOut: throw AO3Error.unauthorized
        case .rejected(let message): throw AO3Error.commentRejected(message: message)
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
        let (data, response) = try await performRequest(URLRequest(url: url))
        try Self.ensureDownloadedFile(data, finalURL: response.url, format: .epub)
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
        let (data, response) = try await performRequest(URLRequest(url: url))
        try Self.ensureDownloadedFile(data, finalURL: response.url, format: format)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = Self.sanitizeFilename(filename.isEmpty ? "work-\(workId)" : filename)
        let fileURL = dir.appendingPathComponent("\(safe).\(format.ext)")
        try? FileManager.default.removeItem(at: fileURL)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// A download is really the file, not a page. A restricted work fetched
    /// signed out (or with an expired cookie) redirects to the login page,
    /// which URLSession follows to a 200, and AO3 or Cloudflare can answer
    /// with an error page. Saved, either would show as Downloaded (the
    /// Library only checks the EPUB file exists) or reach the share sheet as
    /// a `.pdf`. So each format has to start like that format, and nothing is
    /// written unless it does.
    static func ensureDownloadedFile(_ data: Data, finalURL: URL?, format: WorkExportFormat) throws {
        if finalURL?.path.hasPrefix("/users/login") == true { throw AO3Error.unauthorized }
        let matches: Bool
        switch format {
        case .epub, .azw3, .mobi: matches = isEbook(data)
        case .pdf: matches = isPDF(data)
        case .html: matches = try AO3PageCheck.isWorkDownload(html: String(decoding: data, as: UTF8.self))
        }
        if matches { return }
        if format != .html, AO3PageCheck.isLoginPage(html: String(decoding: data, as: UTF8.self)) {
            throw AO3Error.unauthorized
        }
        throw AO3Error.parseFailed(reason: "AO3 didn't send the \(format.displayName) file")
    }

    /// AO3's EPUB is a zip; its AZW3 and MOBI are Mobipocket files.
    static func isEbook(_ data: Data) -> Bool {
        isZip(data) || isMobipocket(data)
    }

    private static func isZip(_ data: Data) -> Bool {
        data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    /// A Palm database whose type and creator, at byte 60, are "BOOKMOBI".
    private static func isMobipocket(_ data: Data) -> Bool {
        data.count >= 68 && data.dropFirst(60).prefix(8).elementsEqual("BOOKMOBI".utf8)
    }

    /// PDF readers accept the header anywhere in the first 1024 bytes.
    private static func isPDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    public func subscribeToWork(workId: Int) async throws {
        // The first page is enough: it shows whether the session is signed in
        // and carries the work's subscribe form. No view_full_work.
        await throttle.wait()
        let pageURL = try AO3Endpoints.workFirstPage(id: workId, base: baseURL)
        let (pageData, pageResponse) = try await performRequest(URLRequest(url: pageURL))
        if pageResponse.url?.path.hasPrefix("/users/login") == true { throw AO3Error.unauthorized }
        guard let pageHTML = String(data: pageData, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Work page not UTF-8")
        }
        // A guest's POST would only bounce to the login page, so don't send one.
        guard KudosParser.isSignedIn(html: pageHTML) else { throw AO3Error.unauthorized }
        guard let form = SubscribeParser.form(html: pageHTML, base: baseURL) else {
            throw AO3Error.subscribeRejected(message: "AO3 doesn't offer a Subscribe button on this work.")
        }
        // Already subscribed (on the website, say): AO3 has no uniqueness
        // check, so posting again would add a second subscription.
        if form.isSubscribed { return }
        // The page-wide token, as kudos and comments use.
        guard let token = try? LoginParser.authenticityToken(html: pageHTML) else {
            throw AO3Error.parseFailed(reason: "authenticity_token not found on work page")
        }

        // The form's own action, `/users/<login>/subscriptions`: AO3 has no
        // subscriptions route under `/works`. One POST, never retried
        // (`performRequest` only retries GETs).
        await throttle.wait()
        var request = URLRequest(url: form.action)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
        var fields = form.fields
        fields["authenticity_token"] = token
        fields["subscription[subscribable_id]"] = fields["subscription[subscribable_id]"] ?? String(workId)
        fields["subscription[subscribable_type]"] = fields["subscription[subscribable_type]"] ?? "Work"
        request.httpBody = encodeForm(fields).data(using: .utf8)

        let (data, response) = try await performRequest(request)
        try SubscribeParser.checkOutcome(html: String(data: data, encoding: .utf8) ?? "", finalURL: response.url)
    }

    public func leaveKudos(workId: Int) async throws -> KudosOutcome {
        // Read the work page first: it carries the kudos form (absent on your
        // own work or one whose creator blocked you) and shows whether the
        // session is still logged in. AO3 takes guest kudos too, so posting
        // with an expired cookie would silently leave one as a guest.
        await throttle.wait()
        let pageURL = try AO3Endpoints.workFirstPage(id: workId, base: baseURL)
        let (pageData, _) = try await performRequest(URLRequest(url: pageURL))
        guard let pageHTML = String(data: pageData, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Work page not UTF-8")
        }
        guard KudosParser.isSignedIn(html: pageHTML) else {
            throw AO3Error.unauthorized
        }
        guard var fields = KudosParser.formFields(html: pageHTML) else {
            throw AO3Error.kudosRejected(message: "AO3 doesn't offer kudos on this work. It may be your own, or its creator may have blocked you.")
        }
        // The page-wide token (`<meta name="csrf-token">`), as comments and
        // subscribe use. AO3 has Rails' per-form tokens on, so the form's own
        // token only validates for a POST to `/kudos`, not `/kudos.js`; AO3's
        // script gets through because it also sends the meta token.
        guard let token = try? LoginParser.authenticityToken(html: pageHTML) else {
            throw AO3Error.parseFailed(reason: "authenticity_token not found on work page")
        }
        fields["authenticity_token"] = token

        // Post the form the way AO3's own script does (`/kudos.js`): it
        // answers 201 on success and 422 with `{"error_message": …}` otherwise,
        // instead of a redirect whose flash we'd have to scrape.
        let kudosURL = try AO3Endpoints.kudos(base: baseURL)
        await throttle.wait()
        var request = URLRequest(url: kudosURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
        request.httpBody = encodeForm(fields).data(using: .utf8)

        let (data, response) = try await performRequest(request, passing: [422])
        switch response.statusCode {
        case 201:
            return .left
        case 422:
            // A refused token (the session ended between the two requests)
            // answers `{"errors": {"auth_error": …}}` instead.
            if KudosParser.isAuthError(json: data) { throw AO3Error.unauthorized }
            let message = KudosParser.errorMessage(json: data) ?? ""
            if KudosParser.isAlreadyLeft(message: message) { return .alreadyLeft }
            throw AO3Error.kudosRejected(message: message.isEmpty ? "AO3 didn't accept the kudos." : message)
        default:
            // Anything else (a maintenance page, a proxy) isn't AO3's kudos
            // answer, so it mustn't be remembered as a kudo.
            throw AO3Error.kudosRejected(message: "AO3 gave an unexpected answer (HTTP \(response.statusCode)), so the kudos may not have been left. Trying again is safe.")
        }
    }


    public func fetchBookmarkForm(workId: Int) async throws -> AO3BookmarkForm {
        await throttle.wait()
        let pageURL = try AO3Endpoints.workPage(id: workId, base: baseURL)
        let (data, _) = try await performRequest(URLRequest(url: pageURL))
        guard let html = String(data: data, encoding: .utf8) else {
            throw AO3Error.parseFailed(reason: "Work page not UTF-8")
        }
        guard let form = BookmarkFormParser.parse(html: html, base: baseURL) else {
            // AO3 only renders the form for a signed-in user; a page without it
            // that isn't signed out is an error page or changed markup.
            if (try? LoginParser.hasLoginForm(html: html)) == true || (try? LoginParser.currentUsername(html: html)) == nil {
                throw AO3Error.unauthorized
            }
            throw AO3Error.parseFailed(reason: "bookmark form not found on the work page")
        }
        return form
    }

    public func saveBookmark(_ form: AO3BookmarkForm) async throws {
        await throttle.wait()
        var request = URLRequest(url: form.action)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(form.action.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if let token = form.hiddenFields["authenticity_token"] {
            request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
        }
        request.httpBody = encodeForm(form.postFields).data(using: .utf8)

        // AO3 redirects a saved bookmark (new or updated) to `/bookmarks/<id>`.
        // A rejected one re-renders the form with an `#error` list, an expired
        // session lands on the login form, and a refused account or pseud is
        // redirected elsewhere with an error flash. URLSession follows the
        // redirect, so judge by the final page.
        let (data, response) = try await performRequest(request)
        let html = String(data: data, encoding: .utf8) ?? ""
        if (try? LoginParser.hasLoginForm(html: html)) == true {
            throw AO3Error.unauthorized
        }
        // A failed update re-renders on `/bookmarks/<id>` too, so form errors
        // come first; a flash on the saved bookmark's page (say, a collection
        // it couldn't join) doesn't undo the save.
        let errors = BookmarkFormParser.saveErrors(html: html)
        if !errors.isEmpty {
            throw AO3Error.parseFailed(reason: errors.joined(separator: " "))
        }
        guard BookmarkFormParser.isBookmarkPage(path: response.url?.path ?? "") else {
            let flash = BookmarkFormParser.flashErrors(html: html)
            throw AO3Error.parseFailed(reason: flash.isEmpty ? "AO3 didn't save the bookmark." : flash.joined(separator: " "))
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

    /// `passing` lists error statuses the caller reads itself (the kudos
    /// POST's 422 carries AO3's reason) instead of having them thrown.
    private func performRequest(_ request: URLRequest, attempt: Int = 0,
                                maxRetries: Int = AO3Client.maxRetries,
                                passing: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        ensureCookiesLoaded()
        // Only auto-retry idempotent reads. Replaying a POST (login, comment,
        // subscribe) after a timeout could double-submit — e.g. a comment that
        // actually landed but whose response was lost — so those surface the
        // error to the caller instead.
        let canRetry = (request.httpMethod ?? "GET").uppercased() == "GET" && attempt < maxRetries
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AO3Error.network(underlying: "Non-HTTP response")
            }
            if passing.contains(http.statusCode) { return (data, http) }
            switch http.statusCode {
            case 200..<300, 302: return (data, http)
            case 401, 403:        throw AO3Error.unauthorized
            case 429:
                // Rate-limited. Only retry when AO3's own Retry-After header
                // says the window is short enough to politely wait out;
                // otherwise fail fast. Blind backoff here would send more
                // requests into a window the server just declared closed —
                // real 429s from a client already throttled to 1 req/s mean a
                // clamp-down much longer than any in-request backoff.
                if canRetry,
                   let retryAfter = Self.retryAfterSeconds(http),
                   retryAfter <= Self.maxPoliteRetryAfter {
                    try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    await throttle.wait()
                    return try await performRequest(request, attempt: attempt + 1, maxRetries: maxRetries, passing: passing)
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
            return try await performRequest(request, attempt: attempt + 1, maxRetries: maxRetries, passing: passing)
        } catch {
            throw AO3Error.network(underlying: error.localizedDescription)
        }
    }

    /// Exponential backoff before a retry: ~0.5s, then ~1s.
    private static func backoffNanos(_ attempt: Int) -> UInt64 {
        let seconds = 0.5 * pow(2.0, Double(attempt))
        return UInt64(seconds * 1_000_000_000)
    }

    /// The longest Retry-After we're willing to wait out inside a request
    /// before surfacing `.rateLimited` to the caller.
    private static let maxPoliteRetryAfter: TimeInterval = 10

    /// Parses a 429's Retry-After header (delta-seconds form; the HTTP-date
    /// form parses as nil, which callers treat as "don't retry").
    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(raw), seconds >= 0 else { return nil }
        return seconds
    }

    /// URLSession errors worth retrying — network hiccups rather than
    /// programmer/permanent errors. A bad URL or cancellation isn't retried,
    /// and neither is being offline (`.notConnectedToInternet`): retrying
    /// with no connectivity just burns backoff time and throttle slots.
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost,
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
    public func login(username: String, password: String) async throws -> String { username }
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
    public func fetchMarkedForLater(username: String, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    public func fetchReadingHistory(username: String, page: Int) async throws -> AO3SearchResults {
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
    public func fetchSeries(id: Int, page: Int) async throws -> AO3Series {
        AO3Series(id: id, title: "Sample Series", creator: "Anon", works: [], currentPage: page)
    }
    public func fetchSubscriptions(username: String) async throws -> [AO3Subscription] { [] }
    public func fetchComments(workId: Int, chapterId: Int?, page: Int) async throws -> AO3CommentsPage {
        AO3CommentsPage(comments: [], currentPage: page)
    }
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
    public func leaveKudos(workId: Int) async throws -> KudosOutcome { .left }
    public func fetchBookmarkForm(workId: Int) async throws -> AO3BookmarkForm {
        AO3BookmarkForm(action: URL(string: "https://archiveofourown.org/works/\(workId)/bookmarks")!,
                        hiddenFields: [:], isExisting: false)
    }
    public func saveBookmark(_ form: AO3BookmarkForm) async throws {}
}

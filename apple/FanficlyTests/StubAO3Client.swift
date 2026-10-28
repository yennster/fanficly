import Foundation
@testable import Fanficly

/// Test double whose autocomplete responses are scripted, so resolution
/// logic (e.g. the relationship character-fallback) can be exercised.
final class StubAO3Client: AO3ClientProtocol, @unchecked Sendable {
    /// term (lowercased) → matches
    var autocompleteResponses: [String: [String]] = [:]
    /// terms (lowercased) whose lookup throws, to script network failures.
    var autocompleteFailingTerms: Set<String> = []
    private(set) var autocompleteCalls: [String] = []
    /// Scripted subscriptions-list response (SubscriptionPoller tests).
    var subscriptionsResponse: [AO3Subscription] = []
    /// False scripts a list that ran past `fetchSubscriptions`' page ceiling.
    var subscriptionsComplete = true
    private(set) var subscriptionsFetchCount = 0
    /// Scripted author works page (SubscriptionPoller tests); empty when nil.
    var authorWorksResponse: AO3SearchResults?
    /// Scripted work page for `fetchWorkMetadata`, run through the real
    /// parser (SubscriptionPoller tests); nil returns a one-chapter work.
    var workMetadataHTML: String?
    /// Scripted published days by work id for `fetchWorkMetadata`, and the
    /// ids it was asked for (SubscriptionPoller tests).
    var workPublishedAt: [Int: Date] = [:]
    private(set) var workMetadataCalls: [Int] = []
    /// Scripted EPUB download failures by work id (RestoreDownloadCenter tests).
    var downloadEPUBErrors: [Int: Error] = [:]
    /// Scripted export failure (WorkExporter tests).
    var exportError: Error?
    /// Scripted kudos answer, and the works kudos were sent for (KudosGiver tests).
    var kudosResult: Result<KudosOutcome, Error> = .success(.left)
    private(set) var kudosCalls: [Int] = []
    /// Scripted subscribe failure, and the works subscribed to (WorkSubscriber tests).
    var subscribeError: Error?
    private(set) var subscribeCalls: [Int] = []

    func autocomplete(field: AO3AutocompleteField, term: String) async throws -> [String] {
        autocompleteCalls.append(term)
        if autocompleteFailingTerms.contains(term.lowercased()) {
            throw URLError(.notConnectedToInternet)
        }
        return autocompleteResponses[term.lowercased()] ?? []
    }

    // Unused protocol stubs.
    func login(username: String, password: String) async throws -> String { username }
    func logout() async {}
    func currentUsername() async -> String? { nil }
    func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    func fetchAuthorWorks(username: String, page: Int) async throws -> AO3SearchResults {
        authorWorksResponse ?? AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    func fetchBookmarks(username: String, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    func fetchMarkedForLater(username: String, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    func fetchReadingHistory(username: String, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    func fetchWork(id: Int) async throws -> AO3WorkPayload {
        AO3WorkPayload(summary: .stub(id: id, title: "x"), chapters: [])
    }
    func fetchWorkMetadata(id: Int) async throws -> AO3WorkMetadata {
        workMetadataCalls.append(id)
        if let publishedAt = workPublishedAt[id] {
            return AO3WorkMetadata(id: id, chapterCount: 2, totalChapters: nil, updatedAt: nil, publishedAt: publishedAt)
        }
        if let workMetadataHTML { return try WorkMetadataParser.parse(html: workMetadataHTML, workId: id) }
        return AO3WorkMetadata(id: id, chapterCount: 1, totalChapters: 1, updatedAt: nil)
    }
    func fetchSeries(id: Int, page: Int) async throws -> AO3Series {
        AO3Series(id: id, title: "x", creator: "x", works: [], currentPage: page)
    }
    func fetchSubscriptions(username: String) async throws -> AO3SubscriptionList {
        subscriptionsFetchCount += 1
        return AO3SubscriptionList(subscriptions: subscriptionsResponse, isComplete: subscriptionsComplete)
    }
    func fetchComments(workId: Int, chapterId: Int?, page: Int) async throws -> AO3CommentsPage {
        AO3CommentsPage(comments: [], currentPage: page)
    }
    func postComment(workId: Int, chapterId: Int?, text: String) async throws {}
    func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom] { [] }
    func fetchPopularSnapshot() async throws -> PopularSnapshot {
        PopularSnapshot(fandoms: [], ships: [], characters: [])
    }
    func downloadEPUB(workId: Int) async throws -> URL {
        if let error = downloadEPUBErrors[workId] { throw error }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(workId).epub")
    }
    func exportWork(workId: Int, format: WorkExportFormat, filename: String) async throws -> URL {
        if let exportError { throw exportError }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(filename).\(format.ext)")
    }
    func subscribeToWork(workId: Int) async throws {
        subscribeCalls.append(workId)
        if let subscribeError { throw subscribeError }
    }
    func leaveKudos(workId: Int) async throws -> KudosOutcome {
        kudosCalls.append(workId)
        return try kudosResult.get()
    }
    func fetchBookmarkForm(workId: Int) async throws -> AO3BookmarkForm {
        AO3BookmarkForm(action: URL(string: "https://archiveofourown.org/works/\(workId)/bookmarks")!,
                        hiddenFields: [:], isExisting: false)
    }
    func saveBookmark(_ form: AO3BookmarkForm) async throws {}
}

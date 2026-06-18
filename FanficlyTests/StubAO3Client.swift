import Foundation
@testable import Fanficly

/// Test double whose autocomplete responses are scripted, so resolution
/// logic (e.g. the relationship character-fallback) can be exercised.
final class StubAO3Client: AO3ClientProtocol, @unchecked Sendable {
    /// term (lowercased) → matches
    var autocompleteResponses: [String: [String]] = [:]
    private(set) var autocompleteCalls: [String] = []

    func autocomplete(field: AO3AutocompleteField, term: String) async throws -> [String] {
        autocompleteCalls.append(term)
        return autocompleteResponses[term.lowercased()] ?? []
    }

    // Unused protocol stubs.
    func login(username: String, password: String) async throws {}
    func logout() async {}
    func currentUsername() async -> String? { nil }
    func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    func fetchAuthorWorks(username: String, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    func fetchBookmarks(username: String, page: Int) async throws -> AO3SearchResults {
        AO3SearchResults(works: [], totalPages: 0, currentPage: page)
    }
    func fetchWork(id: Int) async throws -> AO3WorkPayload {
        AO3WorkPayload(summary: .stub(id: id, title: "x"), chapters: [])
    }
    func fetchWorkMetadata(id: Int) async throws -> AO3WorkMetadata {
        AO3WorkMetadata(id: id, chapterCount: 1, totalChapters: 1, updatedAt: nil)
    }
    func fetchSubscriptions(username: String) async throws -> [AO3Subscription] { [] }
    func fetchComments(workId: Int, chapterId: Int?) async throws -> [AO3Comment] { [] }
    func postComment(workId: Int, chapterId: Int?, text: String) async throws {}
    func fetchFandomsInCategory(categoryName: String) async throws -> [BrowseFandom] { [] }
    func fetchPopularSnapshot() async throws -> PopularSnapshot {
        PopularSnapshot(fandoms: [], ships: [], characters: [])
    }
    func downloadEPUB(workId: Int) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(workId).epub")
    }
    func exportWork(workId: Int, format: WorkExportFormat, filename: String) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(filename).\(format.ext)")
    }
    func subscribeToWork(workId: Int) async throws {}
}

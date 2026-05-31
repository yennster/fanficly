import Foundation
import os

public protocol AO3ClientProtocol: Sendable {
    func login(username: String, password: String) async throws
    func logout() async
    func currentUsername() async -> String?
    func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults
    func fetchWork(id: Int) async throws -> AO3WorkPayload
    func downloadEPUB(workId: Int) async throws -> URL
}

public struct AO3SearchResults: Sendable, Equatable {
    public let works: [AO3WorkSummary]
    public let totalPages: Int
    public let currentPage: Int
}

public struct AO3WorkSummary: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let author: String
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

public enum AO3Error: Error, Sendable {
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

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.httpAdditionalHeaders = [
                "User-Agent": Self.userAgent,
                "Accept": "text/html,application/xhtml+xml",
            ]
            cfg.httpCookieAcceptPolicy = .always
            cfg.httpShouldSetCookies = true
            cfg.requestCachePolicy = .useProtocolCachePolicy
            self.session = URLSession(configuration: cfg)
        }
    }

    public static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "Fanficly/\(version) (+github.com/yennster/fanficly)"
    }

    public func login(username: String, password: String) async throws {
        logger.info("Login flow stub — to be implemented")
        throw AO3Error.loginFailed(reason: "Login not yet implemented")
    }

    public func logout() async {
        if let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) {
            for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
    }

    public func currentUsername() async -> String? {
        nil
    }

    public func search(filters: AO3SearchFilters, page: Int) async throws -> AO3SearchResults {
        await throttle.wait()
        let url = try AO3Endpoints.search(filters: filters, page: page, base: baseURL)
        logger.debug("GET \(url.absoluteString, privacy: .public)")
        throw AO3Error.parseFailed(reason: "Search HTML parser not yet implemented")
    }

    public func fetchWork(id: Int) async throws -> AO3WorkPayload {
        await throttle.wait()
        _ = try AO3Endpoints.work(id: id, base: baseURL)
        throw AO3Error.parseFailed(reason: "Work HTML parser not yet implemented")
    }

    public func downloadEPUB(workId: Int) async throws -> URL {
        await throttle.wait()
        _ = try AO3Endpoints.epub(workId: workId, base: baseURL)
        throw AO3Error.parseFailed(reason: "EPUB download not yet implemented")
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
    public func downloadEPUB(workId: Int) async throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(workId).epub")
    }
}

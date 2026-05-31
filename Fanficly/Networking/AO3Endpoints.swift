import Foundation

enum AO3Endpoints {
    static func search(filters: AO3SearchFilters, page: Int, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/works/search"), resolvingAgainstBaseURL: false)
        var items = filters.queryItems()
        if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }
        components?.queryItems = items
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad search URL") }
        return url
    }

    static func work(id: Int, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/works/\(id)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "view_full_work", value: "true")]
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad work URL") }
        return url
    }

    static func epub(workId: Int, base: URL) throws -> URL {
        base.appending(path: "/downloads/\(workId)/work.epub")
    }

    static func userBookmarks(name: String, base: URL) throws -> URL {
        base.appending(path: "/users/\(name)/bookmarks")
    }

    static func userSubscriptions(name: String, base: URL) throws -> URL {
        base.appending(path: "/users/\(name)/subscriptions")
    }

    static func login(base: URL) throws -> URL {
        base.appending(path: "/users/login")
    }
}

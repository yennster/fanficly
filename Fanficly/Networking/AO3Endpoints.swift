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
        components?.queryItems = [
            URLQueryItem(name: "view_full_work", value: "true"),
            URLQueryItem(name: "view_adult", value: "true"),
        ]
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad work URL") }
        return url
    }

    static func epub(workId: Int, base: URL) throws -> URL {
        base.appending(path: "/downloads/\(workId)/work.epub")
    }

    static func download(workId: Int, format: WorkExportFormat, base: URL) throws -> URL {
        base.appending(path: "/downloads/\(workId)/work.\(format.ext)")
    }

    static func authorWorks(name: String, page: Int, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/users/\(name)/works"),
                                       resolvingAgainstBaseURL: false)
        if page > 1 { components?.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad author works URL") }
        return url
    }

    static func userBookmarks(name: String, page: Int = 1, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/users/\(name)/bookmarks"),
                                       resolvingAgainstBaseURL: false)
        if page > 1 { components?.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad bookmarks URL") }
        return url
    }

    static func userSubscriptions(name: String, page: Int = 1, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/users/\(name)/subscriptions"),
                                       resolvingAgainstBaseURL: false)
        if page > 1 { components?.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad subscriptions URL") }
        return url
    }

    static func login(base: URL) throws -> URL {
        base.appending(path: "/users/login")
    }

    static func workComments(id: Int, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/works/\(id)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "view_adult", value: "true"),
            URLQueryItem(name: "show_comments", value: "true"),
        ]
        components?.fragment = "comments"
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad comments URL") }
        return url
    }

    /// A single chapter's page with its comment thread shown — AO3 threads
    /// comments per chapter, so this is what we read/post against when the
    /// reader knows which chapter id it's on.
    static func chapterComments(workId: Int, chapterId: Int, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/works/\(workId)/chapters/\(chapterId)"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "view_adult", value: "true"),
            URLQueryItem(name: "show_comments", value: "true"),
        ]
        components?.fragment = "comments"
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad chapter comments URL") }
        return url
    }

    static func workSubscriptions(id: Int, base: URL) throws -> URL {
        base.appending(path: "/works/\(id)/subscriptions")
    }

    static func workCommentsPost(id: Int, base: URL) throws -> URL {
        base.appending(path: "/works/\(id)/comments")
    }

    static func autocomplete(field: String, term: String, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/autocomplete/\(field)"), resolvingAgainstBaseURL: false)
        // Percent-encode the term ourselves: URLComponents leaves "/" literal in
        // query values (it's RFC-legal there), but AO3's autocomplete 404s on a
        // raw slash — so ships like "Hermione/Draco" must send "%2F".
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "/+&=?"))
        let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed) ?? term
        components?.percentEncodedQuery = "term=\(encoded)"
        guard let url = components?.url else { throw AO3Error.parseFailed(reason: "Bad autocomplete URL") }
        return url
    }

    static func mediaFandoms(categoryName: String, base: URL) throws -> URL {
        let encoded = ao3PathEncode(categoryName)
        guard let url = URL(string: "\(base.absoluteString)/media/\(encoded)/fandoms") else {
            throw AO3Error.parseFailed(reason: "Bad media URL")
        }
        return url
    }

    /// A tag's works listing (`/tags/<tag>/works`) — its left filter sidebar
    /// carries the most-used relationships/characters/freeforms with counts.
    static func tagWorks(tagName: String, base: URL) throws -> URL {
        let encoded = ao3PathEncode(tagName)
        guard let url = URL(string: "\(base.absoluteString)/tags/\(encoded)/works") else {
            throw AO3Error.parseFailed(reason: "Bad tag works URL")
        }
        return url
    }

    private static func ao3PathEncode(_ s: String) -> String {
        var result = ""
        for ch in s {
            switch ch {
            case "&": result += "*a*"
            case "/": result += "*s*"
            case ".": result += "*d*"
            case "?": result += "*q*"
            case "'": result += "*at*"
            case " ": result += "%20"
            default:
                if let escaped = String(ch).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    result += escaped
                } else {
                    result.append(ch)
                }
            }
        }
        return result
    }
}

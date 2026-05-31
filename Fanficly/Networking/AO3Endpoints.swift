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

    static func userBookmarks(name: String, base: URL) throws -> URL {
        base.appending(path: "/users/\(name)/bookmarks")
    }

    static func userSubscriptions(name: String, base: URL) throws -> URL {
        base.appending(path: "/users/\(name)/subscriptions")
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

    static func workSubscriptions(id: Int, base: URL) throws -> URL {
        base.appending(path: "/works/\(id)/subscriptions")
    }

    static func autocomplete(field: String, term: String, base: URL) throws -> URL {
        var components = URLComponents(url: base.appending(path: "/autocomplete/\(field)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "term", value: term)]
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

import Foundation
import SwiftSoup

public struct AO3Subscription: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case work, series, user
    }
    public let kind: Kind
    public let resourceId: String
    public let title: String
    public let author: String?

    public var id: String { "\(kind.rawValue):\(resourceId)" }
    public var key: String { id }
}

enum SubscriptionsParser {
    static func parse(html: String) throws -> [AO3Subscription] {
        let doc = try SwiftSoup.parse(html)
        var seen = Set<String>()
        var results: [AO3Subscription] = []

        let containers = try doc.select("dl.subscription, ul.subscription, dl.subscriptions, ul.subscriptions, ol.subscription, ol.subscriptions")
        let scopes: [Element] = containers.isEmpty() ? [doc] : containers.array()

        for scope in scopes {
            let entries = try scope.select("dt, li.subscription, li.work, li.series, li.user").array()
            let entrySource: [Element] = entries.isEmpty ? [scope] : entries

            for entry in entrySource {
                let links = try entry.select("a[href]").array()
                guard let primary = pickPrimaryLink(links) else { continue }
                let href = try primary.attr("href")
                guard let parsed = classify(href: href) else { continue }
                if seen.contains(parsed.key) { continue }
                seen.insert(parsed.key)

                let title = try primary.text().trimmingCharacters(in: .whitespaces)
                let author = try authorFromEntry(links: links, primary: primary)

                results.append(AO3Subscription(
                    kind: parsed.kind,
                    resourceId: parsed.id,
                    title: title,
                    author: author
                ))
            }
        }

        return results
    }

    private static func pickPrimaryLink(_ links: [Element]) -> Element? {
        for link in links {
            let href = (try? link.attr("href")) ?? ""
            if classify(href: href) != nil, !href.contains("/comments") {
                return link
            }
        }
        return nil
    }

    private static func authorFromEntry(links: [Element], primary: Element) throws -> String? {
        for link in links where link != primary {
            let href = try link.attr("href")
            if href.hasPrefix("/users/") {
                let text = try link.text().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    struct Classified {
        let kind: AO3Subscription.Kind
        let id: String
        var key: String { "\(kind.rawValue):\(id)" }
    }

    private static func classify(href: String) -> Classified? {
        let trimmed = href.split(separator: "?").first.map(String.init) ?? href
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        switch parts[0] {
        case "works":
            return Classified(kind: .work, id: parts[1])
        case "series":
            return Classified(kind: .series, id: parts[1])
        case "users":
            if parts.count == 2 || (parts.count >= 3 && parts[2] == "pseuds") {
                return Classified(kind: .user, id: parts[1])
            }
            return nil
        default:
            return nil
        }
    }
}

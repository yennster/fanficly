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

/// One page of the subscriptions index: its entries plus the pagination
/// numbers needed to walk the remaining pages.
struct AO3SubscriptionsPage: Sendable {
    let subscriptions: [AO3Subscription]
    let currentPage: Int
    let totalPages: Int
}

enum SubscriptionsParser {
    static func parse(html: String) throws -> [AO3Subscription] {
        try parsePage(html: html).subscriptions
    }

    static func parsePage(html: String) throws -> AO3SubscriptionsPage {
        let doc = try SwiftSoup.parse(html)

        // Fail closed on a stale session: AO3 302s /users/<name>/subscriptions
        // to the login page, URLSession follows the redirect, and the caller
        // hands us login HTML with a 200. Returning [] here (or a phantom row
        // scraped from the login page's own links) would make the poller prune
        // every real SubscriptionRecord, so it must be an error.
        if looksLikeLoginPage(doc) {
            throw AO3Error.unauthorized
        }

        var seen = Set<String>()
        var results: [AO3Subscription] = []

        let containers = try doc.select("dl.subscription, ul.subscription, dl.subscriptions, ul.subscriptions, ol.subscription, ol.subscriptions")

        // No subscription list at all: only trust that as "zero subscriptions"
        // when the page carries the subscriptions-index shell — anything else
        // (error page, markup drift, unexpected redirect) must not read as an
        // empty account.
        if containers.isEmpty(), try !hasIndexMarker(doc) {
            throw AO3Error.parseFailed(reason: "Not a subscriptions page")
        }

        for scope in containers.array() {
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

        let (currentPage, totalPages) = try pagination(doc)
        return AO3SubscriptionsPage(
            subscriptions: results,
            currentPage: currentPage,
            totalPages: totalPages
        )
    }

    /// A logged-in-only page can never legitimately contain a login form, so
    /// its presence means the session cookie expired and AO3 redirected us.
    static func looksLikeLoginPage(_ doc: Document) -> Bool {
        let forms = (try? doc.select("form").array()) ?? []
        return forms.contains { form in
            let action = (try? form.attr("action")) ?? ""
            return action.hasSuffix("/users/login") || action.contains("/users/login?")
        }
    }

    /// The subscriptions index shell: the `subscriptions-index` main div
    /// (Rails' controller-action class) or a heading naming the page. Present
    /// even when the user has zero subscriptions.
    private static func hasIndexMarker(_ doc: Document) throws -> Bool {
        if try !doc.select("div.subscriptions-index, div.subscription-index").isEmpty() {
            return true
        }
        for heading in try doc.select("h2.heading, h3.heading").array() {
            if try heading.text().localizedCaseInsensitiveContains("subscription") {
                return true
            }
        }
        return false
    }

    /// Same will_paginate markup as the search pages — see
    /// `SearchResultsParser` for why "current" is checked on both the <li>
    /// and its inner element.
    private static func pagination(_ doc: Document) throws -> (current: Int, total: Int) {
        var current = 1
        var total = 1
        for li in try doc.select("ol.pagination li").array() {
            guard let num = Int(try li.text().trimmingCharacters(in: .whitespaces)) else { continue }
            total = max(total, num)
            let liIsCurrent = try li.attr("class").contains("current")
            let innerIsCurrent = try !li.select(".current").array().isEmpty
            if liIsCurrent || innerIsCurrent { current = num }
        }
        return (current, total)
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

/// AO3's answer to a work's subscribe POST, which fails closed: AO3 redirects
/// either outcome back to the work (URLSession follows, so it's a 200) with a
/// flash, and an ended session to the login page, also a 200. Only AO3's
/// "You are now following …" notice, the work's button turning into
/// "Unsubscribe", or "already subscribed" count as subscribed.
enum SubscribeParser {
    static func checkOutcome(html: String, finalURL: URL?) throws {
        if finalURL?.path.hasPrefix("/users/login") == true || AO3PageCheck.isLoginPage(html: html) {
            throw AO3Error.unauthorized
        }
        guard let doc = try? SwiftSoup.parse(html) else {
            throw AO3Error.parseFailed(reason: "Subscribe response not HTML")
        }
        let errors = texts(doc, "div.flash.error, div#error li")
        if !errors.isEmpty {
            let message = errors.joined(separator: " ")
            // Already subscribed is what we wanted.
            if message.range(of: "already", options: .caseInsensitive) != nil { return }
            throw AO3Error.subscribeRejected(message: message)
        }
        if isConfirmed(doc) { return }
        throw AO3Error.subscribeRejected(message: "AO3 didn't confirm the subscription. Check your Subscriptions page before trying again.")
    }

    private static func isConfirmed(_ doc: Document) -> Bool {
        let notices = texts(doc, "div.flash.notice")
        if notices.contains(where: { $0.range(of: "now following", options: .caseInsensitive) != nil }) {
            return true
        }
        let controls = (try? doc.select("input[type=submit], button").array()) ?? []
        return controls.contains { control in
            let label = control.hasAttr("value") ? ((try? control.attr("value")) ?? "") : ((try? control.text()) ?? "")
            return label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Unsubscribe") == .orderedSame
        }
    }

    private static func texts(_ doc: Document, _ selector: String) -> [String] {
        let items = (try? doc.select(selector).array()) ?? []
        return items.compactMap { try? $0.text() }.filter { !$0.isEmpty }
    }
}
